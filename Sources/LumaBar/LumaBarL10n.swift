import Foundation

/// User-selectable app language. Default follows the system.
enum LumaBarAppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portugueseBrazil = "pt-BR"
    case italian = "it"
    case russian = "ru"

    var id: String { rawValue }

    static let defaultsKey = "LumaBar.appLanguage"
    static let didChangeNotification = Notification.Name("LumaBarLanguageDidChange")

    /// Bundled localizations (excluding `system`).
    static let bundledCodes: [String] = [
        "en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt-BR", "it", "ru"
    ]

    /// Native-script labels so users can find their language in any UI locale.
    var menuTitle: String {
        switch self {
        case .system: return LumaBarL10n.languageFollowSystem
        case .english: return LumaBarL10n.languageEnglish
        case .simplifiedChinese: return LumaBarL10n.languageSimplifiedChinese
        case .traditionalChinese: return LumaBarL10n.languageTraditionalChinese
        case .japanese: return LumaBarL10n.languageJapanese
        case .korean: return LumaBarL10n.languageKorean
        case .french: return LumaBarL10n.languageFrench
        case .german: return LumaBarL10n.languageGerman
        case .spanish: return LumaBarL10n.languageSpanish
        case .portugueseBrazil: return LumaBarL10n.languagePortuguese
        case .italian: return LumaBarL10n.languageItalian
        case .russian: return LumaBarL10n.languageRussian
        }
    }

    var overrideCode: String? {
        self == .system ? nil : rawValue
    }

    static var current: LumaBarAppLanguage {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? system.rawValue
        return LumaBarAppLanguage(rawValue: raw) ?? .system
    }

    static func setCurrent(_ language: LumaBarAppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        }
        LumaBarL10n.applyPreferredLanguage()
        NotificationCenter.default.post(name: didChangeNotification, object: language)
    }
}

/// Centralized String Catalog lookups for Luma Bar.
enum LumaBarL10n {
    static var appName: String { tr("app.name", "Luma Bar") }

    // MARK: Menu

    static var theme: String { tr("menu.theme", "Theme") }
    static var auraOpacity: String { tr("menu.theme.aura_opacity", "Opacity") }
    static var language: String { tr("menu.language", "Language") }
    static var languageFollowSystem: String { tr("menu.language.system", "Follow System") }
    static var languageEnglish: String { tr("menu.language.english", "English") }
    static var languageSimplifiedChinese: String { tr("menu.language.zh_hans", "简体中文") }
    static var languageTraditionalChinese: String { tr("menu.language.zh_hant", "繁體中文") }
    static var languageJapanese: String { tr("menu.language.japanese", "日本語") }
    static var languageKorean: String { tr("menu.language.korean", "한국어") }
    static var languageFrench: String { tr("menu.language.french", "Français") }
    static var languageGerman: String { tr("menu.language.german", "Deutsch") }
    static var languageSpanish: String { tr("menu.language.spanish", "Español") }
    static var languagePortuguese: String { tr("menu.language.portuguese", "Português (Brasil)") }
    static var languageItalian: String { tr("menu.language.italian", "Italiano") }
    static var languageRussian: String { tr("menu.language.russian", "Русский") }

    static var showMainPanel: String { tr("menu.show_main_panel", "Show Main Panel") }
    static var hideMainPanel: String { tr("menu.hide_main_panel", "Hide Main Panel") }
    static var permissions: String { tr("menu.permissions", "Permissions…") }
    static var help: String { tr("menu.help", "Help & Shortcuts…") }
    static var about: String { tr("menu.about", "About Luma Bar") }
    static var quit: String { tr("menu.quit", "Quit Luma Bar") }
    static var edit: String { tr("menu.edit", "Edit") }
    static var cut: String { tr("menu.cut", "Cut") }
    static var copy: String { tr("menu.copy", "Copy") }
    static var paste: String { tr("menu.paste", "Paste") }
    static var selectAll: String { tr("menu.select_all", "Select All") }
    static var aboutOK: String { tr("about.ok", "OK") }

    static func aboutVersion(version: String, build: String, copyright: String) -> String {
        String(format: tr("about.version_format", "Version %@ (%@)\n\n%@"), locale: resolvedLocale, version, build, copyright)
    }

    // MARK: Help

