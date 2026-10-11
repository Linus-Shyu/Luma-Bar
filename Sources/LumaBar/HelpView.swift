import AppKit
import SwiftUI

// MARK: - Models

struct HelpShortcutItem: Identifiable, Equatable {
    let id: String
    let keys: [String]
    let title: String
    let detail: String
}

struct HelpFeatureItem: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
}

enum HelpGuideContent {
    static var translateShortcutKeys: [String] {
        #if LUMA_APP_STORE
        ["⌘", "C", "×2"]
        #else
        ["⌥"]
        #endif
    }

    static var shortcuts: [HelpShortcutItem] {
        [
            HelpShortcutItem(
                id: "toggle_panel",
                keys: ["⌘", "⇧", "L"],
                title: LumaBarL10n.helpTogglePanelTitle,
                detail: LumaBarL10n.helpTogglePanelDetail
            ),
            HelpShortcutItem(
                id: "escape",
                keys: ["Esc"],
                title: LumaBarL10n.helpEscapeTitle,
                detail: LumaBarL10n.helpEscapeDetail
            ),
            HelpShortcutItem(
                id: "shell",
                keys: ["⌘", "⇧", "↩"],
                title: LumaBarL10n.helpShellTitle,
                detail: LumaBarL10n.helpShellDetail
            ),
            HelpShortcutItem(
                id: "voice",
                keys: ["⌘", "⇧", "M"],
                title: LumaBarL10n.helpVoiceTitle,
                detail: LumaBarL10n.helpVoiceDetail
            ),
            HelpShortcutItem(
                id: "translate",
                keys: translateShortcutKeys,
                title: LumaBarL10n.helpTranslateTitle,
                detail: LumaBarL10n.helpTranslateDetail
            ),
            HelpShortcutItem(
                id: "theme",
                keys: ["⌘", "⌥", "1…7"],
                title: LumaBarL10n.helpThemeTitle,
                detail: LumaBarL10n.helpThemeDetail
            )
        ]
    }

    static var features: [HelpFeatureItem] {
        [
            HelpFeatureItem(
                id: "hover",
                symbol: "rectangle.topthird.inset.filled",
                title: LumaBarL10n.helpHoverTitle,
                detail: LumaBarL10n.helpHoverDetail
            ),
            HelpFeatureItem(
                id: "music",
                symbol: "music.note.list",
                title: LumaBarL10n.helpMusicTitle,
                detail: LumaBarL10n.helpMusicDetail
            ),
            HelpFeatureItem(
                id: "agent",
                symbol: "sparkles",
                title: LumaBarL10n.helpAgentTitle,
                detail: LumaBarL10n.helpAgentDetail
            ),
            HelpFeatureItem(
                id: "pet",
                symbol: "pawprint.fill",
                title: LumaBarL10n.helpPetTitle,
                detail: LumaBarL10n.helpPetDetail
            )
        ]
    }
}

// MARK: - Key Cap

struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.92))
            .padding(.horizontal, label.count > 1 ? 8 : 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 0.5, y: 0.5)
            .accessibilityLabel(label)
    }
}

struct KeyCapChord: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                if index > 0 {
                    Text("+")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                KeyCap(label: key)
            }
        }
    }
}

// MARK: - Help View

struct HelpView: View {
    var onClose: () -> Void

