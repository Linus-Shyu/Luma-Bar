import AppKit
import ApplicationServices
import AVFoundation
import Contacts
import MusicKit
import Speech
import SwiftUI

enum LumaBarPermission: String, CaseIterable, Identifiable {
    case music
    case microphone
    case speechRecognition
    case contacts
    case screenRecording
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: "媒体资料库"
        case .microphone: "麦克风"
        case .speechRecognition: "语音识别"
        case .contacts: "通讯录"
        case .screenRecording: "屏幕录制"
        case .accessibility: "辅助功能"
        }
    }

    var detail: String {
        switch self {
        case .music: "读取本地音乐并显示正在播放的歌曲。"
        case .microphone: "使用 Voice Whisper 录入语音。"
        case .speechRecognition: "把语音转换成文字和指令。"
        case .contacts: "按姓名查找联系人并准备信息。"
        case .screenRecording: "仅在你要求时分析当前窗口截图。"
        case .accessibility: "读取选中文本并支持全局快捷操作。"
        }
    }

    var symbolName: String {
        switch self {
        case .music: "music.note.list"
        case .microphone: "mic.fill"
        case .speechRecognition: "waveform"
        case .contacts: "person.crop.circle"
        case .screenRecording: "rectangle.inset.filled.and.person.filled"
        case .accessibility: "accessibility"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .music: "Privacy_Media"
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        case .contacts: "Privacy_Contacts"
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
    }
}

enum LumaBarPermissionState: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted

    var label: String {
        switch self {
        case .notDetermined: "待设置"
        case .authorized: "已授权"
        case .denied: "未授权"
        case .restricted: "受系统限制"
        }
    }
}

@MainActor
final class PermissionOnboardingModel: ObservableObject {
    static let completionKey = "LumaBar.permissionOnboarding.v1"

    @Published private(set) var states: [LumaBarPermission: LumaBarPermissionState] = [:]
    @Published private(set) var isRequestingAll = false

    private let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        refresh()
    }

    static var hasCompletedSetup: Bool {
        UserDefaults.standard.bool(forKey: completionKey)
    }

    var allCorePermissionsGranted: Bool {
        LumaBarPermission.allCases.allSatisfy { states[$0] == .authorized }
    }

    var grantedCount: Int {
        LumaBarPermission.allCases.filter { states[$0] == .authorized }.count
    }

    func refresh() {
        states[.music] = Self.musicState
        states[.microphone] = Self.microphoneState
        states[.speechRecognition] = Self.speechState
        states[.contacts] = Self.contactsState
        states[.screenRecording] = CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
        states[.accessibility] = AXIsProcessTrusted() ? .authorized : .notDetermined
    }

    func requestAll() {
        guard !isRequestingAll else { return }
        isRequestingAll = true
        Task { @MainActor in
            for permission in LumaBarPermission.allCases {
                await requestIfNeeded(permission, openSettingsIfNeeded: false)
            }
            refresh()
            isRequestingAll = false
        }
    }

    func request(_ permission: LumaBarPermission) {
        Task { @MainActor in
            await requestIfNeeded(permission, openSettingsIfNeeded: true)
            refresh()
        }
    }

    func finish() {
        refresh()
        guard allCorePermissionsGranted else { return }
        UserDefaults.standard.set(true, forKey: Self.completionKey)
        onFinished()
    }

    func openAutomationSettings() {
        openPrivacySettings(anchor: "Privacy_Automation")
    }

    func openFullDiskAccessSettings() {
        openPrivacySettings(anchor: "Privacy_AllFiles")
    }

    private func requestIfNeeded(
        _ permission: LumaBarPermission,
        openSettingsIfNeeded: Bool
    ) async {
        refresh()
        if states[permission] == .authorized {
            return
        }

        if states[permission] == .denied || states[permission] == .restricted {
            if openSettingsIfNeeded {
                openPrivacySettings(anchor: permission.settingsAnchor)
            }
            return
        }

        switch permission {
        case .music:
            _ = await MusicAuthorization.request()
        case .microphone:
            _ = await Self.requestMicrophoneAuthorization()
        case .speechRecognition:
            _ = await Self.requestSpeechAuthorization()
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .screenRecording:
            let granted = CGRequestScreenCaptureAccess()
            if !granted, openSettingsIfNeeded {
                openPrivacySettings(anchor: permission.settingsAnchor)
            }
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let granted = AXIsProcessTrustedWithOptions(options)
            if !granted, openSettingsIfNeeded {
                openPrivacySettings(anchor: permission.settingsAnchor)
            }
        }

        refresh()
    }

    private nonisolated static func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private nonisolated static func requestSpeechAuthorization() async
        -> SFSpeechRecognizerAuthorizationStatus
    {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private static var musicState: LumaBarPermissionState {
        switch MusicAuthorization.currentStatus {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    private static var microphoneState: LumaBarPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    private static var speechState: LumaBarPermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    private static var contactsState: LumaBarPermissionState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .limited: .authorized
        @unknown default: .restricted
        }
    }
}

struct PermissionOnboardingView: View {
    @ObservedObject var model: PermissionOnboardingModel

    private let refreshTimer = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(LumaBarPermission.allCases) { permission in
                        PermissionRow(
                            permission: permission,
                            state: model.states[permission] ?? .notDetermined,
                            action: { model.request(permission) }
                        )
                    }

                    advancedSettings
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }

            footer
        }
        .frame(minWidth: 620, maxWidth: 620, minHeight: 520, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(refreshTimer) { _ in model.refresh() }
    }

    private var header: some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.92), Color.pink.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 62, height: 62)

            Text("一次完成 luma bar 权限设置")
                .font(.system(size: 24, weight: .bold))

            Text("这些权限只会在首次设置时集中请求。授权后，日常使用不会重复弹窗。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按用途授权")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("自动化权限由 macOS 按 Messages、Safari、Chrome 等目标应用分别管理；文件权限也按目录管理。系统不允许应用替用户直接勾选，你可以现在打开对应设置页。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("自动化设置") { model.openAutomationSettings() }
                Button("完全磁盘访问") { model.openFullDiskAccessSettings() }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("已完成 \(model.grantedCount) / \(LumaBarPermission.allCases.count)")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.allCorePermissionsGranted ? "所有核心权限已设置" : "请完成全部核心权限后继续")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.requestAll()
            } label: {
                if model.isRequestingAll {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 92)
                } else {
                    Text("一键开始授权")
                        .frame(width: 92)
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRequestingAll || model.allCorePermissionsGranted)

            Button("完成并开始使用") {
                model.finish()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.allCorePermissionsGranted)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }
}

private struct PermissionRow: View {
    let permission: LumaBarPermission
    let state: LumaBarPermissionState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: permission.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(state == .authorized ? Color.green : Color.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill((state == .authorized ? Color.green : Color.accentColor).opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(permission.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Text(state.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state == .authorized ? Color.green : Color.secondary)
                .frame(width: 58, alignment: .trailing)

            Button(state == .authorized ? "完成" : (state == .notDetermined ? "授权" : "打开设置")) {
                action()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 76)
            .disabled(state == .authorized)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(state == .authorized ? Color.green.opacity(0.25) : Color.primary.opacity(0.06))
                }
        )
    }
}
