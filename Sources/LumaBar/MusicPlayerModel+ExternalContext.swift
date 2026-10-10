import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Combine
import CommonCrypto
import Contacts
import CoreAudio
import CoreText
import CoreWLAN
import Darwin
import IOKit.ps
import PDFKit
import QuartzCore
import ScreenCaptureKit
import Security
import SQLite3
import Speech
import SwiftUI

extension MusicPlayerModel {
    func applyActiveApplication(_ application: NSRunningApplication?) {
        guard isAutoContextEnabled else { return }
        guard let application else { return }

        let bundleIdentifier = application.bundleIdentifier ?? ""
        if bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }

        let appName = application.localizedName ?? ""
        activeExternalApplicationPID = application.processIdentifier
        activeExternalBundleIdentifier = bundleIdentifier
        let context = Self.appContext(
            application: application,
            bundleIdentifier: bundleIdentifier,
            appName: appName
        )
        let appNameChanged = activeAppName != appName
        let contextChanged = activeAppContext != context

        if appNameChanged {
            activeAppName = appName
        }
        if contextChanged {
            activeAppContext = context
        }
        if appNameChanged || contextChanged {
            scheduleNextProactivePetMessage(after: Date(), soon: true)
        }

        let terminalBundleIdentifiers: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable"
        ]
        let windowTitle = terminalBundleIdentifiers.contains(bundleIdentifier)
            ? AgentContextProvider.capture(
                processID: application.processIdentifier,
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                includeFocusedText: false
            ).windowTitle
            : nil

        if let tokenSource = Self.externalTokenSource(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: windowTitle
        ) {
            // Keep selection translation / agent replies visible while Cursor or Codex is frontmost.
            if isSelectionTranslationActive
                || (isExpanded && (activeMode == .agent || isAgentStreaming || isAgentShellRunning))
            {
                activeExternalTokenSource = tokenSource
                refreshCodexTokenUsage(force: false)
                return
            }

            // Monitor Cursor/Codex/Kiro usage in the background, but do not steal the
            // music (or other) compact UI just because that IDE became frontmost.
            let sourceChanged = activeExternalTokenSource != tokenSource
            activeExternalTokenSource = tokenSource
            refreshCodexTokenUsage(force: sourceChanged)
            return
        }

        if isCodexTokenAutoExpanded {
            isCodexTokenAutoExpanded = false
            showsKiroCreditsOverlay = false
            showsCodexWeeklyQuotaOverlay = false
            activeExternalTokenSource = nil
            isExpanded = false
            activeMode = modeBeforeCodexTokenExpansion
        } else if activeExternalTokenSource != nil {
            activeExternalTokenSource = nil
        }

        switch context {
        case .netEase:
            // Never let NetEase becoming frontmost steal a user-locked local / Apple Music channel.
            guard allowsPassiveOwnership(for: .netEase) else { break }
            if activeMode != .music {
                activeMode = .music
            }
            if contextChanged {
                refreshNetEasePlaylists()
                refreshNetEaseNowPlaying(force: true)
            }
        case .coding:
            // Keep the user's current island mode (music / agent / system).
            // Coding apps should not force System and hide playback controls.
            break
        case .writing, .reading, .gaming:
            if activeMode != .agent {
                activeMode = .agent
            }
        case .general:
            if bundleIdentifier == "com.apple.Music" {
                guard allowsPassiveOwnership(for: .appleMusic) || musicLibrarySource == .appleMusic else {
                    break
                }
                if activeMode != .music {
                    activeMode = .music
                }
                if contextChanged || appNameChanged {
                    if allowsPassiveOwnership(for: .appleMusic) {
                        isUsingAppleMusic = true
                        isUsingNetEase = false
                    }
                    refreshAppleMusicNowPlaying(force: true)
                }
            }
        }
    }

    static func appContext(
        application: NSRunningApplication,
        bundleIdentifier: String,
        appName: String
    ) -> IslandAppContext {
        if bundleIdentifier == netEaseMusicBundleIdentifier {
            return .netEase
        }

        let codingBundleIdentifiers: Set<String> = [
            "com.apple.Terminal",
            "com.apple.dt.Xcode",
            "com.googlecode.iterm2",
            "com.microsoft.VSCode",
            "com.openai.codex",
            "dev.kiro.desktop",
            "com.todesktop.230313mzl4w4u92",
            "com.sublimetext.4",
            "dev.warp.Warp-Stable"
        ]

        if codingBundleIdentifiers.contains(bundleIdentifier)
            || bundleIdentifier.hasPrefix("com.todesktop.")
        {
            return .coding
        }

        if bundleIdentifier.hasPrefix("com.jetbrains.") {
            return .coding
        }

        let writingBundleIdentifiers: Set<String> = [
            "com.apple.iWork.Pages",
            "com.microsoft.Word",
            "com.lukilabs.lukiapp",
            "md.obsidian",
            "notion.id"
        ]
        if writingBundleIdentifiers.contains(bundleIdentifier) {
            return .writing
        }

        let readingBundleIdentifiers: Set<String> = [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "com.apple.Preview",
            "com.adobe.Reader",
            "org.zotero.zotero"
        ]
        if readingBundleIdentifiers.contains(bundleIdentifier) {
            return .reading
        }

        if bundleIdentifier == "com.valvesoftware.steam"
            || bundleIdentifier.hasPrefix("com.valvesoftware.")
            || Self.isGameApplication(application)
        {
            return .gaming
        }

        let normalizedName = appName.lowercased()
        if normalizedName.contains("cursor")
            || normalizedName.contains("visual studio code")
            || normalizedName.contains("xcode")
            || normalizedName.contains("terminal")
            || normalizedName.contains("iterm")
            || normalizedName.contains("warp")
        {
            return .coding
        }

        if normalizedName.contains("notion")
            || normalizedName.contains("craft")
            || normalizedName.contains("pages")
            || normalizedName.contains("obsidian")
        {
            return .writing
        }

        if normalizedName.contains("safari")
            || normalizedName.contains("chrome")
            || normalizedName.contains("arc")
            || normalizedName.contains("acrobat")
            || normalizedName.contains("preview")
            || normalizedName.contains("zotero")
        {
            return .reading
        }

        if normalizedName.contains("steam") {
            return .gaming
        }

        return .general
    }

    static func externalTokenSource(
        bundleIdentifier: String,
        appName: String,
        windowTitle: String?
    ) -> ExternalTokenSource? {
        if bundleIdentifier == "com.openai.codex"
            || appName.caseInsensitiveCompare("Codex") == .orderedSame
            || windowTitle?.localizedCaseInsensitiveContains("codex") == true
        {
            return .codex
        }

        // Cursor Stable/Insiders/Nightly all ship under the ToDesktop namespace with
        // different IDs, so match the namespace plus the product name instead of one ID.
        let normalizedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if bundleIdentifier == "com.todesktop.230313mzl4w4u92"
            || (bundleIdentifier.hasPrefix("com.todesktop.") && normalizedAppName.contains("cursor"))
            || normalizedAppName.hasPrefix("cursor")
        {
            return .cursor
        }

        if bundleIdentifier == "dev.kiro.desktop"
            || normalizedAppName == "kiro"
            || normalizedAppName.hasPrefix("kiro")
        {
            return .kiro
        }

        return nil
    }

    static func isGameApplication(_ application: NSRunningApplication) -> Bool {
        guard let bundleURL = application.bundleURL,
              let bundle = Bundle(url: bundleURL),
              let category = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        else {
            return false
        }
        return category == "public.app-category.games"
    }

    func prepareExternalFolderAccess(for source: ExternalTokenSource) {
#if LUMA_APP_STORE
        guard askedExternalFolderSources.insert(source).inserted else { return }
        let keys: [SecurityScopedBookmarks.Key]
        switch source {
        case .cursor:
            keys = [.cursorApplicationSupport, .cursorProjects]
        case .codex, .chatgpt:
            keys = [.codexHome]
        case .kiro:
            keys = [.kiroHome, .kiroApplicationSupport]
        case .cherryStudio:
            keys = [.cherryStudioSupport]
        case .deepSeekHarness:
            keys = [.deepSeekHarnessHome]
        }
        for key in keys where !SecurityScopedBookmarks.hasBookmark(for: key) {
            _ = SecurityScopedBookmarks.promptAndStore(for: key)
        }
#endif
    }

    func prepareRunningExternalFolderAccess() {
#if LUMA_APP_STORE
        let running = NSWorkspace.shared.runningApplications
        func isRunning(_ bundleIdentifier: String) -> Bool {
            running.contains { $0.bundleIdentifier == bundleIdentifier }
        }
        if running.contains(where: {
            ($0.bundleIdentifier?.hasPrefix("com.todesktop.") == true
                && ($0.localizedName ?? "").localizedCaseInsensitiveContains("cursor"))
                || $0.bundleIdentifier == "com.todesktop.230313mzl4w4u92"
        }) {
            prepareExternalFolderAccess(for: .cursor)
        }
        if isRunning("com.openai.codex") || isRunning("com.openai.chat") {
            prepareExternalFolderAccess(for: .codex)
        }
        if isRunning("dev.kiro.desktop") {
            prepareExternalFolderAccess(for: .kiro)
        }
        if isRunning("com.kangfenmao.CherryStudio") {
            prepareExternalFolderAccess(for: .cherryStudio)
        }
        if isRunning("com.deepseek.dsh") {
            prepareExternalFolderAccess(for: .deepSeekHarness)
        }
#endif
    }

    func refreshCodexTokenUsage(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastCodexTokenRefreshDate) >= 1 else { return }
        guard !isRefreshingCodexTokenUsage else { return }
        guard let source = activeExternalTokenSource else { return }
