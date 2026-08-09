import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Permission identity

enum LumaBarPermission: String, CaseIterable, Identifiable {
    case accessibility
    case automation
    case screenRecording

    var id: String { rawValue }

    /// Shown in first-run / Permission Setup panel.
    static var onboardingCases: [LumaBarPermission] {
        var cases: [LumaBarPermission] = []
        if AppStoreDistribution.allowsAccessibilityFeatures {
            cases.append(.accessibility)
        }
        if AppStoreDistribution.allowsShellAutomation {
            cases.append(.automation)
        }
        if AppStoreDistribution.allowsScreenCapture {
            cases.append(.screenRecording)
        }
        return cases.isEmpty ? [.accessibility, .automation, .screenRecording] : cases
    }

    /// Core permissions power daily product paths; optional ones can be skipped.
    var isCore: Bool {
        switch self {
        case .accessibility, .automation: true
        case .screenRecording: false
        }
    }

    var title: String {
        switch self {
        case .accessibility: "辅助功能"
        case .automation: "自动化控制"
        case .screenRecording: "屏幕录制"
        }
    }

    var subtitle: String {
        switch self {
        case .accessibility:
            "划词翻译、Agent 读取选区与前台 App 上下文"
        case .automation:
            "通过 AppleScript 同步 Apple Music / 网易云播放状态"
        case .screenRecording:
            "截图分析当前窗口（可选，可稍后开启）"
        }
    }

    var symbolName: String {
        switch self {
        case .accessibility: "accessibility"
        case .automation: "arrow.triangle.2.circlepath"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .automation: "Privacy_Automation"
        case .screenRecording: "Privacy_ScreenCapture"
        }
    }

    var guideSteps: [String] {
        switch self {
        case .accessibility:
            [
                "点击「授权」或「打开系统设置」",
                "在「隐私与安全性 → 辅助功能」中找到 luma bar",
                "打开右侧开关，再回到本窗口（无需重启）"
            ]
        case .automation:
            [
                "点击「授权」弹出系统询问时选择「好」",
                "或打开「隐私与安全性 → 自动化」，允许控制 Music / 系统事件",
                "返回 Luma Bar 后状态会自动刷新"
            ]
        case .screenRecording:
            [
                "点击「授权」按系统提示允许屏幕录制",
                "也可在「隐私与安全性 → 屏幕录制」中手动打开",
                "不需要的话可以先跳过，不影响日常听歌"
            ]
        }
    }
}

// MARK: - State

enum LumaBarPermissionState: Equatable {
    case notDetermined
    case requesting
    case authorized
    case denied
    case restricted

    var isAuthorized: Bool { self == .authorized }
    var isBlocking: Bool { self == .denied || self == .restricted }

    var label: String {
        switch self {
        case .notDetermined: "待授权"
        case .requesting: "请求中…"
        case .authorized: "已完成"
        case .denied: "未开启"
        case .restricted: "受限制"
        }
    }
}

private enum AutomationTCC {
    static let wouldRequireConsent: OSStatus = -1744 // errAEEventWouldRequireUserConsent
    static let notPermitted: OSStatus = -1743 // errAEEventNotPermitted
}

// MARK: - Model

@MainActor
final class PermissionOnboardingModel: ObservableObject {
    static let completionKey = "LumaBar.permissionOnboarding.v1"
    static let skippedKey = "LumaBar.permissionOnboarding.skipped.v1"
    static let promptedKeyPrefix = "LumaBar.permissionOnboarding.prompted."

    @Published private(set) var states: [LumaBarPermission: LumaBarPermissionState] = [:]
    @Published private(set) var requesting: Set<LumaBarPermission> = []
    @Published private(set) var isRequestingAll = false
    @Published private(set) var expandedGuide: LumaBarPermission?
    @Published private(set) var skipped: Set<LumaBarPermission> = []
    @Published private(set) var justAuthorized: Set<LumaBarPermission> = []

    var onPermissionBecameAuthorized: ((LumaBarPermission) -> Void)?
    var onSoftReminder: ((String) -> Void)?

