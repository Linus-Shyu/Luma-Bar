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

enum NotchSide {
    case left
    case right
}

enum IslandPanelAction {
    case toggleExpanded
    case collapseExpanded
    case togglePlayback
    case nextTrack
    case openAgent
    case showMusic
    case showSystem
    case showAgentMode
    case openExternalToken
    case agentQuickAction(AgentQuickActionKind)
    /// Local / Apple Music / NetEase pills — mouseDown routed in AppKit so SwiftUI rebuilds cannot cancel them.
    case setMusicLibrarySource(IslandMusicLibrarySource)
}

enum IslandContentMode: String, CaseIterable {
    case music = "Music"
    case system = "System"
    case agent = "Agent"
    case token = "Token"
}

enum AuraOpacityPreference {
    static let defaultsKey = "auraOpacity"
    static let didChangeNotification = Notification.Name("LumaBarAuraOpacityDidChange")
    /// Thin frosted glass by default; slider spans nearly clear → soft frost.
    static let defaultValue: Double = 0.22
    static let range: ClosedRange<Double> = 0.0...1.0

    static var current: Double {
        get { clamped(UserDefaults.standard.object(forKey: defaultsKey) as? Double ?? defaultValue) }
        set {
            let value = clamped(newValue)
            UserDefaults.standard.set(value, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChangeNotification, object: value)
        }
    }

