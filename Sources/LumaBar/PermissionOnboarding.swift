import AppKit
import ApplicationServices
import SwiftUI

enum LumaBarPermission: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording

    var id: String { rawValue }

    static var onboardingCases: [LumaBarPermission] {
        [.accessibility, .screenRecording]
    }

    var title: String {
        switch self {
        case .accessibility: "辅助功能"
        case .screenRecording: "屏幕录制"
        }
    }

    var hint: String {
        switch self {
        case .accessibility: "划词翻译需要"
        case .screenRecording: "截图分析需要（可后开）"
        }
    }

    var symbolName: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
    }
}

enum LumaBarPermissionState: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted

    var isAuthorized: Bool { self == .authorized }

    var label: String {
        switch self {
        case .notDetermined: "未设置"
        case .authorized: "已开启"
        case .denied, .restricted: "未开启"
        }
    }
}

@MainActor
final class PermissionOnboardingModel: ObservableObject {
    static let completionKey = "LumaBar.permissionOnboarding.v1"

    @Published private(set) var states: [LumaBarPermission: LumaBarPermissionState] = [:]
    @Published private(set) var isRequesting = false

    var onPermissionBecameAuthorized: ((LumaBarPermission) -> Void)?

    private let onFinished: () -> Void
    private var previousAuthorized: Set<LumaBarPermission> = []
    private var pollTask: Task<Void, Never>?

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        refresh()
        previousAuthorized = authorizedSet
    }

    static var hasCompletedSetup: Bool {
        UserDefaults.standard.bool(forKey: completionKey)
    }

    private var authorizedSet: Set<LumaBarPermission> {
        Set(LumaBarPermission.onboardingCases.filter { states[$0]?.isAuthorized == true })
    }

    func refresh() {
        let next = Self.readSnapshot()
        let nowAuthorized = Set(LumaBarPermission.onboardingCases.filter { next[$0]?.isAuthorized == true })
        let newly = nowAuthorized.subtracting(previousAuthorized)
        states = next
        previousAuthorized = nowAuthorized
        for permission in newly {
            onPermissionBecameAuthorized?(permission)
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
        guard !isRequesting else { return }
        isRequesting = true
        Task { @MainActor in
            for permission in LumaBarPermission.onboardingCases {
                await request(permission, jumpToSettings: true)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            refresh()
            isRequesting = false
        }
    }

    func request(_ permission: LumaBarPermission) {
        Task { @MainActor in
            await request(permission, jumpToSettings: true)
            refresh()
        }
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.completionKey)
        onFinished()
    }

    private func request(_ permission: LumaBarPermission, jumpToSettings: Bool) async {
        let current = Self.readSnapshot()[permission] ?? .notDetermined
        if current.isAuthorized { return }

        switch permission {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let granted = AXIsProcessTrustedWithOptions(options)
            if !granted, jumpToSettings {
                openPrivacySettings(for: permission)
            }
        case .screenRecording:
            let granted = CGRequestScreenCaptureAccess()
            if !granted, jumpToSettings {
                openPrivacySettings(for: permission)
            }
        }
    }

    private func openPrivacySettings(for permission: LumaBarPermission) {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(permission.settingsAnchor)"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private static func readSnapshot() -> [LumaBarPermission: LumaBarPermissionState] {
        [
            .accessibility: AXIsProcessTrusted() ? .authorized : .notDetermined,
            .screenRecording: CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
        ]
    }
}

struct PermissionOnboardingView: View {
    @ObservedObject var model: PermissionOnboardingModel
    private let timer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("权限设置")
                    .font(.system(size: 22, weight: .bold))
                Text("只需这几项。麦克风和通讯录会在你真正用到时再询问。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)

            VStack(spacing: 8) {
                ForEach(LumaBarPermission.onboardingCases) { permission in
                    let state = model.states[permission] ?? .notDetermined
                    HStack(spacing: 12) {
                        Image(systemName: permission.symbolName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(state.isAuthorized ? Color.green : Color.secondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title)
                                .font(.system(size: 14, weight: .medium))
                            Text(permission.hint)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(state.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(state.isAuthorized ? Color.green : Color.secondary)

                        Button(state.isAuthorized ? "好" : "开启") {
                            model.request(permission)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(state.isAuthorized)
                        .frame(width: 56)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 20)

            HStack(spacing: 12) {
                Button {
                    model.requestAll()
                } label: {
                    if model.isRequesting {
                        ProgressView().controlSize(.small).frame(width: 88)
                    } else {
                        Text("一键开启").frame(width: 88)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.isRequesting)

                Button("开始使用") {
                    model.finish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 24)
        }
        .frame(width: 400, height: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(timer) { _ in model.pollTick() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.syncFromSystemSettings()
        }
        .onAppear { model.refresh() }
    }
}
