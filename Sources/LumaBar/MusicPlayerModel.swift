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


@MainActor
final class MusicPlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
// MARK: - Published state
    @Published var theme = IslandTheme.saved {
        didSet {
            theme.persist()
        }
    }
    @Published var isSelectionTranslationEnabled: Bool = {
        let defaults = UserDefaults.standard
        let key = "LumaBar.selectionTranslationEnabled"
        // Copied text goes to a third-party AI service, so the store build waits for the user to opt in.
        return defaults.object(forKey: key) == nil
            ? !AppStoreDistribution.isAppStoreBuild
            : defaults.bool(forKey: key)
    }() {
        didSet {
            UserDefaults.standard.set(
                isSelectionTranslationEnabled,
                forKey: "LumaBar.selectionTranslationEnabled"
            )
        }
    }
    @Published var tracks: [LocalTrack] = []
    @Published var currentIndex = 0
    @Published var isPlaying = false
    @Published var isExpanded = false
    /// When true, expanded panel + desktop pet must not paint (Space transition / settle).
    /// WindowServer snapshot restore can briefly resurrect ordered-out windows — opacity kills that flash.
    @Published var suppressTransientIslandSurfaces = false
    @Published var isCodexTokenAutoExpanded = false
    @Published var taskCompletionNotice: TaskCompletionNotice?
    @Published var activeMode: IslandContentMode = .music
    @Published var activeAppContext: IslandAppContext = .general
    @Published var activeAppName = ""
    @Published var isAutoContextEnabled = true
    @Published var systemMetrics = SystemMetricsSnapshot()
    @Published var netEaseNowPlaying: NetEaseNowPlaying?
    @Published var resolvedNetEaseTrack: LocalTrack?
    @Published var netEasePlaylists: [NetEasePlaylist] = []
    @Published var selectedNetEasePlaylistTracks: [LocalTrack] = []
    @Published var selectedNetEasePlaylistID: String?
    @Published var isUsingNetEase = false
    @Published var appleMusicNowPlaying: MusicNowPlayingInfo?
    @Published var resolvedAppleMusicTrack: LocalTrack?
    @Published var isUsingAppleMusic = false
    /// The single source that owns island play/pause routing and exclusive audio.
    @Published var activeMusicSource: IslandMusicLibrarySource = .local
    /// Cancels stale ensureSinglePlayerPlaying play callbacks when the user clicks rapidly.
    var exclusivePlayGeneration: UInt64 = 0
    /// History lags a play-by-id command by several seconds. Until it catches up, ignore the
    /// previous song so the panel does not snap backwards.
    var pinnedNetEaseIdentity = ""
    var pinnedNetEaseSongID = ""
    var pinnedNetEaseUntil = Date.distantPast
    /// First empty NetEase sample of the current gap while a song was playing.
    var netEaseNowPlayingMissSince: Date?
    @Published var musicLibrarySource: IslandMusicLibrarySource = .local
    /// User manually picked a library channel — polling / frontmost-app heuristics must not steal it.
    var musicSourceUserLocked = false
    @Published var isScanning = false
    @Published var scanMessage = LumaBarL10n.scanScanning
    @Published var position: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var agentInput = ""
    @Published var agentResponse = LumaBarL10n.agentReadyDetail
    @Published var agentStatus = LumaBarL10n.agentReady
    @Published var agentAPIKeyDraft = ""
    @Published var agentHasAPIKey = AgentCredentialStore.currentAPIKey() != nil
    @Published var isAgentStreaming = false
    @Published var agentTokenUsage = AgentTokenUsage.saved {
        didSet {
            agentTokenUsage.persist()
        }
    }
    @Published var codexTokenUsage: CodexTokenUsageSnapshot?
    @Published var showsKiroCreditsOverlay = false
    @Published var showsCodexWeeklyQuotaOverlay = false
    @Published var agentLiveEstimatedTokens = 0
    @Published var pendingAgentShellCommand: String?
    @Published var pendingMessageAction: PendingMessageAction?
    @Published var isMessageConfirmationPending = false
    @Published var isAgentShellConfirmationPending = false
    @Published var isAgentShellRequestMode = false
    @Published var isAgentShellRunning = false
    @Published var isVoiceWhisperRecording = false
    @Published var isVoiceWhisperFinalizing = false
    @Published var voiceWhisperTranscript = ""
    @Published var desktopPetMood: DesktopPetMood = .idle
    @Published var agentFocusRequestID = UUID()
    @Published var volume: Double = SystemAudioController.outputVolume() ?? 0.82 {
        didSet {
            if isSyncingSystemVolume {
                audioPlayer?.volume = 1.0
                return
            }

            suppressSystemVolumeSyncUntil = Date().addingTimeInterval(0.35)
            let didSetSystemVolume = SystemAudioController.setOutputVolume(volume)
            audioPlayer?.volume = didSetSystemVolume ? 1.0 : Float(volume)
        }
    }
    @Published var cameraGapWidth = NotchMetrics.fallbackCameraGap

// MARK: - Host callbacks
    var requestExpandedPanelPreservation: ((String, TimeInterval) -> Void)?
    var requestExpandedPanelDismissal: (() -> Void)?
    var requestDesktopPetMessage: ((String) -> Void)?
    var requestTaskCompletionPresentation: (() -> Bool)?

