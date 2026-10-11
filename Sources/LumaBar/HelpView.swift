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

struct LumaBarIndividualSponsor: Identifiable {
    let id: String
    let name: String
    let avatarName: String
    let url: URL?
}

struct LumaBarCreditEntry: Identifiable {
    let id: String
    let name: String
    let role: String
    let founder: String?
    let thanks: String
    let url: URL
    let logoName: String
    /// Light artwork needs a dark tile behind it; dark artwork a light tile.
    let usesLightLogo: Bool
    /// Wide wordmark treatment instead of a square icon tile.
    let isWordmark: Bool
    /// The artwork ships with its own background (e.g. a filled square mark) —
    /// render it bare, just rounded and clipped.
    let hasOwnBackground: Bool
}

/// Acknowledgements data. Localized strings resolve on each access, so a mid-run
/// language switch updates the list without recreating it.
enum LumaBarCredits {
    static var entries: [LumaBarCreditEntry] {
        [
            LumaBarCreditEntry(
                id: "xcombinator",
                name: "X-Combinator",
                role: LumaBarL10n.aboutCreditsXCombinatorRole,
                founder: "Lloyd",
                thanks: LumaBarL10n.aboutThanksXCombinator,
                url: URL(string: "https://x-combinator.xyz/")!,
                logoName: "xcombinator",
                usesLightLogo: true,
                isWordmark: false,
                hasOwnBackground: true
            ),
            LumaBarCreditEntry(
                id: "everlasting",
                name: "Everlasting Zone",
                role: LumaBarL10n.aboutCreditsEverlastingRole,
                founder: "Shorpen",
                thanks: LumaBarL10n.aboutThanksEverlasting,
                url: URL(string: "https://everlasting.zone/")!,
                logoName: "everlasting",
                usesLightLogo: true,
                isWordmark: true,
                hasOwnBackground: false
            ),
            LumaBarCreditEntry(
                id: "adventurex",
                name: "AdventureX",
                role: LumaBarL10n.aboutCreditsAdventureXRole,
                founder: nil,
                thanks: LumaBarL10n.aboutThanksAdventureX,
                url: URL(string: "https://www.adventure-x.cn/")!,
                logoName: "adventurex",
                usesLightLogo: true,
                isWordmark: false,
                hasOwnBackground: false
            ),
            LumaBarCreditEntry(
                id: "aws",
                name: "Amazon Web Services · 亚马逊云科技",
                role: LumaBarL10n.aboutCreditsAWSRole,
                founder: nil,
                thanks: LumaBarL10n.aboutThanksAWS,
                url: URL(string: "https://www.amazonaws.cn/en/")!,
                logoName: "aws",
                usesLightLogo: false,
                isWordmark: false,
                hasOwnBackground: true
            ),
            LumaBarCreditEntry(
                id: "bonjour",
                name: "Bonjour",
                role: LumaBarL10n.aboutCreditsBonjourRole,
                founder: nil,
                thanks: LumaBarL10n.aboutThanksBonjour,
                url: URL(string: "https://bonjour.bio/")!,
                logoName: "bonjour",
                usesLightLogo: true,
                isWordmark: false,
                hasOwnBackground: false
            )
        ]
    }

    static var individuals: [LumaBarIndividualSponsor] {
        [
            LumaBarIndividualSponsor(id: "caiziqi", name: "蔡子奇", avatarName: "sponsor-caiziqi", url: nil),
            LumaBarIndividualSponsor(
                id: "hongbro886",
                name: "Hongbro886",
                avatarName: "sponsor-hongbro886",
                url: URL(string: "https://github.com/Hongbro886")
            ),
            LumaBarIndividualSponsor(id: "qianxun", name: "千峋", avatarName: "sponsor-qianxun", url: nil)
        ]
    }

    static func avatar(named name: String) -> NSImage? {
        logo(named: name)
    }