    static var helpWindowTitle: String { tr("help.window_title", "Help & Shortcuts") }
    static var helpTitle: String { tr("help.title", "Help") }
    static var helpSubtitle: String { tr("help.subtitle", "Shortcuts and everyday actions") }
    static var helpClose: String { tr("help.close", "Close") }
    static var helpSectionShortcuts: String { tr("help.section.shortcuts", "Shortcuts") }
    static var helpSectionFeatures: String { tr("help.section.features", "Features") }
    static var helpFooter: String {
        tr("help.footer", "This guide opens only when you ask for it — never on launch.")
    }
    static var helpTogglePanelTitle: String { tr("help.shortcut.toggle_panel.title", "Show / hide main panel") }
    static var helpTogglePanelDetail: String {
        tr("help.shortcut.toggle_panel.detail", "Summon the expanded panel anytime; press again to dismiss.")
    }
    static var helpEscapeTitle: String { tr("help.shortcut.escape.title", "Collapse panel") }
    static var helpEscapeDetail: String {
        tr("help.shortcut.escape.detail", "Press Escape while expanded to return to the compact bar.")
    }
    static var helpShellTitle: String { tr("help.shortcut.shell.title", "Agent / Shell input") }
    static var helpShellDetail: String { tr("help.shortcut.shell.detail", "Expand and focus the Agent input field.") }
    static var helpVoiceTitle: String { tr("help.shortcut.voice.title", "Voice Whisper") }
    static var helpVoiceDetail: String {
        tr("help.shortcut.voice.detail", "Start or stop speech-to-text into the Agent field.")
    }
    static var helpTranslateTitle: String { tr("help.shortcut.translate.title", "Selection translation") }
    static var helpTranslateDetail: String {
        tr("help.shortcut.translate.detail", "Hold Option and release a selection to translate (when enabled).")
    }
    static var helpThemeTitle: String { tr("help.shortcut.theme.title", "Switch theme") }
    static var helpThemeDetail: String {
        tr("help.shortcut.theme.detail", "Quickly switch Void, Horizon, Aura, and other skins from Theme.")
    }
    static var helpHoverTitle: String { tr("help.feature.hover.title", "Hover to expand") }
    static var helpHoverDetail: String {
        tr("help.feature.hover.detail", "Move the pointer to the notch / top bar to expand; move away to collapse.")
    }
    static var helpMusicTitle: String { tr("help.feature.music.title", "Music & lyrics") }
    static var helpMusicDetail: String {
        tr("help.feature.music.detail", "Sync Apple Music / NetEase playback; expand for progress and lyrics.")
    }
    static var helpAgentTitle: String { tr("help.feature.agent.title", "Agent assistant") }
    static var helpAgentDetail: String {
        tr("help.feature.agent.detail", "Switch to Agent in the panel; use shortcuts or voice for confirmed local actions.")
    }
    static var helpPetTitle: String { tr("help.feature.pet.title", "Desktop companion") }
    static var helpPetDetail: String {
        tr("help.feature.pet.detail", "Some themes show a desktop pet; click for a short companion note.")
    }

    // MARK: Island chrome

    static var modeMusic: String { tr("island.mode.music", "Music") }
    static var modeSystem: String { tr("island.mode.system", "System") }
    static var modeAgent: String { tr("island.mode.agent", "Agent") }
    static var lyrics: String { tr("island.lyrics", "Lyrics") }
    static var send: String { tr("island.send", "Send") }
    static var collapse: String { tr("island.collapse", "Collapse") }
    static var libraryLocal: String { tr("island.library.local", "Local") }
    static var libraryAppleMusic: String { tr("island.library.apple_music", "Apple Music") }
    static var libraryNetEase: String { tr("island.library.netease", "NetEase") }
    static var openMusic: String { tr("island.open_music", "Open Music") }
    static var openMusicHint: String { tr("island.open_music_hint", "Open Music.app to start playing") }
    static var noLocalSongs: String { tr("island.no_local_songs", "No local songs") }
    static var cancelSend: String { tr("island.cancel_send", "Cancel send") }
    static var builtinKey: String { tr("island.builtin_key", "Built-in") }
    static func remainingPercent(_ text: String) -> String {
        String(format: tr("island.remaining_format", "Left %@"), locale: resolvedLocale, text)
    }
    static func usedPercent(_ text: String) -> String {
        String(format: tr("island.used_format", "Used %@"), locale: resolvedLocale, text)
    }
    static var taskComplete: String { tr("island.task_complete", "Task complete") }
    static var taskCompleteFallbackDetail: String {
        tr("island.task_complete_fallback", "You can check the result now")
    }
    static var dismissNotice: String { tr("island.dismiss_notice", "Dismiss") }
    static func taskCompleteA11y(brand: String) -> String {
        String(format: tr("island.task_complete_a11y", "%@ task complete"), locale: resolvedLocale, brand)
    }
    static func backgroundTaskComplete(brand: String) -> String {
        String(format: tr("island.background_task_complete", "%@ · Background task complete"), locale: resolvedLocale, brand)
    }
    static var returnForFullResult: String { tr("island.return_for_result", "Return to see the full result") }
    static func backgroundTaskCompleteA11y(brand: String, title: String) -> String {
        String(format: tr("island.background_task_a11y", "%@ background task complete, %@"), locale: resolvedLocale, brand, title)
    }
    static var confirmRun: String { tr("island.confirm_run", "Confirm run") }
    static var runCommand: String { tr("island.run_command", "Run command") }