    static func clamped(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

enum IslandTheme: String, CaseIterable {
    case void
    case horizon
    case forge
    case grid
    case arcade
    case nook
    case aura

    private static let defaultsKey = "LumaBar.theme"

    static var saved: IslandTheme {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else {
            return .void
        }
        if let theme = IslandTheme(rawValue: rawValue) {
            return theme
        }
        // Migrate pre–Scheme B identifiers (and keep pets on the same skins).
        let migrated: IslandTheme
        switch rawValue {
        case "bar": migrated = .void
        case "mistBlue": migrated = .horizon
        case "adventureX": migrated = .forge
        case "eightBit": migrated = .grid
        case "pixelConsole": migrated = .arcade
        case "pixelCat": migrated = .nook
        case "liquidGlass": migrated = .aura
        default: return .void
        }
        migrated.persist()
        return migrated
    }

    var displayName: String {
        switch self {
        case .void:
            return "Void"
        case .horizon:
            return "Horizon"
        case .forge:
            return "Forge"
        case .grid:
            return "Grid"
        case .arcade:
            return "Arcade"
        case .nook:
            return "Nook"
        case .aura:
            return "Aura"
        }
    }

    var isGrid: Bool {
        self == .grid
    }

    var isArcade: Bool {
        self == .arcade
    }

    var isNook: Bool {
        self == .nook
    }

    var isForge: Bool {
        self == .forge
    }

    var isLight: Bool {
        self == .horizon || self == .forge || self == .nook
    }

    var showsDesktopPet: Bool {
        self == .horizon || isArcade || isNook
    }

    var desktopPetName: String {
        switch self {
        case .horizon:
            return "Panda"
        case .nook:
            return "Mochi"
        case .arcade:
            return "Pup"
        default:
            return LumaBarL10n.companionSubtitle
        }
    }

    var desktopPetMessages: [String] {
        switch self {
        case .horizon:
            return [
                "慢慢来，今天也要稳稳地。",
                "休息一下，看看远处吧。",
                "竹子备好了，继续专注。",
                "别着急，我陪你慢慢处理。",
                "音乐响起，我就开始摇摆。",
                "系统很安静，一切都在掌握中。",
                "今天也要保持一点松弛感。",
                "困了就眯一会儿。",
                "你今天做了好多事，真的很厉害。",
                "专注力这么强，熊猫都要佩服了。",
                "你处理问题的方式好沉稳，学到了。",
                "有你在，什么难题都能搞定。"
            ]
        case .nook:
            return [
                "喵，今天想听哪一首？",
                "这首不错，尾巴都跟着摇了。",
                "CPU 有点热，猫爪替你盯着。",
                "点开 Agent，交给聪明猫猫。",
                "忙完记得伸个懒腰，喵。",
                "我没有偷懒，只是在晒屏幕。",
                "再点一下，我就继续陪你。",
                "灵感来了，快抓住它。",
                "喵～你今天好厉害，猫猫认证。",
                "这么努力，你是我见过最棒的铲屎官。",
                "你刚才那操作，帅到尾巴竖起来了。",
                "能陪这么聪明的你，猫猫超有面子的。"
            ]
        case .arcade:
            return [
                "汪！今天要先做哪件事？",
                "换首歌吧，我已经开始摇尾巴了。",
                "CPU 有点忙，我帮你盯着。",
                "Agent 已就位，我来闻闻线索。",
                "任务完成，奖励一块小饼干吧。",
                "工作很久啦，出去走两步吧。",
                "有新消息的话，我会提醒你。",
                "我一直在这里陪你，汪。",
                "汪汪！你今天也太厉害了吧！",
                "你是狗狗见过最努力的主人，汪！",
                "这么强的主人，我尾巴都摇断了！",
                "跟着你，狗狗每天都好开心，汪！"
            ]
        default:
            return []
        }
    }

    var isPixelStyled: Bool {
        switch self {
        case .forge, .grid, .arcade: return true
        case .void, .horizon, .nook, .aura: return false
        }
    }

    /// Aura uses real `NSVisualEffectView` frosted glass; other themes stay on fixed layer fills.
    var usesBackdropMaterial: Bool { self == .aura }

    var fontDesign: Font.Design {
        isPixelStyled && !isNook ? .monospaced : .rounded
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if isForge, AdventureXPixelFont.isAvailable {
            return .custom(AdventureXPixelFont.primaryPostScriptName, size: size)
        }
        return .system(size: size, weight: weight, design: fontDesign)
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if isForge, let font = AdventureXPixelFont.nsFont(size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    var compactCornerRadius: CGFloat {
        .infinity
    }

    var expandedCornerRadius: CGFloat {
        switch self {
        case .void, .horizon, .arcade, .nook, .forge: return NotchMetrics.expandedCornerRadius
        case .aura: return 28
        case .grid: return 4
        }
    }

    var cardCornerRadius: CGFloat {
        switch self {
        case .void, .horizon, .arcade: return 11
        case .nook: return 14
        case .forge: return 5
        case .grid: return 2
        case .aura: return 16
        }
    }

    var controlCornerRadius: CGFloat {
        switch self {
        case .void, .horizon, .arcade, .nook, .aura: return 999
        case .forge: return 3
        case .grid: return 2
        }
    }

    var fieldCornerRadius: CGFloat {
        switch self {
        case .void, .horizon, .arcade: return 8
        case .nook: return 10
        case .forge: return 3
        case .grid: return 2
        case .aura: return 12
        }
    }

    var tokenOverlayCornerRadius: CGFloat {
        switch self {
        case .void: return NotchMetrics.codexTokenCornerRadius
        case .horizon: return NotchMetrics.codexTokenCornerRadius
        case .forge: return 5
        case .grid: return 4
        case .arcade: return 18
        case .nook: return 22
        case .aura: return 28
        }
    }

    var primaryAccent: Color {
        switch self {
        case .void:
            return Color.islandTangerine
        case .horizon:
            return Color(red: 0.392, green: 0.678, blue: 0.941)
        case .forge:
            return Color(red: 0.843, green: 0.353, blue: 0.153)
        case .grid:
            return Color(red: 1.0, green: 0.82, blue: 0.40)
        case .arcade:
            return Color(red: 1.0, green: 0.70, blue: 0.31)
        case .nook:
            return Color(red: 0.855, green: 0.498, blue: 0.337)
        case .aura:
            // Pearl specular accent (visionOS glass highlight family).
            return Color(red: 0.86, green: 0.93, blue: 0.98)
        }
    }

    var activityAccent: Color {
        switch self {
        case .void:
            return Color.islandGreen
        case .horizon:
            return Color(red: 0.282, green: 0.784, blue: 0.545)
        case .forge:
            return Color(red: 0.176, green: 0.439, blue: 0.286)
        case .grid, .arcade:
            return Color(red: 0.32, green: 0.95, blue: 0.46)
        case .nook:
            return Color(red: 0.929, green: 0.675, blue: 0.463)
        case .aura:
            return Color(red: 0.72, green: 0.90, blue: 0.98)
        }
    }

    var pixelBorder: Color {
        switch self {
        case .arcade:
            return Color(red: 0.33, green: 0.37, blue: 0.61)
        case .nook:
            return Color(red: 0.835, green: 0.722, blue: 0.663)
        case .void, .grid:
            return Color(red: 0.33, green: 0.96, blue: 0.78)
        case .horizon:
            return Color(red: 0.392, green: 0.592, blue: 0.788)
        case .forge:
            return Color(red: 0.212, green: 0.243, blue: 0.204)
        case .aura:
            return Color.white.opacity(0.28)
        }
    }

    var pixelControlFill: Color {
        switch self {
        case .arcade:
            return Color(red: 0.15, green: 0.18, blue: 0.30)
        case .nook:
            return Color(red: 0.969, green: 0.925, blue: 0.886)
        case .void, .grid:
            return pixelBorder.opacity(0.1)
        case .horizon:
            return Color(red: 0.929, green: 0.969, blue: 1.0)
        case .forge:
            return Color(red: 0.784, green: 0.745, blue: 0.647)
        case .aura:
            return Color.white.opacity(0.04)
        }
    }

    var preferredColorScheme: ColorScheme {
        isLight ? .light : .dark
    }

    var foregroundColor: Color {
        if isForge {
            return Color(red: 0.153, green: 0.212, blue: 0.173)
        }
        if isNook {
            return Color(red: 0.204, green: 0.165, blue: 0.153)
        }
        if self == .aura {
            return Color(red: 0.94, green: 0.98, blue: 1.0)
        }
        return isLight
            ? Color(red: 0.094, green: 0.204, blue: 0.322)
            : .white
    }

    var mutedForegroundColor: Color {
        if isForge {
            return Color(red: 0.424, green: 0.412, blue: 0.341)
        }
        if isNook {
            return Color(red: 0.455, green: 0.404, blue: 0.38)
        }
        if self == .aura {
            return Color(red: 0.78, green: 0.90, blue: 0.96)
        }
        return isLight
            ? Color(red: 0.471, green: 0.565, blue: 0.667)
            : .white
    }

    func foreground(opacity: Double = 1) -> Color {
        foregroundColor.opacity(opacity)
    }

    func mutedForeground(opacity: Double = 1) -> Color {
        mutedForegroundColor.opacity(opacity)
    }

    var subtleFill: Color {
        if isForge {
            return Color(red: 0.914, green: 0.875, blue: 0.788).opacity(0.92)
        }
        if isNook {
            return Color.white.opacity(0.48)
        }
        if self == .aura {
            return Color.clear
        }
        return isLight
            ? Color(red: 0.929, green: 0.969, blue: 1.0).opacity(0.82)
            : Color.white.opacity(0.08)
    }

    var controlFill: Color {
        if isNook {
            return Color.white.opacity(0.52)
        }
        if self == .aura {
            return Color.white.opacity(0.04)
        }
        return isPixelStyled ? pixelControlFill : (isLight ? primaryAccent.opacity(0.12) : Color.white.opacity(0.08))
    }

    var controlForeground: Color {
        isLight ? foregroundColor : Color.white
    }

    var accentForeground: Color {
        isLight ? Color.white : Color.black
    }

    var separatorColor: Color {
        if self == .aura {
            return Color.white.opacity(0.10)
        }
        return isNook
            ? pixelBorder.opacity(0.34)
            : (isLight ? pixelBorder.opacity(0.2) : Color.white.opacity(0.1))
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum AdventureXPixelFont {
    static let primaryPostScriptName = "Ark-Pixel-12px-Mono-zh_cn-Regular"
    static let latinPostScriptName = "Ark-Pixel-12px-Mono-latin-Regular"
    nonisolated(unsafe) private static var didRegister = false

    static var isAvailable: Bool {
        registerIfNeeded()
        return NSFont(name: primaryPostScriptName, size: 12) != nil
    }

    static func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true
        for resource in ["ArkPixel12Mono-ZHCN", "ArkPixel12Mono-Latin"] {
            guard let url = Bundle.main.url(
                forResource: resource,
                withExtension: "otf",
                subdirectory: "Fonts"
            ) else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func nsFont(size: CGFloat) -> NSFont? {
        registerIfNeeded()
        return NSFont(name: primaryPostScriptName, size: size)
            ?? NSFont(name: latinPostScriptName, size: size)
    }
}

struct IslandThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = IslandTheme.void
}

extension EnvironmentValues {
    var islandTheme: IslandTheme {
        get { self[IslandThemeEnvironmentKey.self] }
        set { self[IslandThemeEnvironmentKey.self] = newValue }
    }
}

enum IslandAppContext: Equatable {
    case general
    case coding
    case writing
    case reading
    case gaming
    case netEase

    var agentTitle: String {
        switch self {
        case .coding:
            return LumaBarL10n.agentTitleCode
        case .writing:
            return LumaBarL10n.agentTitleWriting
        case .reading:
            return LumaBarL10n.agentTitleReading
        case .gaming:
            return LumaBarL10n.agentTitleGaming
        case .netEase:
            return LumaBarL10n.agentTitleMusic
        case .general:
            return LumaBarL10n.agentTitleGeneral
        }
    }

    var label: String {
        switch self {
        case .coding:
            return LumaBarL10n.agentContextCode
        case .writing:
            return LumaBarL10n.agentContextWriting
        case .reading:
            return LumaBarL10n.agentContextReading
        case .gaming:
            return LumaBarL10n.agentContextGaming
        case .netEase:
            return LumaBarL10n.agentContextMusic
        case .general:
            return LumaBarL10n.agentContextGeneral
        }
    }

    var icon: String {
        switch self {
        case .coding:
            return "chevron.left.forwardslash.chevron.right"
        case .writing:
            return "text.cursor"
        case .reading:
            return "doc.text.magnifyingglass"
        case .gaming:
            return "gamecontroller.fill"
        case .netEase:
            return "music.note"
        case .general:
            return "sparkles"
        }
    }
}

enum AgentQuickActionKind: String, Identifiable, Sendable {
    case inspectScreen
    case briefContext
    case draftReply
    case makePlan
    case system
    case playPause
    case nextTrack
    case shell
    case explainCode
    case refactorCode
    case commentCode
    case professionalWriting
    case simplifyWriting
    case proofreadWriting
    case outlineWriting
    case summarizePage
    case keyTakeaways
    case explainConcept
    case gameGuide
    case gameBuild
    case gameScreenshot
    case gameMusic

    var id: String { rawValue }
}

struct AgentQuickAction: Identifiable, Sendable {
    let kind: AgentQuickActionKind
    let title: String
    let icon: String

    var id: AgentQuickActionKind { kind }
}

enum AgentRequestPurpose: Sendable {
    case conversation
    case shellCommand
    case translation
}

struct LocalToolPlan: Decodable, Sendable {
    let action: String
    let query: String?
    let player: String?
    let value: Double?
    let enabled: Bool?
    let appName: String?
}

