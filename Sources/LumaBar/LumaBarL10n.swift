import Foundation

/// Centralized String Catalog lookups for Luma Bar (en + zh-Hans).
enum LumaBarL10n {
    static var appName: String { tr("app.name", "Luma Bar") }

    // MARK: Menu

    static var theme: String { tr("menu.theme", "Theme") }
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

    static func aboutVersion(version: String, build: String, copyright: String) -> String {
        let format = tr("about.version_format", "Version %@ (%@)\n\n%@")
        return String(format: format, locale: .current, version, build, copyright)
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

    static var helpTogglePanelTitle: String {
        tr("help.shortcut.toggle_panel.title", "Show / hide main panel")
    }
    static var helpTogglePanelDetail: String {
        tr("help.shortcut.toggle_panel.detail", "Summon the expanded panel anytime; press again to dismiss.")
    }
    static var helpEscapeTitle: String { tr("help.shortcut.escape.title", "Collapse panel") }
    static var helpEscapeDetail: String {
        tr("help.shortcut.escape.detail", "Press Escape while expanded to return to the compact bar.")
    }
    static var helpShellTitle: String { tr("help.shortcut.shell.title", "Agent / Shell input") }
    static var helpShellDetail: String {
        tr("help.shortcut.shell.detail", "Expand and focus the Agent input field.")
    }
    static var helpVoiceTitle: String { tr("help.shortcut.voice.title", "Voice Whisper") }
    static var helpVoiceDetail: String {
        tr("help.shortcut.voice.detail", "Start or stop speech-to-text into the Agent field.")
    }
    static var helpTranslateTitle: String {
        tr("help.shortcut.translate.title", "Selection translation")
    }
    static var helpTranslateDetail: String {
        tr(
            "help.shortcut.translate.detail",
            "Hold Option and release a selection to translate (when enabled)."
        )
    }
    static var helpThemeTitle: String { tr("help.shortcut.theme.title", "Switch theme") }
    static var helpThemeDetail: String {
        tr(
            "help.shortcut.theme.detail",
            "Quickly switch Void, Horizon, Aura, and other skins from Theme."
        )
    }
    static var helpHoverTitle: String { tr("help.feature.hover.title", "Hover to expand") }
    static var helpHoverDetail: String {
        tr(
            "help.feature.hover.detail",
            "Move the pointer to the notch / top bar to expand; move away to collapse."
        )
    }
    static var helpMusicTitle: String { tr("help.feature.music.title", "Music & lyrics") }
    static var helpMusicDetail: String {
        tr(
            "help.feature.music.detail",
            "Sync Apple Music / NetEase playback; expand for progress and lyrics."
        )
    }
    static var helpAgentTitle: String { tr("help.feature.agent.title", "Agent assistant") }
    static var helpAgentDetail: String {
        tr(
            "help.feature.agent.detail",
            "Switch to Agent in the panel; use shortcuts or voice for confirmed local actions."
        )
    }
    static var helpPetTitle: String { tr("help.feature.pet.title", "Desktop companion") }
    static var helpPetDetail: String {
        tr(
            "help.feature.pet.detail",
            "Some themes show a desktop pet; click for a short companion note."
        )
    }

    // MARK: - Bundle

    /// SPM resource bundle in `swift run`; packaged `.app` copies it under `Contents/Resources`.
    static var localizationBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        if let url = Bundle.main.url(forResource: "LumaBar_LumaBar", withExtension: "bundle"),
           let bundled = Bundle(url: url)
        {
            return bundled
        }
        return .main
        #endif
    }

    private static func tr(_ key: String, _ defaultValue: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: localizationBundle, value: defaultValue, comment: "")
    }
}