    static var quickExplain: String { tr("island.quick.explain", "Explain") }
    static var quickRefactor: String { tr("island.quick.refactor", "Refactor") }
    static var quickComment: String { tr("island.quick.comment", "Comment") }
    static var quickShell: String { tr("island.quick.shell", "Shell") }
    static var quickProfessional: String { tr("island.quick.professional", "Professional") }
    static var quickSimplify: String { tr("island.quick.simplify", "Simplify") }
    static var quickProofread: String { tr("island.quick.proofread", "Proofread") }
    static var quickOutline: String { tr("island.quick.outline", "Outline") }
    static var quickTLDR: String { tr("island.quick.tldr", "TL;DR") }
    static var quickKeyPoints: String { tr("island.quick.key_points", "Key Points") }
    static var quickGuide: String { tr("island.quick.guide", "Guide") }
    static var quickBuild: String { tr("island.quick.build", "Build") }
    static var quickScreen: String { tr("island.quick.screen", "Screen") }
    static var quickNext: String { tr("island.quick.next", "Next") }
    static var quickMood: String { tr("island.quick.mood", "Mood") }

    static var sysCPU: String { tr("island.sys.cpu", "CPU") }
    static var sysMemory: String { tr("island.sys.memory", "Memory") }
    static var sysDisk: String { tr("island.sys.disk", "Disk") }
    static var sysBattery: String { tr("island.sys.battery", "Battery") }
    static var sysUptime: String { tr("island.sys.uptime", "Uptime") }
    static func sysTotal(_ text: String) -> String {
        String(format: tr("island.sys.total_format", "Total %@"), locale: resolvedLocale, text)
    }

    static var actionRescan: String { tr("island.action.rescan", "Rescan Music") }
    static var actionOpenNetEase: String { tr("island.action.open_netease", "Open NetEase Cloud Music") }
    static var actionOpenAppleMusic: String { tr("island.action.open_apple_music", "Open Apple Music") }
    static var actionRefreshPlaylists: String { tr("island.action.refresh_playlists", "Refresh NetEase Playlists") }
    static var actionSwitchMusic: String { tr("island.action.switch_music", "Switch to Music") }
    static var actionSwitchSystem: String { tr("island.action.switch_system", "Switch to System") }
    static var actionSwitchAgent: String { tr("island.action.switch_agent", "Switch to Agent") }
    static var actionQuit: String { tr("island.action.quit", "Quit") }

    static var agentPasteKey: String { tr("island.agent.paste_key", "Paste API key") }
    static var agentClearKey: String { tr("island.agent.clear_key", "Clear API key") }
    static var agentCopyCommand: String { tr("island.agent.copy_command", "Copy command") }
    static var agentTools: String { tr("island.agent.tools", "TOOLS") }
    static var agentCTX: String { tr("island.agent.ctx", "CTX") }
    static var tokenInput: String { tr("island.token.input", "Input") }
    static var tokenOutput: String { tr("island.token.output", "Output") }
    static var tokenRemaining: String { tr("island.token.remaining", "Remaining") }
    static var petHelp: String {
        tr("island.pet.help", "Click to talk, long-press for Voice Whisper, drag to move")
    }
    static var petTalk: String { tr("island.pet.talk", "Talk") }
    static func tokenOpenHelp(_ summary: String) -> String {
        String(format: tr("island.token.open_help_format", "Open token usage · %@ tokens"), locale: resolvedLocale, summary)
    }