    private let onFinished: () -> Void
    private var previousAuthorized: Set<LumaBarPermission> = []
    private var pollTask: Task<Void, Never>?
    private var celebrateTask: Task<Void, Never>?
    private var autoFinishTask: Task<Void, Never>?

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        skipped = Self.loadSkipped()
        refresh()
        previousAuthorized = authorizedSet
    }

    static var hasCompletedSetup: Bool {
        UserDefaults.standard.bool(forKey: completionKey)
    }

    var corePermissions: [LumaBarPermission] {
        LumaBarPermission.onboardingCases.filter(\.isCore)
    }

    var optionalPermissions: [LumaBarPermission] {
        LumaBarPermission.onboardingCases.filter { !$0.isCore }
    }

    var authorizedCount: Int {
        LumaBarPermission.onboardingCases.filter { states[$0]?.isAuthorized == true }.count
    }

    var totalCount: Int { LumaBarPermission.onboardingCases.count }

    var progressFraction: Double {
        guard totalCount > 0 else { return 1 }
        let done = LumaBarPermission.onboardingCases.filter { permission in
            states[permission]?.isAuthorized == true || skipped.contains(permission)
        }.count
        return Double(done) / Double(totalCount)
    }

    var allCoreAuthorized: Bool {
        corePermissions.allSatisfy { states[$0]?.isAuthorized == true }
    }

    var canFinishComfortably: Bool {
        allCoreAuthorized
            && optionalPermissions.allSatisfy {
                states[$0]?.isAuthorized == true || skipped.contains($0)
            }
    }

    var primaryActionTitle: String {
        if canFinishComfortably { return "完成并开始" }
        if allCoreAuthorized { return "开始使用" }
        return "稍后再说"
    }

    private var authorizedSet: Set<LumaBarPermission> {
        Set(LumaBarPermission.onboardingCases.filter { states[$0]?.isAuthorized == true })
    }

    func refresh() {
        var next = Self.readSnapshot()
        for permission in LumaBarPermission.onboardingCases {
            if requesting.contains(permission), next[permission]?.isAuthorized != true {
                next[permission] = .requesting
            } else if next[permission] == .notDetermined, Self.hasPrompted(permission) {
                next[permission] = .denied
            }
        }

        let nowAuthorized = Set(LumaBarPermission.onboardingCases.filter { next[$0]?.isAuthorized == true })
        let newly = nowAuthorized.subtracting(previousAuthorized)
        states = next
        previousAuthorized = nowAuthorized

        if !newly.isEmpty {
            justAuthorized.formUnion(newly)
            skipped.subtract(newly)
            Self.persistSkipped(skipped)
            celebrateTask?.cancel()
            celebrateTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                justAuthorized.subtract(newly)
            }
            for permission in newly {
                onPermissionBecameAuthorized?(permission)
            }
            maybeAutoAdvance()
        }
    }

    func syncFromSystemSettings() {
        pollTick()
    }

    func pollTick() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            defer { pollTask = nil }
            refresh()
        }
    }

    func requestAll() {
        guard !isRequestingAll else { return }
        isRequestingAll = true
        Task { @MainActor in
            for permission in LumaBarPermission.onboardingCases {
                if states[permission]?.isAuthorized == true { continue }
                if skipped.contains(permission), !permission.isCore { continue }
                await request(permission, jumpToSettings: true)
                try? await Task.sleep(nanoseconds: 280_000_000)
            }
            refresh()
            isRequestingAll = false
        }
    }

    func request(_ permission: LumaBarPermission) {
        Task { @MainActor in
            await request(permission, jumpToSettings: true)
            refresh()
        }
    }

    func openSettings(for permission: LumaBarPermission) {
        Self.openPrivacySettings(for: permission)
    }

    func skip(_ permission: LumaBarPermission) {
        guard !permission.isCore else { return }
        skipped.insert(permission)
        Self.persistSkipped(skipped)
        expandedGuide = nil
        maybeAutoAdvance()
    }

    func unskip(_ permission: LumaBarPermission) {
        skipped.remove(permission)
        Self.persistSkipped(skipped)
    }

    func toggleGuide(for permission: LumaBarPermission) {
        expandedGuide = expandedGuide == permission ? nil : permission
    }

    func finish() {
        autoFinishTask?.cancel()
        UserDefaults.standard.set(true, forKey: Self.completionKey)
        Self.persistSkipped(skipped)

        var tips: [String] = []
        if states[.accessibility]?.isAuthorized != true {
            tips.append("划词翻译还需开启「辅助功能」，可在菜单栏 → Permission Setup 再开。")
        }
        if states[.automation]?.isAuthorized != true {
            tips.append("音乐同步需要「自动化」权限，播放控制可能暂时不可用。")
        }
        if skipped.contains(.screenRecording), states[.screenRecording]?.isAuthorized != true {
            tips.append("已跳过屏幕录制；需要截图分析时再去权限设置开启即可。")
        }
        if let tip = tips.first {
            onSoftReminder?(tip)
        }
        onFinished()
    }

    private func maybeAutoAdvance() {
        guard canFinishComfortably else { return }
        autoFinishTask?.cancel()
        autoFinishTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, canFinishComfortably else { return }
            finish()
        }
    }

    private func request(_ permission: LumaBarPermission, jumpToSettings: Bool) async {
        let current = Self.readSnapshot()[permission] ?? .notDetermined
        if current.isAuthorized { return }

        requesting.insert(permission)
        states[permission] = .requesting
        Self.markPrompted(permission)
        skipped.remove(permission)
        Self.persistSkipped(skipped)

        switch permission {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let granted = AXIsProcessTrustedWithOptions(options)
            if !granted, jumpToSettings {
                Self.openPrivacySettings(for: permission)
            }
        case .automation:
            _ = Self.probeAutomation(prompt: true)
            if jumpToSettings {
                try? await Task.sleep(nanoseconds: 450_000_000)
                if Self.readSnapshot()[.automation]?.isAuthorized != true {
                    Self.openPrivacySettings(for: permission)
                }
            }
        case .screenRecording:
            let granted = CGRequestScreenCaptureAccess()
            if !granted, jumpToSettings {
                Self.openPrivacySettings(for: permission)
            }
        }

        requesting.remove(permission)
    }

    // MARK: Snapshot / Settings

    private static func readSnapshot() -> [LumaBarPermission: LumaBarPermissionState] {
        var map: [LumaBarPermission: LumaBarPermissionState] = [:]
        for permission in LumaBarPermission.onboardingCases {
            switch permission {
            case .accessibility:
                map[permission] = AXIsProcessTrusted() ? .authorized : .notDetermined
            case .automation:
                map[permission] = probeAutomation(prompt: false)
            case .screenRecording:
                map[permission] = CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
            }
        }
        return map
    }

    private static func probeAutomation(prompt: Bool) -> LumaBarPermissionState {
        let targets = ["com.apple.Music", "com.apple.systemevents"]
        var sawNotDetermined = false
        var sawDenied = false
        var sawAuthorized = false

        for bundleID in targets {
            switch automationOSStatus(bundleID: bundleID, prompt: prompt) {
            case noErr:
                sawAuthorized = true
            case AutomationTCC.wouldRequireConsent:
                sawNotDetermined = true
            case AutomationTCC.notPermitted:
                sawDenied = true
            default:
                continue
            }
        }

        if sawAuthorized { return .authorized }
        if sawDenied { return .denied }
        if sawNotDetermined { return .notDetermined }
        return .notDetermined
    }

    private static func automationOSStatus(bundleID: String, prompt: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(
            target.aeDesc,
            typeWildCard,
            typeWildCard,
            prompt
        )
    }

    static func openPrivacySettings(for permission: LumaBarPermission) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(permission.settingsAnchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private static func hasPrompted(_ permission: LumaBarPermission) -> Bool {
        UserDefaults.standard.bool(forKey: promptedKeyPrefix + permission.rawValue)
    }

    private static func markPrompted(_ permission: LumaBarPermission) {
        UserDefaults.standard.set(true, forKey: promptedKeyPrefix + permission.rawValue)
    }

    private static func loadSkipped() -> Set<LumaBarPermission> {
        let raw = UserDefaults.standard.stringArray(forKey: skippedKey) ?? []
        return Set(raw.compactMap(LumaBarPermission.init(rawValue:)))
    }

    private static func persistSkipped(_ set: Set<LumaBarPermission>) {
        UserDefaults.standard.set(set.map(\.rawValue).sorted(), forKey: skippedKey)
    }
}

