import AppKit

/// Builds the status-item and application menus with a single, tidy layout.
@MainActor
final class LumaBarMenuBuilder {
    weak var target: AnyObject?

    private var appThemeItems: [IslandTheme: NSMenuItem] = [:]
    private var statusThemeItems: [IslandTheme: NSMenuItem] = [:]
    private weak var appShowHideItem: NSMenuItem?
    private weak var statusShowHideItem: NSMenuItem?

    private static let themeShortcutDigits: [IslandTheme: String] = [
        .void: "1",
        .grid: "2",
        .arcade: "3",
        .nook: "4",
        .horizon: "5",
        .forge: "6",
        .aura: "7"
    ]

    private static let themeSelectors: [IslandTheme: Selector] = [
        .void: #selector(AppDelegate.selectVoidTheme),
        .horizon: #selector(AppDelegate.selectHorizonTheme),
        .forge: #selector(AppDelegate.selectForgeTheme),
        .grid: #selector(AppDelegate.selectGridTheme),
        .arcade: #selector(AppDelegate.selectArcadeTheme),
        .nook: #selector(AppDelegate.selectNookTheme),
        .aura: #selector(AppDelegate.selectAuraTheme)
    ]

    // MARK: - Public

    func makeApplicationMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: LumaBarL10n.appName)
        populatePrimaryGroups(
            into: appMenu,
            themeStorage: &appThemeItems,
            showHideStorage: &appShowHideItem,
            includeThemeKeyEquivalents: true,
            includeQuitKeyEquivalent: true
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Keep a standard Edit menu so Agent / Help text fields get Cut/Copy/Paste.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: LumaBarL10n.edit)
        editMenu.addItem(NSMenuItem(title: LumaBarL10n.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: LumaBarL10n.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: LumaBarL10n.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: LumaBarL10n.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        return mainMenu
    }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu(title: LumaBarL10n.appName)
        populatePrimaryGroups(
            into: menu,
            themeStorage: &statusThemeItems,
            showHideStorage: &statusShowHideItem,
            includeThemeKeyEquivalents: false,
            includeQuitKeyEquivalent: true
        )
        return menu
    }

    func updateThemeState(_ theme: IslandTheme) {
        for (itemTheme, item) in appThemeItems {
            item.state = itemTheme == theme ? .on : .off
        }
        for (itemTheme, item) in statusThemeItems {
            item.state = itemTheme == theme ? .on : .off
        }
    }

    func updatePanelVisibility(isExpanded: Bool) {
        let title = isExpanded ? LumaBarL10n.hideMainPanel : LumaBarL10n.showMainPanel
        appShowHideItem?.title = title
        statusShowHideItem?.title = title
    }

    // MARK: - Layout

    /// Group 1: Theme + Show/Hide  
    /// Group 2: Permissions + Help + About  
    /// Group 3: Quit
    private func populatePrimaryGroups(
        into menu: NSMenu,
        themeStorage: inout [IslandTheme: NSMenuItem],
        showHideStorage: inout NSMenuItem?,
        includeThemeKeyEquivalents: Bool,
        includeQuitKeyEquivalent: Bool
    ) {
        themeStorage.removeAll()

        // —— Group 1: Core ——
        let themeParent = NSMenuItem(title: LumaBarL10n.theme, action: nil, keyEquivalent: "")
        themeParent.submenu = makeThemeSubmenu(
            storage: &themeStorage,
            includeKeyEquivalents: includeThemeKeyEquivalents
        )
        menu.addItem(themeParent)

        let showHide = makeItem(
            title: LumaBarL10n.showMainPanel,
            action: #selector(AppDelegate.toggleMainPanelFromMenu),
            keyEquivalent: includeThemeKeyEquivalents ? "l" : "",
            modifiers: includeThemeKeyEquivalents ? [.command, .shift] : []
        )
        menu.addItem(showHide)
        showHideStorage = showHide

        menu.addItem(.separator())

        // —— Group 2: Settings & Help ——
        menu.addItem(makeItem(
            title: LumaBarL10n.permissions,
            action: #selector(AppDelegate.showPermissionSetupFromMenu)
        ))
        menu.addItem(makeItem(
            title: LumaBarL10n.help,
            action: #selector(AppDelegate.showHelpFromMenu),
            keyEquivalent: includeThemeKeyEquivalents ? "?" : "",
            modifiers: includeThemeKeyEquivalents ? [.command] : []
        ))
        menu.addItem(makeItem(
            title: LumaBarL10n.about,
            action: #selector(AppDelegate.showAboutFromMenu)
        ))

        menu.addItem(.separator())

        // —— Group 3: Quit ——
        menu.addItem(makeItem(
            title: LumaBarL10n.quit,
            action: #selector(AppDelegate.quitFromMenu),
            keyEquivalent: includeQuitKeyEquivalent ? "q" : "",
            modifiers: includeQuitKeyEquivalent ? [.command] : []
        ))
    }

    private func makeThemeSubmenu(
        storage: inout [IslandTheme: NSMenuItem],
        includeKeyEquivalents: Bool
    ) -> NSMenu {
        let submenu = NSMenu(title: LumaBarL10n.theme)
        // Stable product order: Void → Grid → Arcade → Nook → Horizon → Forge → Aura
        let order: [IslandTheme] = [.void, .grid, .arcade, .nook, .horizon, .forge, .aura]

        for theme in order {
            guard let action = Self.themeSelectors[theme] else { continue }
            let key = includeKeyEquivalents ? (Self.themeShortcutDigits[theme] ?? "") : ""
            let item = makeItem(
                title: theme.displayName,
                action: action,
                keyEquivalent: key,
                modifiers: key.isEmpty ? [] : [.command, .option]
            )
            submenu.addItem(item)
            storage[theme] = item
        }
        return submenu
    }

    private func makeItem(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        if !modifiers.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }
}