    static var agentPlaceholderShell: String {
        tr("island.agent.placeholder.shell", "Describe shell task, then press Return")
    }
    static var agentPlaceholderCode: String {
        tr("island.agent.placeholder.code", "Ask about code or generate a command")
    }
    static var agentPlaceholderWriting: String {
        tr("island.agent.placeholder.writing", "Rewrite, expand, or refine")
    }
    static var agentPlaceholderReading: String {
        tr("island.agent.placeholder.reading", "Ask about this page or document")
    }
    static var agentPlaceholderGaming: String {
        tr("island.agent.placeholder.gaming", "Ask about a game, item, or build")
    }
    static var agentPlaceholderMusic: String {
        tr("island.agent.placeholder.music", "Control music naturally")
    }
    static var agentPlaceholderGeneral: String { tr("island.agent.placeholder.general", "Message") }

    static var agentTitleCode: String { tr("island.agent.title.code", "Code Agent") }
    static var agentTitleWriting: String { tr("island.agent.title.writing", "Writing Agent") }
    static var agentTitleReading: String { tr("island.agent.title.reading", "Reading Agent") }
    static var agentTitleGaming: String { tr("island.agent.title.gaming", "Game Agent") }
    static var agentTitleMusic: String { tr("island.agent.title.music", "Music Agent") }
    static var agentTitleGeneral: String { tr("island.agent.title.general", "AI Agent") }

    static var agentContextCode: String { tr("island.agent.context.code", "Code") }
    static var agentContextWriting: String { tr("island.agent.context.writing", "Writing") }
    static var agentContextReading: String { tr("island.agent.context.reading", "Reading") }
    static var agentContextGaming: String { tr("island.agent.context.gaming", "Gaming") }
    static var agentContextMusic: String { tr("island.agent.context.music", "Music") }
    static var agentContextGeneral: String { tr("island.agent.context.general", "General") }