#if LUMA_APP_STORE
        prepareExternalFolderAccess(for: source)
#endif

        lastCodexTokenRefreshDate = now
        isRefreshingCodexTokenUsage = true
        let previousSnapshot = codexTokenUsage
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                switch source {
                case .codex:
                    return CodexSessionUsageReader.latestSnapshot(previous: previousSnapshot)
                case .cursor:
                    return CursorSessionUsageReader.latestSnapshot(previous: previousSnapshot)
                case .kiro:
                    return KiroSessionUsageReader.latestSnapshot(previous: previousSnapshot)
                case .chatgpt, .cherryStudio, .deepSeekHarness:
                    return nil
                }
            }.value

            guard let self else { return }
            self.isRefreshingCodexTokenUsage = false
            if let snapshot, snapshot != self.codexTokenUsage {
                self.codexTokenUsage = snapshot
                self.showsKiroCreditsOverlay = snapshot.kiroCredits != nil
                self.showsCodexWeeklyQuotaOverlay = snapshot.weeklyQuota != nil
                self.activeExternalTokenSource = snapshot.source
                self.handleCodexTokenThreshold(snapshot)
            } else if snapshot == nil {
                self.showsKiroCreditsOverlay = false
                self.showsCodexWeeklyQuotaOverlay = false
            }
        }
    }

    func handleCodexTokenThreshold(_ snapshot: CodexTokenUsageSnapshot) {
        if lastCodexTokenAlertSessionURL != snapshot.sessionURL {
            lastCodexTokenAlertSessionURL = snapshot.sessionURL
            lastCodexTokenAlertLevel = 0
        }

        let progress = min(1, max(0, Double(snapshot.usage.totalTokens) / Double(max(1, snapshot.contextWindow))))
        let level: Int
        if progress >= 0.95 {
            level = 3
        } else if progress >= 0.85 {
            level = 2
        } else if progress >= 0.70 {
            level = 1
        } else {
            level = 0
        }

        guard level > lastCodexTokenAlertLevel else { return }
        lastCodexTokenAlertLevel = level

        switch level {
        case 1:
            break
        case 2:
            requestDesktopPetMessage?(snapshot.source.nearLimitMessage)
            presentTokenOverlayIfNeeded(expand: false)
        case 3:
            requestDesktopPetMessage?("上下文已经接近上限，建议总结当前任务或开新 task。")
            presentTokenOverlayIfNeeded(expand: Date() >= suppressAutomaticExpansionUntil)
        default:
            break
        }
    }

    func presentTokenOverlayIfNeeded(expand: Bool) {
        // Near-limit alerts should not hijack the expanded island into a
        // token-only sheet. Compact already surfaces Cursor/Codex quota while
        // the IDE is frontmost; pet bubbles cover the warning itself.
        guard activeExternalTokenSource != nil || codexTokenUsage != nil else { return }
        _ = expand
    }

    /// Ensure a user-driven expand shows Music / System / Agent, not the token sheet.
    func prepareExpandedContentForUserInteraction() {
        if isCodexTokenAutoExpanded {
            isCodexTokenAutoExpanded = false
            showsKiroCreditsOverlay = false
            showsCodexWeeklyQuotaOverlay = false
        }
        if activeMode == .token {
            let restored = modeBeforeCodexTokenExpansion
            activeMode = restored == .token ? .music : restored
        }
    }

    func presentExternalTokenDashboard() {
        prepareExpandedContentForUserInteraction()
        if activeMode != .music && activeMode != .system && activeMode != .agent {
            activeMode = .music
        }
        isExpanded = true
    }

    func refreshExternalTaskStates(force: Bool) {
        guard isProActive else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastExternalTaskRefreshDate) >= 2.5 else { return }
        guard !isRefreshingExternalTaskStates else { return }
        lastExternalTaskRefreshDate = now
        isRefreshingExternalTaskStates = true