    static func logo(named name: String) -> NSImage? {
        let bundle = LumaBarL10n.resourceBundle
        // SPM's resource processing flattens subdirectories into the bundle root;
        // keep the nested lookup as a fallback for layouts that preserve folders.
        let candidates: [String?] = [
            bundle.path(forResource: name, ofType: "png"),
            bundle.path(forResource: name, ofType: "png", inDirectory: "Credits")
        ]
        for path in candidates {
            guard let path else { continue }
            if let image = NSImage(contentsOfFile: path) {
                return image
            }
        }
        return nil
    }
}

struct AboutLumaBarView: View {
    let onClose: () -> Void
    @State private var hoveredEntryID: String?

    private var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "v\(version) (\(build))"
    }

    private var copyrightLine: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Luma Bar Core Team"
    }

    private var appIcon: NSImage? {
        NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .padding(.vertical, 14)

            Text(LumaBarL10n.aboutCreditsIntro)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LumaBarL10n.aboutThanksTitle.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(.tertiary)
                    ForEach(LumaBarCredits.entries) { entry in
                        creditCard(entry)
                    }

                    Text(LumaBarL10n.aboutIndividualTitle.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)
                    Text(LumaBarL10n.aboutIndividualThanks)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    individualSponsors
                }
                .padding(.bottom, 2)
            }

            footer
        }
        .padding(22)
        .frame(width: 460, height: 790)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.05),
                        .clear,
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .scaledToFit()
                        .padding(5)
                } else {
                    Image(systemName: "capsule.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 54, height: 54)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.5), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(LumaBarL10n.appName)
                    .font(.system(size: 19, weight: .bold))
                Text(versionLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(copyrightLine)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            Text("Luma Bar Core Team")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(LumaBarL10n.aboutCreditsClose) {
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 14)
    }

    private var individualSponsors: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(LumaBarCredits.individuals) { sponsor in
                Button {
                    if let url = sponsor.url {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    VStack(spacing: 6) {
                        Group {
                            if let image = LumaBarCredits.avatar(named: sponsor.avatarName) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                ZStack {
                                    Circle().fill(Color.primary.opacity(0.1))
                                    Text(String(sponsor.name.prefix(1)))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.12), radius: 4, y: 1)

                        Text(sponsor.name)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(sponsor.url == nil ? Color.secondary : Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .help(sponsor.url?.absoluteString ?? sponsor.name)
                .disabled(sponsor.url == nil)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func creditCard(_ entry: LumaBarCreditEntry) -> some View {
        let isHovered = hoveredEntryID == entry.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 13) {
                logoTile(entry)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(entry.role)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if let founder = entry.founder {
                        Text(LumaBarL10n.aboutCreditsFounder(founder))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovered ? Color.accentColor : Color.secondary.opacity(0.5))
            }

            Text(entry.thanks)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                NSWorkspace.shared.open(entry.url)
            } label: {
                HStack(spacing: 4) {
                    Text(LumaBarL10n.aboutCreditsOpenWebsite)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: isHovered
                            ? [Color.accentColor.opacity(0.5), Color.white.opacity(0.06)]
                            : [Color.white.opacity(0.14), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(isHovered ? 0.10 : 0.05), radius: isHovered ? 8 : 4, y: isHovered ? 2 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                hoveredEntryID = hovering ? entry.id : nil
            }
        }
    }

    @ViewBuilder
    private func logoTile(_ entry: LumaBarCreditEntry) -> some View {
        let corner: CGFloat = entry.isWordmark ? 10 : 13
        let size: CGSize = entry.isWordmark
            ? CGSize(width: 116, height: 52)
            : CGSize(width: 60, height: 60)
        Group {
            if entry.hasOwnBackground {
                logoImage(entry)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: entry.usesLightLogo
                                ? [Color(white: 0.16), Color(white: 0.05)]
                                : [Color.white.opacity(0.75), Color.white.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: size.width, height: size.height)
                    .overlay(
                        logoImage(entry)
                            .resizable()
                            .scaledToFit()
                            .padding(entry.isWordmark ? 12 : 10)
                    )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func logoImage(_ entry: LumaBarCreditEntry) -> Image {
        if let image = LumaBarCredits.logo(named: entry.logoName) {
            return Image(nsImage: image)
        }
        return Image(systemName: "building.columns")
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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 790),
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