    static var agentOpen: String { tr("island.agent.open", "Open agent") }
    static var agentClose: String { tr("island.agent.close", "Close agent") }
    static func agentStreaming(_ provider: String) -> String {
        String(format: tr("island.agent.streaming_format", "%@ Streaming"), locale: resolvedLocale, provider)
    }
    static var agentVoiceInput: String { tr("island.agent.voice_input", "Voice input") }
    static var agentRunningCommand: String { tr("island.agent.running_command", "Running command") }
    static var agentConnecting: String { tr("island.agent.connecting", "Connecting") }
    static var agentWriting: String { tr("island.agent.writing", "Writing") }
    static var agentLive: String { tr("island.agent.live", "Live") }
    static var agentAsk: String { tr("island.agent.ask", "Ask") }
    static var agentKeyBadge: String { tr("island.agent.key_badge", "Key") }
    static var agentAPIKeyNeeded: String { tr("island.agent.api_key_needed", "API key needed") }
    static var agentThinking: String { tr("island.agent.thinking", "Thinking") }
    static var agentLastRequest: String { tr("island.agent.last_request", "Last request") }
    static var agentReadingContext: String { tr("island.agent.reading_context", "Reading context") }
    static var agentCurrentContext: String { tr("island.agent.current_context", "Current context") }
    static var agentAITokenUsage: String { tr("island.agent.ai_token_usage", "AI token usage") }
    static var agentShellRequest: String { tr("island.agent.shell_request", "Shell request") }
    static func agentKeySaved(_ provider: String) -> String {
        String(format: tr("island.agent.key_saved_format", "%@ key saved"), locale: resolvedLocale, provider)
    }
    static var agentKeySaveFailed: String { tr("island.agent.key_save_failed", "Key save failed") }
    static func agentUsingBuiltin(_ provider: String) -> String {
        String(format: tr("island.agent.using_builtin_format", "Using built-in %@"), locale: resolvedLocale, provider)
    }
    static func agentKeyCleared(_ provider: String) -> String {
        String(format: tr("island.agent.key_cleared_format", "%@ key cleared"), locale: resolvedLocale, provider)
    }
    static var agentClipboardEmpty: String { tr("island.agent.clipboard_empty", "Clipboard empty") }
    static var agentKeyPasted: String { tr("island.agent.key_pasted", "Key pasted") }
    static var agentCanceled: String { tr("island.agent.canceled", "Canceled") }
    static var agentShell: String { tr("island.agent.shell", "Shell") }
    static var agentReadingSelection: String { tr("island.agent.reading_selection", "Reading selection") }
    static var agentTranslating: String { tr("island.agent.translating", "Translating") }
    static var agentCapturing: String { tr("island.agent.capturing", "Capturing") }
    static var agentStreamingStatus: String { tr("island.agent.streaming", "Streaming") }
    static var agentNoOutput: String { tr("island.agent.no_output", "No output") }
    static func agentTranslated(_ seconds: Double) -> String {
        String(format: tr("island.agent.translated_format", "Translated %.1fs"), locale: resolvedLocale, seconds)
    }
    static func agentDone(_ seconds: Double) -> String {
        String(format: tr("island.agent.done_format", "Done %.1fs"), locale: resolvedLocale, seconds)
    }
    static var agentError: String { tr("island.agent.error", "Error") }
    static var agentPlanning: String { tr("island.agent.planning", "Planning local actions") }
    static var agentPlanningFailed: String { tr("island.agent.planning_failed", "Planning failed") }
    static var agentSearchingMusic: String { tr("island.agent.searching_music", "Searching music") }
    static var agentNoMusic: String { tr("island.agent.no_music", "No music found") }
    static var agentMusicError: String { tr("island.agent.music_error", "Music error") }
    static var agentWeather: String { tr("island.agent.weather", "Weather") }
    static var agentWeatherError: String { tr("island.agent.weather_error", "Weather error") }
    static var agentCopied: String { tr("island.agent.copied", "Copied") }
    static var agentConfirmSend: String { tr("island.agent.confirm_send", "Confirm send") }
    static var agentConfirmSendAgain: String {
        tr("island.agent.confirm_send_again", "Tap again to confirm send")
    }
    static var agentSending: String { tr("island.agent.sending", "Sending") }
    static var agentSent: String { tr("island.agent.sent", "Sent") }
    static var agentSendFailed: String { tr("island.agent.send_failed", "Send failed") }
    static var agentShellReady: String { tr("island.agent.shell_ready", "Shell ready") }
    static var agentBlocked: String { tr("island.agent.blocked", "Blocked") }
    static var agentRunning: String { tr("island.agent.running", "Running") }
    static var agentRunFailed: String { tr("island.agent.run_failed", "Run failed") }
    static func agentExit(_ code: Int) -> String {
        String(format: tr("island.agent.exit_format", "Exit %d"), locale: resolvedLocale, code)
    }
    static var agentChineseSpeechModel: String {
        tr("island.agent.chinese_speech_model", "Chinese speech model")
    }

    static var musicPlay: String { tr("island.music.play", "Play") }
    static var musicPause: String { tr("island.music.pause", "Pause") }
    static var musicSeek: String { tr("island.music.seek", "Seek") }
    static var musicNoTimeline: String { tr("island.music.no_timeline", "No timeline available") }
    static var musicPrevPlaylist: String { tr("island.music.prev_playlist", "Previous playlist") }
    static var musicNextPlaylist: String { tr("island.music.next_playlist", "Next playlist") }
    static var musicOpenPlayer: String { tr("island.music.open_player", "Open player") }
    static func musicOpenPlayer(brand: String, percent: String) -> String {
        String(format: tr("island.music.open_player_format", "Open player · %@ %@"), locale: resolvedLocale, brand, percent)
    }

    static var lyricsNoTrack: String { tr("island.lyrics.no_track", "No track selected") }
    static var lyricsNone: String { tr("island.lyrics.none", "No lyrics") }
    static var lyricsLoading: String { tr("island.lyrics.loading", "Loading lyrics…") }
    static var lyricsNoEmbedded: String { tr("island.lyrics.no_embedded", "No embedded lyrics") }
    static var libraryLocalSubtitle: String { tr("island.library.local_subtitle", "Local library") }
    static var voiceFinishing: String { tr("island.voice.finishing", "Finishing transcription") }
    static var voiceFinishWhisper: String { tr("island.voice.finish", "Finish Voice Whisper") }
    static var voiceStartWhisper: String { tr("island.voice.start", "Start Voice Whisper") }
    static var companionTitle: String { tr("island.companion.title", "Desktop Companion") }
    static var companionSubtitle: String { tr("island.companion.subtitle", "Desktop companion") }