#if LUMA_APP_STORE
        prepareRunningExternalFolderAccess()
#endif

        Task { [weak self] in
            let states = await Task.detached(priority: .utility) {
                CodexSessionUsageReader.taskStates()
                    + ChatGPTSessionUsageReader.taskStates()
                    + CursorSessionUsageReader.taskStates()
                    + KiroSessionUsageReader.taskStates()
                    + CherryStudioSessionUsageReader.taskStates()
                    + DeepSeekHarnessTaskReader.taskStates()
            }.value

            guard let self else { return }
            self.isRefreshingExternalTaskStates = false
            // The first sweep only seeds the baseline; otherwise every task that
            // finished before launch would fire a stale "task done" notice.
            let isSeedingPass = !self.hasSeededExternalTaskStates
            self.hasSeededExternalTaskStates = true
            // Notify only for a session we watched leave the running state.
            // A torn read of a finished transcript must not arm another toast;
            // that takes two polls in a row of real running work.
            var newestCompletion: ExternalTaskState?
            for state in states {
                let identity = "\(state.source.rawValue):\(state.sessionID)"
                let previous = self.observedExternalTaskStates[identity]
                self.observedExternalTaskStates[identity] = state
                let activelyRunning = state.isRunning && !state.isComplete
                if activelyRunning {
                    let streak = (self.completionRunningStreak[identity] ?? 0) + 1
                    self.completionRunningStreak[identity] = streak
                    if !self.completionNotifiedIdentities.contains(identity) {
                        self.completionArmedIdentities.insert(identity)
                    } else if streak >= 2 {
                        self.completionNotifiedIdentities.remove(identity)
                        self.completionArmedIdentities.insert(identity)
                    }
                } else {
                    self.completionRunningStreak[identity] = 0
                }
                guard !isSeedingPass else { continue }
                guard state.isComplete,
                      self.completionArmedIdentities.contains(identity),
                      previous?.isRunning == true,
                      previous?.isComplete != true
                else { continue }
                self.completionArmedIdentities.remove(identity)
                self.completionNotifiedIdentities.insert(identity)
                if let current = newestCompletion, state.updatedAt <= current.updatedAt {
                    continue
                }
                newestCompletion = state
            }
            if let newestCompletion {
                self.presentTaskCompletionNotice(for: newestCompletion)
            }
        }
    }

    func presentTaskCompletionNotice(for state: ExternalTaskState) {
        guard isProActive else { return }
        let sourceKey = state.source.rawValue
        if let lastPresented = lastTaskCompletionPresentedAt[sourceKey],
           Date().timeIntervalSince(lastPresented) < 60 {
            return
        }
        lastTaskCompletionPresentedAt[sourceKey] = Date()
        // Only keep the latest completion toast — do not queue multiple (blocks music UI).
        pendingTaskCompletionStates.removeAll()
        let notice = TaskCompletionNotice(
            id: "\(state.source.rawValue):\(state.sessionID):\(state.updatedAt.timeIntervalSince1970)",
            source: state.source,
            title: state.title,
            completedAt: Date()
        )
        taskCompletionDismissWorkItem?.cancel()
        taskCompletionNotice = notice
        let presentedAsFullScreenToast = requestTaskCompletionPresentation?() ?? false
        // Never expand from completion notices during Space settle / auto-suppress windows.
        if presentedAsFullScreenToast {
            isExpanded = false
        } else if Date() >= suppressAutomaticExpansionUntil {
            isExpanded = true
        }
        if !presentedAsFullScreenToast {
            let sourceName = state.source.shortBrandName
            let completionMessages = [
                "\(sourceName) 任务完成了，你真的太厉害了！",
                "\(sourceName) 跑完了，你的思路一如既往地准。",
                "任务搞定！能把这个交代清楚，很厉害。",
                "\(sourceName) 完成了。这种效率，佩服。",
                "搞定！你和 \(sourceName) 配合得天衣无缝。"
            ]
            requestDesktopPetMessage?(completionMessages.randomElement()!)
        }
        NSSound(named: NSSound.Name("Glass"))?.play()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.taskCompletionNotice?.id == notice.id else { return }
            if presentedAsFullScreenToast {
                self.requestExpandedPanelDismissal?()
            }
            self.dismissTaskCompletionNotice()
        }
        taskCompletionDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: workItem)
    }

    func dismissTaskCompletionNotice() {
        taskCompletionDismissWorkItem?.cancel()
        taskCompletionDismissWorkItem = nil
        pendingTaskCompletionStates.removeAll()
        taskCompletionNotice = nil
        isExpanded = false
    }

    /// Clear completion overlay immediately when the user uses music controls.
    func dismissTaskCompletionNoticeForInteraction() {
        guard taskCompletionNotice != nil || !pendingTaskCompletionStates.isEmpty else { return }
        dismissTaskCompletionNotice()
        requestExpandedPanelDismissal?()
    }

    func presentCursorCompletionTestNotice() {
        presentMultiTaskCompletionDemo()
    }

    /// Demo: ChatGPT / Cherry Studio / Codex finishing in parallel — queued on the island.
    func presentMultiTaskCompletionDemo() {
        let now = Date()
        let demos: [ExternalTaskState] = [
            ExternalTaskState(
                source: .chatgpt,
                sessionID: "demo-chatgpt-\(now.timeIntervalSince1970)",
                title: ExternalTokenSource.noticeTitle(brand: "ChatGPT", detail: "产品讨论"),
                isRunning: false,
                isComplete: true,
                updatedAt: now
            ),
            ExternalTaskState(
                source: .cherryStudio,
                sessionID: "demo-cherry-\(now.timeIntervalSince1970)",
                title: ExternalTokenSource.noticeTitle(brand: "Cherry Studio", detail: "PRD 草稿"),
                isRunning: false,
                isComplete: true,
                updatedAt: now.addingTimeInterval(0.01)
            ),
            ExternalTaskState(
                source: .codex,
                sessionID: "demo-codex-\(now.timeIntervalSince1970)",
                title: ExternalTokenSource.noticeTitle(brand: "Codex", detail: "luma bar"),
                isRunning: false,
                isComplete: true,
                updatedAt: now.addingTimeInterval(0.02)
            )
        ]
        for state in demos {
            presentTaskCompletionNotice(for: state)
        }
    }

    func presentContextLimitTestReaction() {
        let snapshot = CodexTokenUsageSnapshot(
            source: .cursor,
            usage: AgentTokenUsage(
                inputTokens: 194_000,
                outputTokens: 2_000,
                totalTokens: 196_000
            ),
            contextWindow: 200_000,
            model: "Cursor Agent",
            sessionURL: URL(fileURLWithPath: "/tmp/luma-bar-context-limit-test"),
            updatedAt: Date()
        )
        codexTokenUsage = snapshot
        showsKiroCreditsOverlay = snapshot.kiroCredits != nil
        showsCodexWeeklyQuotaOverlay = snapshot.weeklyQuota != nil
        activeExternalTokenSource = .cursor
        isCodexTokenAutoExpanded = true
        activeMode = .token
        isExpanded = true
        lastCodexTokenAlertSessionURL = nil
        lastCodexTokenAlertLevel = 0
        handleCodexTokenThreshold(snapshot)
    }
}