// MARK: - Private engine state
    var audioPlayer: AVAudioPlayer?
    /// True only while `audioPlayer` holds a NetEase download. A local-library song left in the
    /// engine must never answer NetEase's Play button or hide what the NetEase client is playing.
    var audioPlayerHoldsNetEaseDownload = false

    var netEaseDownloadPlayer: AVAudioPlayer? {
        audioPlayerHoldsNetEaseDownload ? audioPlayer : nil
    }
    lazy var voiceSpeechRecognizer: SFSpeechRecognizer? = {
        SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans-CN"))
            ?? SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }()
    var voiceAudioSession: (any VoiceWhisperSession)?
    var voiceWhisperFinalizationWorkItem: DispatchWorkItem?
    var timer: Timer?
    var isSyncingSystemVolume = false
    var isAdjustingSystemVolume = false
    var suppressSystemVolumeSyncUntil = Date.distantPast
    var suppressAutomaticExpansionUntil = Date.distantPast

    /// Exposed so AppDelegate can ignore hover expand during Space settle.
    var suppressAutomaticExpansionUntilDate: Date { suppressAutomaticExpansionUntil }
    var codingSessionStartDate: Date?
    var lastWorkReminderDate = Date.distantPast
    var desktopPetReminderUntil = Date.distantPast
    var desktopPetHighCPUSince: Date?
    var nextProactivePetMessageDate = Date().addingTimeInterval(Double.random(in: 75...140))
    var lastProactivePetMessage = ""
    var petWeatherSnapshot: PetWeatherSnapshot?
    var lastPetWeatherRefreshDate = Date.distantPast
    var petWeatherTask: Task<Void, Never>?
    var lastCPUTicks: CPUTicks?
    var lastNetworkCounter: NetworkCounter?
    var lastSystemMetricsDate = Date.distantPast
    var lastApplicationContextRefreshDate = Date.distantPast
    var lastNetEaseRefreshDate = Date.distantPast
    /// After a user force-pause, ignore stale MediaRemote "playing" samples briefly.
    var suppressNetEasePlayingUntil = Date.distantPast
    /// Last play/pause we sent. CoreAudio keeps reporting "running" after a pause, so the next
    /// press must follow this instead of the lagging flag — otherwise it sends pause again.
    var netEaseCommandedPlayingValue: Bool?
    var netEaseCommandedPlayingAt = Date.distantPast

    /// The play state Luma Bar last asked NetEase for. The direct build reads NetEase's real state
    /// through MediaRemote, so the command only bridges the gap until NetEase reports; if NetEase
    /// stops on its own, a stale "playing" must not make the Play button send pause.
    var netEaseCommandedPlaying: Bool? {
        get {
#if !LUMA_APP_STORE
            // Match `suppressNetEasePlayingUntil` (8s). Expiring earlier lets laggy
            // MediaRemote flip Play back into Pause and makes buttons feel dead.
            if Date().timeIntervalSince(netEaseCommandedPlayingAt) > 8 { return nil }
#endif
            return netEaseCommandedPlayingValue
        }
        set {
            netEaseCommandedPlayingValue = newValue
            netEaseCommandedPlayingAt = Date()
        }
    }
    /// Once the user pauses, the history wall clock is no longer the playhead. Keep the frozen
    /// lyric time instead of snapping forward by the length of the pause.
    var netEaseHoldPosition = false
    var musicLibrarySourceUserPinUntil = Date.distantPast
    var pendingNetEasePlaylistCoverIDs = Set<String>()
    var pendingNetEasePlaylistTrackArtworkIDs = Set<String>()
    var currentNetEaseTrackIdentity = ""
    var netEaseDetailsRequestToken = UUID()
    var isResolvingNetEaseDetails = false
    var netEaseLyricsTask: URLSessionDataTask?
    var netEaseArtworkTask: URLSessionDataTask?
    var lastNetEaseLyricsRetryDate = Date.distantPast
    var pendingNetEaseSeek: (position: TimeInterval, expiresAt: Date)?
    var pendingAppleMusicSeek: (position: TimeInterval, expiresAt: Date)?
    /// NetEase playhead via timestamp interpolation (same algorithm as Apple Music).
    var netEaseProgressClock = PlaybackProgressClock()
    /// True while the user is scrubbing the seek bar (and briefly after commit settle).
    @Published var isSeekingPlayback = false
    /// Normalized 0...1 preview while `isSeekingPlayback` is locked.
    @Published var seekPreviewProgress: Double = 0
    /// Freeze play/pause icon while scrubbing so system glitches can't flip it.
    var seekLockedIsPlaying: Bool?
    var seekUnlockWorkItem: DispatchWorkItem?
    var currentAppleMusicTrackIdentity = ""
    var appleMusicLyricsFinishedIdentity = ""
    var appleMusicLyricsTask: Task<Void, Never>?
    var agentTask: Task<Void, Never>?
    var agentRequestToken = UUID()
    var isSelectionTranslationActive = false
    var activeExternalApplicationPID: pid_t?
    var activeExternalBundleIdentifier = ""
    var shellConfirmationResetWorkItem: DispatchWorkItem?
    var messageConfirmationResetWorkItem: DispatchWorkItem?
    var lastTranslatedSelection = ""
    var lastSelectionTranslationDate = Date.distantPast
    var cachedSelectionContext: AgentWorkspaceContext?
    var cachedSelectionDate = Date.distantPast
    var modeBeforeCodexTokenExpansion: IslandContentMode = .music
    var activeExternalTokenSource: ExternalTokenSource?
    var lastCodexTokenRefreshDate = Date.distantPast
    var isRefreshingCodexTokenUsage = false
    var lastCodexTokenAlertSessionURL: URL?
    var lastCodexTokenAlertLevel = 0
    var lastExternalTaskRefreshDate = Date.distantPast
    var lastExclusiveAudioReconcileDate = Date.distantPast
    var isRefreshingExternalTaskStates = false
    var observedExternalTaskStates: [String: ExternalTaskState] = [:]
    var hasSeededExternalTaskStates = false
    /// Sessions we have actually seen running, so a finished file cannot toast on sight.
    var completionArmedIdentities: Set<String> = []
    /// Already toasted. Re-armed only after the session runs for two polls in a row.
    var completionNotifiedIdentities: Set<String> = []
    var completionRunningStreak: [String: Int] = [:]
    var lastTaskCompletionPresentedAt: [String: Date] = [:]
    var pendingTaskCompletionStates: [ExternalTaskState] = []
    var taskCompletionDismissWorkItem: DispatchWorkItem?
    var agentModelName: String {
        AgentModelProvider.current.defaultModel
    }

    var agentUsesBundledCredential: Bool {
        AgentCredentialStore.usesBundledCredential
    }

    var agentShowsAPIKeySetup: Bool {
        AgentCredentialStore.showsAPIKeySetup
    }
    var agentTokenLimit: Int {
        let configured = ProcessInfo.processInfo.environment["LUMA_BAR_OPENAI_TOKEN_LIMIT"]
            .flatMap(Int.init)
        return max(1_000, configured ?? 128_000)
    }
    let workReminderInterval: TimeInterval = {
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["LUMA_BAR_WORK_REMINDER_SECONDS"].flatMap(TimeInterval.init)
        return max(60, configured ?? 7_200)
    }()