    // MARK: Permissions

    static var permissionWindowTitle: String { tr("permission.window_title", "Permissions") }
    static var permissionTitle: String { tr("permission.title", "Permissions") }
    static var permissionSubtitle: String {
        tr("permission.subtitle", "Turn these on so Luma Bar can work fully. Status refreshes when you return from System Settings.")
    }
    static var permissionCore: String { tr("permission.badge.core", "Core") }
    static var permissionOptional: String { tr("permission.badge.optional", "Optional") }
    static var permissionAuthorize: String { tr("permission.authorize", "Allow") }
    static var permissionRetry: String { tr("permission.retry", "Retry") }
    static var permissionOpenSettings: String { tr("permission.open_settings", "Open Settings") }
    static var permissionSkip: String { tr("permission.skip", "Skip") }
    static var permissionUnskip: String { tr("permission.unskip", "Undo skip") }
    static var permissionShowGuide: String { tr("permission.show_guide", "How to enable?") }
    static var permissionHideGuide: String { tr("permission.hide_guide", "Hide guide") }
    static var permissionRequestAll: String { tr("permission.request_all", "Allow All") }
    static var permissionFinishReady: String { tr("permission.finish_ready", "Done") }
    static var permissionFinishStart: String { tr("permission.finish_start", "Get Started") }
    static var permissionFinishLater: String { tr("permission.finish_later", "Later") }
    static var permissionCoreReady: String { tr("permission.core_ready", "Core permissions ready") }
    static var permissionCoreNeeded: String { tr("permission.core_needed", "Please finish core permissions first") }
    static var permissionCoreWarning: String {
        tr("permission.core_warning", "You can continue without core permissions, but selection translation / music sync may be unavailable.")
    }
    static func permissionAuthorizedCount(authorized: Int, total: Int) -> String {
        String(format: tr("permission.authorized_count", "%d/%d allowed"), locale: resolvedLocale, authorized, total)
    }
    static var permissionAccessibilityTitle: String { tr("permission.accessibility.title", "Accessibility") }
    static var permissionAccessibilitySubtitle: String {
        tr("permission.accessibility.subtitle", "Selection translation, Agent reading selection and frontmost app context")
    }
    static var permissionAutomationTitle: String { tr("permission.automation.title", "Automation") }
    static var permissionAutomationSubtitle: String {
        tr("permission.automation.subtitle", "Sync Apple Music / NetEase playback via AppleScript")
    }
    static var permissionScreenTitle: String { tr("permission.screen.title", "Screen Recording") }
    static var permissionScreenSubtitle: String {
        tr("permission.screen.subtitle", "Screenshot analysis for the current window (optional)")
    }
    static var permissionStatePending: String { tr("permission.state.pending", "Pending") }
    static var permissionStateRequesting: String { tr("permission.state.requesting", "Requesting…") }
    static var permissionStateDone: String { tr("permission.state.done", "Done") }
    static var permissionStateOff: String { tr("permission.state.off", "Off") }
    static var permissionStateRestricted: String { tr("permission.state.restricted", "Restricted") }
    static var permissionStateSkipped: String { tr("permission.state.skipped", "Skipped") }
    static var permissionGuideAccessibility1: String { tr("permission.guide.accessibility.1", "Tap Allow or Open Settings") }
    static var permissionGuideAccessibility2: String {
        tr("permission.guide.accessibility.2", "In Privacy & Security → Accessibility, find luma bar")
    }
    static var permissionGuideAccessibility3: String {
        tr("permission.guide.accessibility.3", "Turn the switch on, then return here (no restart needed)")
    }
    static var permissionGuideAutomation1: String {
        tr("permission.guide.automation.1", "Tap Allow and choose OK in the system prompt")
    }
    static var permissionGuideAutomation2: String {
        tr("permission.guide.automation.2", "Or open Privacy & Security → Automation and allow Music / System Events")
    }
    static var permissionGuideAutomation3: String {
        tr("permission.guide.automation.3", "Return to Luma Bar and status refreshes automatically")
    }
    static var permissionGuideScreen1: String { tr("permission.guide.screen.1", "Tap Allow and follow the system prompt") }
    static var permissionGuideScreen2: String {
        tr("permission.guide.screen.2", "Or enable it in Privacy & Security → Screen Recording")
    }
    static var permissionGuideScreen3: String {
        tr("permission.guide.screen.3", "You can skip this for now; everyday listening still works")
    }
    static var permissionTipAccessibility: String {
        tr("permission.tip.accessibility", "Selection translation still needs Accessibility — reopen Permissions from the menu.")
    }
    static var permissionTipAutomation: String {
        tr("permission.tip.automation", "Music sync needs Automation; playback controls may be unavailable for now.")
    }
    static var permissionTipScreen: String {
        tr("permission.tip.screen", "Screen Recording was skipped; enable it later in Permissions when you need screenshots.")
    }
    static var permissionUpdated: String { tr("permission.updated", "Permissions updated. Refreshing content.") }
    static var permissionAccessibilityGranted: String {
        tr("permission.granted.accessibility", "Accessibility is on — selection translation is ready.")
    }
    static var permissionAutomationGranted: String {
        tr("permission.granted.automation", "Automation is on — music sync can work.")
    }
    static var permissionScreenGranted: String {
        tr("permission.granted.screen", "Screen Recording is on — screenshot analysis is available.")
    }