    var body: some View {
        ZStack {
            // Adaptive system material — separate help window only (not island chrome).
            Rectangle()
                .fill(.thickMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.35)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        sectionHeader(LumaBarL10n.helpSectionShortcuts, symbol: "keyboard")
                        VStack(spacing: 8) {
                            ForEach(HelpGuideContent.shortcuts) { item in
                                shortcutRow(item)
                            }
                        }

                        sectionHeader(LumaBarL10n.helpSectionFeatures, symbol: "sparkle.magnifyingglass")
                        VStack(spacing: 8) {
                            ForEach(HelpGuideContent.features) { item in
                                featureRow(item)
                            }
                        }

                        Text(LumaBarL10n.helpFooter)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 520, idealHeight: 560)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 2) {
                Text(LumaBarL10n.helpTitle)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(LumaBarL10n.helpSubtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.quaternary.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .help(LumaBarL10n.helpClose)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .textCase(.uppercase)
            .tracking(0.4)
    }

    private func shortcutRow(_ item: HelpShortcutItem) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(item.detail)
                    .font(.system(size: 11.5, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            KeyCapChord(keys: item.keys)
        }
        .padding(14)
        .background(cardBackground)
    }

    private func featureRow(_ item: HelpFeatureItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary.opacity(0.55))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(item.detail)
                    .font(.system(size: 11.5, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.background.opacity(0.42))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

// MARK: - On-demand presenter (never auto-shows at launch)

@MainActor
enum HelpGuidePresenter {
    private static var window: NSWindow?

    /// Opens the help cheatsheet only when explicitly invoked (menu / action).
    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = HelpView {
            close()
        }
        let hosting = NSHostingView(rootView: root)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = LumaBarL10n.helpWindowTitle
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = hosting
        panel.center()
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            Task { @MainActor in
                Self.window = nil
            }
        }

        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.orderOut(nil)
        window = nil
    }

    /// Rebuild the open Help window after a language change.
    static func reloadForLanguageChange() {
        guard window != nil else { return }
        close()
        show()
    }
}

// MARK: - About & Acknowledgements

struct LumaBarCreditEntry: Identifiable {
    let id: String
    let name: String
    let role: String
    let founder: String?
    let url: URL
}

/// Acknowledgements data. Roles resolve through the localization system each access,
/// so a mid-run language switch updates the list without recreating it.
enum LumaBarCredits {
    static var entries: [LumaBarCreditEntry] {
        [
            LumaBarCreditEntry(
                id: "xcombinator",
                name: "X-Combinator",
                role: LumaBarL10n.aboutCreditsXCombinatorRole,
                founder: "Lloyd",
                url: URL(string: "https://x-combinator.xyz/")!
            ),
            LumaBarCreditEntry(
                id: "everlasting",
                name: "Everlasting Zone",
                role: LumaBarL10n.aboutCreditsEverlastingRole,
                founder: "Shorpen",
                url: URL(string: "https://everlasting.zone/")!
            ),
            LumaBarCreditEntry(
                id: "adventurex",
                name: "AdventureX",
                role: LumaBarL10n.aboutCreditsAdventureXRole,
                founder: nil,
                url: URL(string: "https://www.adventure-x.cn/")!
            ),
            LumaBarCreditEntry(
                id: "aws",
                name: "Amazon Web Services · 亚马逊云科技",
                role: LumaBarL10n.aboutCreditsAWSRole,
                founder: nil,
                url: URL(string: "https://www.amazonaws.cn/en/")!
            ),
            LumaBarCreditEntry(
                id: "bonjour",
                name: "Bonjour",
                role: LumaBarL10n.aboutCreditsBonjourRole,
                founder: nil,
                url: URL(string: "https://bonjour.bio/")!
            )
        ]
    }
}

struct AboutLumaBarView: View {
    let onClose: () -> Void

    private var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "v\(version) (\(build))"
    }

    private var copyrightLine: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Luma Bar Core Team"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "capsule.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LumaBarL10n.appName)
                        .font(.system(size: 16, weight: .bold))
                    Text(versionLine)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            Text(copyrightLine)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            Divider()
                .padding(.vertical, 12)

            // Credits heading
            VStack(alignment: .leading, spacing: 3) {
                Text(LumaBarL10n.aboutCreditsTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(LumaBarL10n.aboutCreditsIntro)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)

            // Credit cards
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(LumaBarCredits.entries) { entry in
                        creditCard(entry)
                    }
                }
                .padding(.bottom, 2)
            }

            // Footer
            HStack {
                Spacer()
                Button(LumaBarL10n.aboutCreditsClose) {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 400, height: 470)
        .background(.regularMaterial)
    }

    private func creditCard(_ entry: LumaBarCreditEntry) -> some View {
        Button {
            NSWorkspace.shared.open(entry.url)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(entry.role)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if let founder = entry.founder {
                        Text(LumaBarL10n.aboutCreditsFounder(founder))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 4)
                VStack(spacing: 2) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(LumaBarL10n.aboutCreditsOpenWebsite)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 1)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(LumaBarL10n.aboutCreditsOpenWebsite + " · " + entry.url.absoluteString)
    }
}

@MainActor
enum AboutLumaBarPresenter {
    private static var window: NSWindow?

    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingView(rootView: AboutLumaBarView { close() })
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = LumaBarL10n.appName
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.center()
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            Task { @MainActor in
                Self.window = nil
            }
        }
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }

    /// Recreate the content when the OS language changes mid-run.
    static func reloadForLanguageChange() {
        guard let window else { return }
        let root = AboutLumaBarView { close() }
        window.contentView = NSHostingView(rootView: root)
    }
}