// MARK: - Lifecycle
    override init() {
        super.init()
        AgentCredentialStore.clearKeychainOverrideIfBundled()
        agentHasAPIKey = AgentCredentialStore.currentAPIKey() != nil
        refreshSystemMetrics(force: true)
        refreshPetWeatherIfNeeded(now: Date())
        timer = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(timerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        AppleMusicService.shared.startMonitoring { [weak self] in
            self?.applyAppleMusicNowPlaying(AppleMusicService.shared.currentTrack)
        }
    }

    /// Always unlocked while preparing Mac App Store / free distribution.
    var isProActive: Bool { true }

    var currentTrack: LocalTrack? {
        let list = activePlaybackList
        guard list.indices.contains(currentIndex) else { return nil }
        return list[currentIndex]
    }

    /// Queue used by play / next / previous — always matches the visible library channel.
    var currentPlaybackList: [LocalTrack] {
        activePlaybackList
    }

    /// Source-exclusive track queue. Local never falls through to a NetEase playlist.
    var activePlaybackList: [LocalTrack] {
        switch musicLibrarySource {
        case .local:
            return Self.localPlayableTracks(from: tracks)
        case .netEase:
            if selectedNetEasePlaylistID != nil, !selectedNetEasePlaylistTracks.isEmpty {
                return selectedNetEasePlaylistTracks
            }
            return tracks
        case .appleMusic:
            return []
        }
    }

    /// Audio files Luma Bar can play with AVAudioPlayer (never `.ncm` / remote NetEase IDs).
    nonisolated static func localPlayableTracks(from tracks: [LocalTrack]) -> [LocalTrack] {
        tracks.filter(isLocallyPlayableFile)
    }

    nonisolated static func isLocallyPlayableFile(_ track: LocalTrack) -> Bool {
        track.url.isFileURL && isSelfDecodableAudio(track.url)
    }

    var isCodingContext: Bool {
        activeAppContext == .coding
    }

    var usesCompactExpandedOverlay: Bool {
        isCodexTokenAutoExpanded || taskCompletionNotice != nil
    }

    var showsKiroCredits: Bool {
        showsKiroCreditsOverlay
    }

    var showsCodexWeeklyQuota: Bool {
        showsCodexWeeklyQuotaOverlay
    }

    var kiroCreditsUsage: KiroCreditsUsage? {
        guard isCodexTokenAutoExpanded else { return nil }
        return codexTokenUsage?.kiroCredits
    }

    var codexWeeklyQuota: CodexWeeklyQuota? {
        guard isCodexTokenAutoExpanded else { return nil }
        return codexTokenUsage?.weeklyQuota
    }

    var kiroCreditsAccentColor: Color {
        guard let credits = kiroCreditsUsage else { return agentTokenAccentColor }
        let progress = credits.progress
        if progress >= 0.95 { return Color.islandRed }
        if progress >= 0.85 { return Color.islandTangerine }
        if progress >= 0.70 { return theme.primaryAccent }
        return theme.isLight ? theme.primaryAccent.opacity(0.92) : Color.islandGreen
    }

    var codexWeeklyQuotaAccentColor: Color {
        guard let quota = codexWeeklyQuota else { return agentTokenAccentColor }
        let progress = quota.progress
        if progress >= 0.95 { return Color.islandRed }
        if progress >= 0.85 { return Color.islandTangerine }
        if progress >= 0.70 { return theme.primaryAccent }
        return theme.isLight ? theme.primaryAccent.opacity(0.92) : Color.islandGreen
    }

    var isNetEaseContext: Bool {
        activeAppContext == .netEase
    }

    var agentContextLabel: String {
        let app = activeAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        return app.isEmpty ? activeAppContext.label : "\(activeAppContext.label) · \(app)"
    }

    var agentContextIcon: String {
        activeAppContext.icon
    }

// MARK: - Presentation helpers
    func refreshLocalizedChromeAfterLanguageChange() {
        guard !isAgentStreaming, !isAgentShellRunning, !isVoiceWhisperRecording, !isVoiceWhisperFinalizing else {
            objectWillChange.send()
            return
        }
        // Idle chrome must always track the active UI language (status + detail together).
        if agentHasAPIKey {
            agentStatus = LumaBarL10n.agentReady
            agentResponse = LumaBarL10n.agentReadyDetail
        } else {
            agentStatus = LumaBarL10n.agentAPIKeyNeeded
            agentResponse = LumaBarL10n.agentConfigureKey(AgentModelProvider.current.displayName)
        }
        objectWillChange.send()
    }

    var agentInputPlaceholder: String {
        if isAgentShellRequestMode {
            return LumaBarL10n.agentPlaceholderShell
        }

        switch activeAppContext {
        case .coding:
            return LumaBarL10n.agentPlaceholderCode
        case .writing:
            return LumaBarL10n.agentPlaceholderWriting
        case .reading:
            return LumaBarL10n.agentPlaceholderReading
        case .gaming:
            return LumaBarL10n.agentPlaceholderGaming
        case .netEase:
            return LumaBarL10n.agentPlaceholderMusic
        case .general:
            return LumaBarL10n.agentPlaceholderGeneral
        }
    }

    var agentQuickActions: [AgentQuickAction] {
        guard isSelectionTranslationActive else {
            return []
        }

        switch activeAppContext {
        case .coding:
            return [
                AgentQuickAction(kind: .explainCode, title: LumaBarL10n.quickExplain, icon: "text.magnifyingglass"),
                AgentQuickAction(kind: .refactorCode, title: LumaBarL10n.quickRefactor, icon: "wand.and.stars"),
                AgentQuickAction(kind: .commentCode, title: LumaBarL10n.quickComment, icon: "text.bubble"),
                AgentQuickAction(kind: .shell, title: LumaBarL10n.quickShell, icon: "terminal")
            ]
        case .writing:
            return [
                AgentQuickAction(kind: .professionalWriting, title: LumaBarL10n.quickProfessional, icon: "briefcase"),
                AgentQuickAction(kind: .simplifyWriting, title: LumaBarL10n.quickSimplify, icon: "textformat.size.smaller"),
                AgentQuickAction(kind: .proofreadWriting, title: LumaBarL10n.quickProofread, icon: "checkmark.seal"),
                AgentQuickAction(kind: .outlineWriting, title: LumaBarL10n.quickOutline, icon: "list.bullet.indent")
            ]
        case .reading:
            return [
                AgentQuickAction(kind: .summarizePage, title: LumaBarL10n.quickTLDR, icon: "text.alignleft"),
                AgentQuickAction(kind: .keyTakeaways, title: LumaBarL10n.quickKeyPoints, icon: "key.fill"),
                AgentQuickAction(kind: .explainConcept, title: LumaBarL10n.quickExplain, icon: "questionmark.circle"),
                AgentQuickAction(kind: .shell, title: LumaBarL10n.quickShell, icon: "terminal")
            ]
        case .gaming:
            return [
                AgentQuickAction(kind: .gameGuide, title: LumaBarL10n.quickGuide, icon: "map"),
                AgentQuickAction(kind: .gameBuild, title: LumaBarL10n.quickBuild, icon: "hammer"),
                AgentQuickAction(kind: .gameScreenshot, title: LumaBarL10n.quickScreen, icon: "viewfinder"),
                AgentQuickAction(kind: .gameMusic, title: LumaBarL10n.modeMusic, icon: "music.note")
            ]
        case .netEase:
            return [
                AgentQuickAction(kind: .playPause, title: displayedIsPlaying ? "Pause" : "Play", icon: displayedIsPlaying ? "pause.fill" : "play.fill"),
                AgentQuickAction(kind: .nextTrack, title: LumaBarL10n.quickNext, icon: "forward.fill"),
                AgentQuickAction(kind: .gameMusic, title: LumaBarL10n.quickMood, icon: "music.note.list"),
                AgentQuickAction(kind: .system, title: LumaBarL10n.modeSystem, icon: "cpu")
            ]
        case .general:
            return [
                AgentQuickAction(kind: .system, title: LumaBarL10n.modeSystem, icon: "cpu"),
                AgentQuickAction(kind: .playPause, title: displayedIsPlaying ? "Pause" : "Play", icon: displayedIsPlaying ? "pause.fill" : "play.fill"),
                AgentQuickAction(kind: .nextTrack, title: LumaBarL10n.quickNext, icon: "forward.fill"),
                AgentQuickAction(kind: .shell, title: LumaBarL10n.quickShell, icon: "terminal")
            ]
        }
    }

    var systemDisplayTitle: String {
        isCodingContext ? "Code Monitor" : "System Monitor"
    }

    var systemDisplaySubtitle: String {
        "CPU \(systemMetrics.cpuText)  MEM \(systemMetrics.memoryText)"
    }

    var agentModelDisplayName: String {
        let rawName: String
        if usesExternalTokenDisplay {
            guard let externalModel = codexTokenUsage?.model else {
                return "读取模型…"
            }
            rawName = externalModel
        } else {
            rawName = agentModelName
        }
        let normalizedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.lowercased().hasPrefix("gpt-") {
            return "GPT \(normalizedName.dropFirst(4))"
        }

        return normalizedName
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + String(word.dropFirst())
            }
            .joined(separator: " ")
    }

    var agentDisplayedTokenTotal: Int {
        if usesExternalTokenDisplay {
            return codexTokenUsage?.usage.totalTokens ?? 0
        }
        return isAgentStreaming
            ? max(agentTokenUsage.totalTokens, agentLiveEstimatedTokens)
            : agentTokenUsage.totalTokens
    }

    var displayedTokenLimit: Int {
        if usesExternalTokenDisplay, let codexTokenUsage {
            return codexTokenUsage.contextWindow
        }
        return agentTokenLimit
    }

    var displayedTokenUsage: AgentTokenUsage {
        if usesExternalTokenDisplay {
            return codexTokenUsage?.usage ?? AgentTokenUsage()
        }
        return agentTokenUsage
    }

    /// True while Cursor / Codex / Kiro is frontmost and we are sampling its context window.
    var isMonitoringExternalTokenUsage: Bool {
        activeExternalTokenSource != nil
    }

    /// Compact bar prefers quota/context while Cursor/Codex is frontmost,
    /// without forcing the expanded panel into the dedicated token dashboard.
    var shouldShowExternalTokenInCompact: Bool {
        guard isMonitoringExternalTokenUsage else { return false }
        return activeMode == .music || activeMode == .token
    }

    var usesExternalTokenDisplay: Bool {
        isCodexTokenAutoExpanded || isMonitoringExternalTokenUsage
    }

    var agentTokenProgress: Double {
        min(1, max(0, Double(agentDisplayedTokenTotal) / Double(max(1, displayedTokenLimit))))
    }

    var agentTokenAccentColor: Color {
        if theme.isNook {
            if agentTokenProgress >= 0.95 {
                return Color(red: 0.69, green: 0.286, blue: 0.302)
            }
            if agentTokenProgress >= 0.85 {
                return Color(red: 0.765, green: 0.349, blue: 0.271)
            }
            if agentTokenProgress >= 0.70 {
                return Color(red: 0.82, green: 0.455, blue: 0.275)
            }
            return Color(red: 0.79, green: 0.40, blue: 0.275)
        }
        if agentTokenProgress >= 0.95 {
            return Color.islandRed
        }
        if agentTokenProgress >= 0.85 {
            return Color.islandTangerine
        }
        if agentTokenProgress >= 0.70 {
            return Color(red: 1.0, green: 0.76, blue: 0.26)
        }
        return usesExternalTokenDisplay ? Color.islandGreen : themeTokenFallbackColor
    }

    var themeTokenFallbackColor: Color {
        activeMode == .token ? Color.islandGreen : Color.islandCyan
    }

    var agentTokenPercentText: String {
        "\(Int((agentTokenProgress * 100).rounded()))%"
    }

    var agentRemainingTokens: Int {
        max(0, displayedTokenLimit - agentDisplayedTokenTotal)
    }

    var externalTokenBrandLabel: String {
        (codexTokenUsage?.source ?? activeExternalTokenSource)?.brandLabel ?? "AI CONTEXT"
    }

    var externalTokenAccessibilityLabel: String {
        (codexTokenUsage?.source ?? activeExternalTokenSource)?.accessibilityLabel ?? LumaBarL10n.agentAITokenUsage
    }

    var agentTokenStateText: String {
        if usesExternalTokenDisplay {
            let source = codexTokenUsage?.source ?? activeExternalTokenSource
            return codexTokenUsage == nil
                ? (source?.readingLabel ?? LumaBarL10n.agentReadingContext)
                : LumaBarL10n.agentCurrentContext
        }
        if isAgentStreaming { return LumaBarL10n.agentThinking }
        if agentTokenUsage.totalTokens > 0 { return LumaBarL10n.agentLastRequest }
        return agentHasAPIKey ? LumaBarL10n.agentReady : LumaBarL10n.agentAPIKeyNeeded
    }

    var agentTokenSummaryText: String {
        "\(Self.compactTokenCount(agentDisplayedTokenTotal)) / \(Self.compactTokenCount(displayedTokenLimit))"
    }

    var agentInputTokenText: String {
        Self.compactTokenCount(displayedTokenUsage.inputTokens)
    }

    var agentOutputTokenText: String {
        Self.compactTokenCount(displayedTokenUsage.outputTokens)
    }

    var agentRemainingTokenText: String {
        Self.compactTokenCount(agentRemainingTokens)
    }

    var compactAgentTitle: String {
        isAgentStreaming ? LumaBarL10n.agentStreaming(AgentModelProvider.current.displayName) : activeAppContext.agentTitle
    }

    var compactAgentSubtitle: String {
        if isVoiceWhisperRecording {
            return LumaBarL10n.agentVoiceInput
        }
        if isAgentShellRunning {
            return LumaBarL10n.agentRunningCommand
        }
        if isAgentStreaming {
            return agentResponse.isEmpty ? LumaBarL10n.agentConnecting : LumaBarL10n.agentWriting
        }
        return agentHasAPIKey ? agentStatus : LumaBarL10n.agentAPIKeyNeeded
    }

    var desktopPetMoodMessage: String? {
        switch desktopPetMood {
        case .idle:
            return nil
        case .hot:
            return "系统温度或 CPU 负载持续偏高：CPU \(systemMetrics.cpuText)。"
        case .working:
            return isAgentShellRunning ? "我在后台搬命令，跑完就汇报结果。" : "AI 正在打字，先把思路交给我。"
        case .stretch:
            return "已经连续写代码很久了，喝口水，伸个懒腰。"
        case .voice:
            return "我在听，讲完再按 ⌘⇧M。"
        }
    }

    var activeDisplayTitle: String {
        switch activeMode {
        case .music:
            return displayedTitle
        case .system:
            return systemDisplayTitle
        case .agent:
            return compactAgentTitle
        case .token:
            return agentModelDisplayName
        }
    }

    var activeDisplaySubtitle: String {
        switch activeMode {
        case .music:
            return displayedSubtitle
        case .system:
            return systemDisplaySubtitle
        case .agent:
            return compactAgentSubtitle
        case .token:
            return agentTokenSummaryText
        }
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    static func compactTokenCount(_ value: Int) -> String {
        guard value >= 1_000 else { return "\(value)" }

        let thousands = Double(value) / 1_000
        if thousands >= 100 || thousands.rounded() == thousands {
            return "\(Int(thousands.rounded()))K"
        }
        return String(format: "%.1fK", thousands)
    }

    var compactMusicTitle: String {
        if isDisplayingAppleMusicNowPlaying {
            return displayedTitle
        }
        if isNetEaseContext, !netEasePlaylists.isEmpty {
            return "NetEase Playlists"
        }

        return displayedTitle
    }

    var compactMusicSubtitle: String {
        if isDisplayingAppleMusicNowPlaying {
            return displayedArtist
        }
        if isNetEaseContext, let playlist = netEasePlaylists.first {
            return playlist.name
        }

        return displayedArtist
    }

    var displayedTitle: String {
        if isDisplayingAppleMusicNowPlaying, let appleMusicNowPlaying {
            return appleMusicNowPlaying.title
        }
        if isDisplayingNetEaseNowPlaying, let netEaseNowPlaying {
            return netEaseNowPlaying.title
        }
        return currentTrack?.title ?? scanMessage
    }

    var displayedArtist: String {
        if isDisplayingAppleMusicNowPlaying, let appleMusicNowPlaying {
            return appleMusicNowPlaying.artist
        }
        if isDisplayingNetEaseNowPlaying, let netEaseNowPlaying {
            return netEaseNowPlaying.artist
        }
        return currentTrack?.displayArtist ?? "luma bar"
    }

    var displayedSubtitle: String {
        if isDisplayingAppleMusicNowPlaying, let appleMusicNowPlaying {
            return appleMusicNowPlaying.album.isEmpty
                ? appleMusicNowPlaying.artist
                : "\(appleMusicNowPlaying.artist) • \(appleMusicNowPlaying.album)"
        }
        if isDisplayingNetEaseNowPlaying, let netEaseNowPlaying {
            return netEaseNowPlaying.album.isEmpty
                ? netEaseNowPlaying.artist
                : "\(netEaseNowPlaying.artist) • \(netEaseNowPlaying.album)"
        }
        return currentTrack?.displaySubtitle ?? LumaBarL10n.libraryLocalSubtitle
    }

    var displayedArtworkData: Data? {
        if isDisplayingAppleMusicNowPlaying {
            return appleMusicNowPlaying?.artworkData ?? resolvedAppleMusicTrack?.artworkData
        }
        if isDisplayingNetEaseNowPlaying, let netEaseNowPlaying {
            if resolvedNetEasePresentationMatches(netEaseNowPlaying) {
                return resolvedNetEaseTrack?.artworkData ?? netEaseNowPlaying.artworkData
            }
            return netEaseNowPlaying.artworkData
        }
        return currentTrack?.artworkData
    }

    var displayedPosition: TimeInterval {
        if isSeekingPlayback {
            return max(0, displayedDuration * seekPreviewProgress)
        }
        if isDisplayingAppleMusicNowPlaying {
            return AppleMusicService.shared.playbackTime
        }
        if isDisplayingNetEaseNowPlaying {
            if let audioPlayer = netEaseDownloadPlayer {
                return audioPlayer.currentTime
            }
            return netEaseProgressClock.calculatedCurrentTime()
        }
        // Live playhead for lyrics / seek UI — do not use the throttled @Published
        // `position` (1s steps), or the lyric pane jumps and flickers.
        return audioPlayer?.currentTime ?? position
    }

    /// Whether `displayedPosition` is close enough to the real playhead to drive lyric highlighting.
    var displayedPositionIsReliable: Bool {
        guard isDisplayingNetEaseNowPlaying else { return true }
        if netEaseDownloadPlayer != nil { return true }
        return netEaseNowPlaying?.positionIsReliable ?? false
    }

    var displayedDuration: TimeInterval {
        if isDisplayingAppleMusicNowPlaying {
            return appleMusicNowPlaying?.duration ?? AppleMusicService.shared.duration
        }
        if isDisplayingNetEaseNowPlaying {
            if let audioPlayer = netEaseDownloadPlayer, audioPlayer.duration > 0 {
                return audioPlayer.duration
            }
            return netEaseNowPlaying?.duration ?? netEaseProgressClock.duration
        }
        return duration
    }

    var displayedIsPlaying: Bool {
        if isSeekingPlayback, let seekLockedIsPlaying {
            return seekLockedIsPlaying
        }
        if isDisplayingAppleMusicNowPlaying {
            // Single source of truth: Music.app player state mirrored by AppleMusicService.
            return AppleMusicService.shared.playerState == .playing
        }
        if isDisplayingNetEaseNowPlaying {
            if let audioPlayer = netEaseDownloadPlayer {
                return audioPlayer.isPlaying
            }
            return netEaseNowPlaying?.isPlaying ?? netEaseProgressClock.isPlaying
        }
        return isPlaying
    }

    var displayedProgress: Double {
        if isSeekingPlayback {
            return min(1, max(0, seekPreviewProgress))
        }
        let duration = displayedDuration
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayedPosition / duration))
    }

    /// Store builds cannot move a song NetEase itself is playing. Local files and Apple Music can.
    var canSeekPlayback: Bool {
        guard showsPlaybackTimeline, displayedDuration > 0 else { return false }
        // The store build cannot send NetEase a seek. Only a downloaded copy we decode ourselves can move.
#if LUMA_APP_STORE
        if shouldRouteControlsToNetEase {
            return netEaseLocalCopyOfCurrentSong != nil
        }
#endif
        return true
    }

    /// Why the timeline cannot be dragged, for the tooltip.
    var seekUnavailableReason: String {
#if LUMA_APP_STORE
        if shouldRouteControlsToNetEase, showsPlaybackTimeline {
            return LumaBarL10n.musicNetEaseNoSeek
        }
#endif
        return LumaBarL10n.musicNoTimeline
    }

    /// NetEase's own play state. The direct build has MediaRemote's playback rate; the store build
    /// only knows whether NetEase is producing sound.
    var netEaseReportedPlaying: Bool {
#if LUMA_APP_STORE
        return NetEaseAudioActivity.isAudible
#else
        return netEaseNowPlaying?.isPlaying ?? NetEaseAudioActivity.isAudible
#endif
    }

    var netEaseLocalCopyCache: (key: String, track: LocalTrack?)?

    /// The self-decodable download of the song the NetEase client is playing, if it is in the list on screen.
    var netEaseLocalCopyOfCurrentSong: LocalTrack? {
        guard netEaseDownloadPlayer == nil, let nowPlaying = netEaseNowPlaying else { return nil }
        let queue = activePlaybackList
        let key = [
            nowPlaying.songID,
            nowPlaying.title,
            nowPlaying.artist,
            selectedNetEasePlaylistID ?? "",
            String(queue.count),
            queue.first?.url.absoluteString ?? ""
        ].joined(separator: "|")
        if let cache = netEaseLocalCopyCache, cache.key == key {
            return cache.track
        }
        let match = indexOfPlayingNetEaseTrack(in: queue).map { queue[$0] }
        let copy = match.flatMap { Self.isLocallyPlayableFile($0) ? $0 : nil }
        netEaseLocalCopyCache = (key, copy)
        return copy
    }

    /// NetEase does not publish a playhead. The store build draws the estimate anchored on the
    /// history row's start time, and only while that estimate still holds.
    var showsPlaybackTimeline: Bool {
#if LUMA_APP_STORE
        if shouldRouteControlsToNetEase {
            return displayedDuration > 0 && displayedPositionIsReliable
        }
#endif
        return true
    }

    var isDisplayingAppleMusicNowPlaying: Bool {
        // Visible library channel wins — never show a rival source over a user lock.
        switch musicLibrarySource {
        case .appleMusic:
            return appleMusicNowPlaying != nil
        case .netEase:
            return false
        case .local:
            guard !musicSourceUserLocked else { return false }
            return isUsingAppleMusic
                || (audioPlayer == nil && isAppleMusicContext && appleMusicNowPlaying != nil)
        }
    }

    var isDisplayingNetEaseNowPlaying: Bool {
        switch musicLibrarySource {
        case .netEase:
            return netEaseNowPlaying != nil
        case .appleMusic:
            return false
        case .local:
            guard !musicSourceUserLocked else { return false }
            return isUsingNetEase
                || (audioPlayer == nil && isNetEaseContext && netEaseNowPlaying != nil)
        }
    }

    var isAppleMusicContext: Bool {
        activeExternalBundleIdentifier == "com.apple.Music"
    }

    var shouldRouteControlsToAppleMusic: Bool {
        // Visible channel is absolute while the user has locked a source.
        switch musicLibrarySource {
        case .appleMusic:
            return true
        case .netEase:
            return false
        case .local:
            return activeMusicSource == .appleMusic
                || (isUsingAppleMusic && !musicSourceUserLocked)
                || (!musicSourceUserLocked && audioPlayer == nil && isAppleMusicContext)
        }
    }

    var shouldRouteControlsToNetEase: Bool {
        // Whoever produces the sound owns the transport. When we decode the file ourselves — which
        // includes NetEase downloads in a format we can read — our own engine has real next,
        // previous, and seek, and NetEase has none of the three.
        switch musicLibrarySource {
        case .netEase:
            return netEaseDownloadPlayer == nil
        case .appleMusic:
            return false
        case .local:
            // Local channel never routes to NetEase unless local itself owns playback
            // as NetEase (should not happen after exclusivity claim).
            return audioPlayer == nil
                && activeMusicSource == .netEase && isUsingNetEase && !musicSourceUserLocked
        }
    }

    var shouldRouteControlsToSystemPlayer: Bool {
        guard audioPlayer == nil else { return false }
        return [
            "com.spotify.client",
            "org.videolan.vlc",
            "com.colliderli.iina"
        ].contains(activeExternalBundleIdentifier)
    }

    var selectedNetEasePlaylist: NetEasePlaylist? {
        guard let selectedNetEasePlaylistID else { return nil }
        return netEasePlaylists.first { $0.id == selectedNetEasePlaylistID }
    }

    var displayedTrackList: [LocalTrack] {
        switch musicLibrarySource {
        case .netEase:
            if selectedNetEasePlaylistID != nil {
                return selectedNetEasePlaylistTracks
            }
            return tracks
        case .appleMusic:
            // Apple Music mirrors Music.app — no local track catalog yet.
            return []
        case .local:
            return Self.localPlayableTracks(from: tracks)
        }
    }

    var displayedTrackListMessage: String {
        switch musicLibrarySource {
        case .netEase:
            if selectedNetEasePlaylistID != nil {
                return selectedNetEasePlaylistTracks.isEmpty ? scanMessage : ""
            }
            return scanMessage
        case .appleMusic:
            if appleMusicNowPlaying != nil {
                return LumaBarL10n.appleMusicPlaying
            }
            return LumaBarL10n.appleMusicEmpty
        case .local:
            return Self.localPlayableTracks(from: tracks).isEmpty
                ? (scanMessage.isEmpty ? LumaBarL10n.noLocalSongs : scanMessage)
                : ""
        }
    }

    var displayedLyricsTrack: LocalTrack? {
        if isDisplayingAppleMusicNowPlaying {
            return resolvedAppleMusicTrack ?? appleMusicPlaceholderTrack
        }
        guard isDisplayingNetEaseNowPlaying, let netEaseNowPlaying else { return currentTrack }
        // A history row past its own duration is not the song being heard. Showing its
        // lyrics, or a similarly titled song from the playlist, puts the wrong words on screen.
        if netEaseHistoryRowIsStale {
            return netEaseLyricShell(netEaseNowPlaying)
        }
        if resolvedNetEasePresentationMatches(netEaseNowPlaying), let resolvedNetEaseTrack {
            return resolvedNetEaseTrack
        }
        return netEaseLyricShell(netEaseNowPlaying)
    }

    /// Audio is still running, but this history row has already run past the song's length.
    var netEaseHistoryRowIsStale: Bool {
        guard let nowPlaying = netEaseNowPlaying else { return false }
        guard nowPlaying.isPlaying, nowPlaying.duration > 1, !nowPlaying.positionIsReliable else { return false }
        return nowPlaying.position + 0.25 >= nowPlaying.duration
    }

    var appleMusicPlaceholderTrack: LocalTrack? {
        guard let appleMusicNowPlaying else { return nil }
        let identity = Self.appleMusicTrackIdentity(
            title: appleMusicNowPlaying.title,
            artist: appleMusicNowPlaying.artist,
            album: appleMusicNowPlaying.album
        )
        let id = URL(string: "apple-music://track/\(identity.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "current")")
            ?? URL(fileURLWithPath: "/apple-music/\(identity)")
        return LocalTrack(
            id: id,
            url: id,
            title: appleMusicNowPlaying.title,
            artist: appleMusicNowPlaying.artist,
            album: appleMusicNowPlaying.album,
            artworkData: appleMusicNowPlaying.artworkData,
            lyrics: "",
            timedLyrics: [],
            playbackSource: .appleMusic
        )
    }

    var resolvedNetEaseSongID: String? {
        guard let resolvedNetEaseTrack else { return nil }
        if case .netEaseSong(let songID) = resolvedNetEaseTrack.playbackSource {
            return songID
        }
        return nil
    }

    var askedExternalFolderSources: Set<ExternalTokenSource> = []
    var didAskForMusicLibrary = false

    /// One-time folder grants so the sandboxed build can read the frontmost app's data.
    var followsNetEaseListOnScreen: Bool {
        guard musicLibrarySource == .netEase else { return false }
        let queue = activePlaybackList
        guard queue.count > 1 else { return false }
        return netEaseDownloadPlayer != nil || indexOfPlayingNetEaseTrack(in: queue) != nil
    }

    /// NetEase advances through its own queue and play mode when a song ends. If the song that ended
    /// came from the list on screen and NetEase moved somewhere else, play that list's next song.
    var lastAppleMusicRefreshDate = Date.distantPast
}