    // MARK: Voice / scan / agent chrome

    static var voiceNeedSpeech: String { tr("voice.need_speech", "Speech permission needed") }
    static var voiceNeedSpeechDetail: String {
        tr("voice.need_speech_detail", "Speech recognition will be requested — tap OK in the dialog.")
    }
    static var voiceSpeechDenied: String { tr("voice.speech_denied", "Speech recognition not allowed") }
    static var voiceSpeechUnavailable: String { tr("voice.speech_unavailable", "Speech recognition unavailable") }
    static var voiceNeedMic: String { tr("voice.need_mic", "Microphone permission needed") }
    static var voiceNeedMicDetail: String {
        tr("voice.need_mic_detail", "Microphone access will be requested — tap OK in the dialog.")
    }
    static var voiceMicDenied: String { tr("voice.mic_denied", "Microphone not allowed") }
    static var voiceMicUnavailable: String { tr("voice.mic_unavailable", "Microphone unavailable") }
    static var voiceTranscribing: String { tr("voice.transcribing", "Transcribing") }
    static var voiceTranscribingDetail: String { tr("voice.transcribing_detail", "Finishing speech transcription…") }
    static var voiceTimeout: String { tr("voice.timeout", "Speech transcription timed out. Please try again.") }
    static var voiceListening: String { tr("voice.listening", "Listening") }
    static var voiceListeningDetail: String {
        tr("voice.listening_detail", "Listening… Press ⌘⇧M again when finished.")
    }
    static var voiceOpenMicSettings: String {
        tr("voice.open_mic_settings", "Enable luma bar in System Settings → Privacy & Security → Microphone, then retry Voice Whisper.")
    }
    static var voiceOpenSpeechSettings: String {
        tr("voice.open_speech_settings", "Enable luma bar in System Settings → Privacy & Security → Speech Recognition, then retry Voice Whisper.")
    }
    static var voiceOpenPrivacySettings: String {
        tr("voice.open_privacy_settings", "Allow Microphone and Speech Recognition in System Settings → Privacy & Security, then retry.")
    }
    static var voiceReady: String { tr("voice.ready", "Voice ready") }
    static var voiceNoSpeech: String { tr("voice.no_speech", "No speech detected") }
    static var voiceNoSpeechDetail: String {
        tr("voice.no_speech_detail", "No usable speech was heard. Please try again.")
    }
    static var voiceError: String { tr("voice.error", "Voice error") }
    static var voiceMicError: String { tr("voice.mic_error", "Microphone error") }

    static var scanScanning: String { tr("scan.scanning", "Scanning local music") }
    static var scanScanningAll: String { tr("scan.scanning_all", "Scanning local and NetEase music") }
    static var scanGrantFolder: String { tr("scan.grant_folder", "Grant a music folder to scan local tracks") }
    static var scanNone: String { tr("scan.none", "No music found") }
    static func scanFound(_ count: Int) -> String {
        String(format: tr("scan.found_format", "%d tracks found"), locale: resolvedLocale, count)
    }
    static var agentReady: String { tr("agent.ready", "Ready") }
    static var agentReadyDetail: String { tr("agent.ready_detail", "Ready.") }
    static func agentConfigureKey(_ provider: String) -> String {
        String(format: tr("agent.configure_key_format", "Configure a %@ API key, or inject a built-in key."), locale: resolvedLocale, provider)
    }
    static func agentConfigureKeyFirst(_ provider: String) -> String {
        String(
            format: tr(
                "agent.configure_key_first_format",
                "Configure a %@ API key first, or inject a built-in key at build time."
            ),
            locale: resolvedLocale,
            provider
        )
    }