// MARK: - View

struct PermissionOnboardingView: View {
    @ObservedObject var model: PermissionOnboardingModel
    @Environment(\.colorScheme) private var colorScheme

    private let timer = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    private var accent: Color {
        Color(red: 0.18, green: 0.55, blue: 0.72)
    }

    private var success: Color {
        Color(red: 0.22, green: 0.68, blue: 0.42)
    }

    private var danger: Color {
        Color(red: 0.86, green: 0.28, blue: 0.28)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 28)
                .padding(.horizontal, 28)
                .padding(.bottom, 18)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(LumaBarPermission.onboardingCases) { permission in
                        permissionCard(permission)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
            }

            footer
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 22)
        }
        .frame(width: 440, height: 560)
        .background(pageBackground)
        .onReceive(timer) { _ in model.pollTick() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.syncFromSystemSettings()
        }
        .onAppear { model.refresh() }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(colorScheme == .dark ? 0.35 : 0.22),
                                accent.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)

                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(spacing: 6) {
                Text("权限引导")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("开启下列能力后，Luma Bar 才能完整工作。从系统设置返回时会自动刷新状态。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            progressBar
        }
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent, accent.opacity(0.75)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * model.progressFraction))
                        .animation(.easeInOut(duration: 0.35), value: model.progressFraction)
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(model.authorizedCount)/\(model.totalCount) 已授权")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.allCoreAuthorized {
                    Label("核心权限已就绪", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(success)
                } else {
                    Text("请先完成核心权限")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func permissionCard(_ permission: LumaBarPermission) -> some View {
        let state = displayState(for: permission)
        let isSkipped = model.skipped.contains(permission)
        let showGuide = model.expandedGuide == permission

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                statusGlyph(
                    for: state,
                    symbol: permission.symbolName,
                    celebrated: model.justAuthorized.contains(permission)
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(permission.title)
                            .font(.system(size: 14, weight: .semibold))
                        Text(permission.isCore ? "核心" : "可选")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                (permission.isCore ? accent.opacity(0.14) : Color.primary.opacity(0.06)),
                                in: Capsule()
                            )
                            .foregroundStyle(permission.isCore ? accent : Color.secondary)
                        Spacer(minLength: 0)
                        Text(statusLabel(state: state, skipped: isSkipped))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(statusColor(state: state, skipped: isSkipped))
                    }

                    Text(permission.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !state.isAuthorized {
                HStack(spacing: 8) {
                    Button {
                        model.request(permission)
                    } label: {
                        Label(
                            state.isBlocking ? "重试授权" : "授权",
                            systemImage: "hand.raised.fill"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .frame(minWidth: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.small)
                    .disabled(state == .requesting || model.isRequestingAll)

                    Button {
                        model.openSettings(for: permission)
                    } label: {
                        Label("打开系统设置", systemImage: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if !permission.isCore {
                        Button(isSkipped ? "撤销跳过" : "跳过") {
                            if isSkipped {
                                model.unskip(permission)
                            } else {
                                model.skip(permission)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                Button {
                    model.toggleGuide(for: permission)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showGuide ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(showGuide ? "收起指引" : "如何开启？")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(accent.opacity(0.9))
                }
                .buttonStyle(.plain)

                if showGuide {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(permission.guideSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(width: 16, height: 16)
                                    .background(accent.opacity(0.85), in: Circle())
                                Text(step)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.primary.opacity(0.82))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accent.opacity(colorScheme == .dark ? 0.12 : 0.07))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(14)
        .background(cardBackground(authorized: state.isAuthorized, skipped: isSkipped))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(cardBorder(authorized: state.isAuthorized, skipped: isSkipped), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.22), value: showGuide)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    private func displayState(for permission: LumaBarPermission) -> LumaBarPermissionState {
        if model.requesting.contains(permission) { return .requesting }
        return model.states[permission] ?? .notDetermined
    }

    private func statusLabel(state: LumaBarPermissionState, skipped: Bool) -> String {
        if state.isAuthorized { return "已完成" }
        if skipped { return "已跳过" }
        return state.label
    }

    private func statusColor(state: LumaBarPermissionState, skipped: Bool) -> Color {
        if state.isAuthorized { return success }
        if skipped { return .secondary }
        if state == .requesting { return accent }
        if state.isBlocking { return danger }
        return .secondary
    }

    @ViewBuilder
    private func statusGlyph(for state: LumaBarPermissionState, symbol: String, celebrated: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(glyphBackground(state))
                .frame(width: 40, height: 40)

            if state == .requesting {
                ProgressView()
                    .controlSize(.small)
            } else if state.isAuthorized {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(success)
                    .modifier(PermissionBounceModifier(trigger: celebrated))
            } else if state.isBlocking {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(danger)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.9))
            }
        }
    }

    private func glyphBackground(_ state: LumaBarPermissionState) -> Color {
        if state.isAuthorized { return success.opacity(0.14) }
        if state.isBlocking { return danger.opacity(0.12) }
        if state == .requesting { return accent.opacity(0.12) }
        return Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.05)
    }

    private func cardBackground(authorized: Bool, skipped: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        authorized
                            ? success.opacity(colorScheme == .dark ? 0.1 : 0.06)
                            : skipped
                                ? Color.primary.opacity(0.03)
                                : Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.02)
                    )
            }
    }

    private func cardBorder(authorized: Bool, skipped: Bool) -> Color {
        if authorized { return success.opacity(0.35) }
        if skipped { return Color.primary.opacity(0.06) }
        return Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if !model.allCoreAuthorized {
                Text("核心权限未完成时仍可进入，但划词 / 音乐同步可能不可用。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button {
                    model.requestAll()
                } label: {
                    Group {
                        if model.isRequestingAll {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("一键授权")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.isRequestingAll || model.canFinishComfortably)

                Button {
                    model.finish()
                } label: {
                    Text(model.primaryActionTitle)
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var pageBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    accent.opacity(colorScheme == .dark ? 0.14 : 0.08),
                    .clear,
                    Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct PermissionBounceModifier: ViewModifier {
    let trigger: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.symbolEffect(.bounce, value: trigger)
        } else {
            content
        }
    }
}