    static var appleMusicPlaying: String {
        tr("island.apple_music.playing", "Playing via Apple Music (Music.app)")
    }
    static var appleMusicEmpty: String {
        tr("island.apple_music.empty", "Play a song in Music.app to see it here")
    }
    static var libraryLocalFile: String { tr("island.library.local_file", "Local file") }

    // MARK: Locale / Bundle

    static var resolvedLanguageCode: String {
        if let override = LumaBarAppLanguage.current.overrideCode {
            return override
        }
        return matchSystemLanguage()
    }

    static var resolvedLocale: Locale {
        Locale(identifier: resolvedLanguageCode)
    }

    static func applyPreferredLanguage() {
        if let code = LumaBarAppLanguage.current.overrideCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
        bundleLock.lock()
        cachedLocalizedBundle = nil
        bundleLock.unlock()
    }

    private static let bundleLock = NSLock()
    nonisolated(unsafe) private static var cachedLocalizedBundle: Bundle?

    static var resourceBundle: Bundle {
        // Prefer the packaged resource bundle inside the .app (SPM lowercases *.lproj names).
        if let url = Bundle.main.url(forResource: "LumaBar_LumaBar", withExtension: "bundle"),
           let bundled = Bundle(url: url)
        {
            return bundled
        }
        if let url = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("LumaBar_LumaBar.bundle"),
           let bundled = Bundle(url: url)
        {
            return bundled
        }
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static var localizationBundle: Bundle {
        bundleLock.lock()
        defer { bundleLock.unlock() }
        if let cachedLocalizedBundle { return cachedLocalizedBundle }
        let base = resourceBundle
        if let localized = lprojBundle(in: base, code: resolvedLanguageCode) {
            cachedLocalizedBundle = localized
            return localized
        }
        if let english = lprojBundle(in: base, code: "en") {
            cachedLocalizedBundle = english
            return english
        }
        cachedLocalizedBundle = base
        return base
    }

    /// SPM resource processing lowercases folder names (`zh-Hans` → `zh-hans`), so look up case-insensitively.
    private static func lprojBundle(in base: Bundle, code: String) -> Bundle? {
        let candidates = [code, code.lowercased()]
        for candidate in candidates {
            if let path = base.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path)
            {
                return bundle
            }
        }
        let root = base.bundlePath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        let wanted = code.lowercased() + ".lproj"
        guard let name = names.first(where: { $0.lowercased() == wanted }) else { return nil }
        return Bundle(path: (root as NSString).appendingPathComponent(name))
    }

    private static func matchSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages
        for raw in preferred {
            let lowered = raw.lowercased()
            if lowered.hasPrefix("zh") {
                if lowered.contains("hant") || lowered.contains("tw") || lowered.contains("hk") || lowered.contains("mo") {
                    return "zh-Hant"
                }
                return "zh-Hans"
            }
            if lowered.hasPrefix("pt") {
                return "pt-BR"
            }
            let short = String(lowered.prefix(2))
            let map: [String: String] = [
                "en": "en", "ja": "ja", "ko": "ko", "fr": "fr", "de": "de",
                "es": "es", "it": "it", "ru": "ru"
            ]
            if let code = map[short] { return code }
        }
        let bundlePrefs = Bundle.main.preferredLocalizations
        for raw in bundlePrefs {
            let normalized: String
            switch raw.lowercased() {
            case "zh-hans", "zh-cn", "zh": normalized = "zh-Hans"
            case "zh-hant", "zh-tw", "zh-hk": normalized = "zh-Hant"
            case "pt-br", "pt": normalized = "pt-BR"
            default: normalized = raw
            }
            if LumaBarAppLanguage.bundledCodes.contains(normalized) {
                return normalized
            }
        }
        return "en"
    }

    private static func tr(_ key: String, _ defaultValue: String) -> String {
        let value = NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: localizationBundle,
            value: defaultValue,
            comment: ""
        )
        return value
    }
}
