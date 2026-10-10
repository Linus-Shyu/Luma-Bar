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

struct PixelGridOverlay: View {
    var body: some View {
        Canvas { context, size in
            var grid = Path()

            for x in stride(from: CGFloat(0), through: size.width, by: 8) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }

            for y in stride(from: CGFloat(0), through: size.height, by: 8) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }

            context.stroke(grid, with: .color(.white.opacity(0.028)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

struct PixelAccentRail: View {
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Canvas { context, size in
            var index = 0
            for x in stride(from: CGFloat(0), to: size.width, by: 10) {
                let width = min(8, size.width - x)
                let color = index.isMultiple(of: 3)
                    ? theme.primaryAccent
                    : theme.pixelBorder
                context.fill(
                    Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                    with: .color(color.opacity(0.9))
                )
                index += 1
            }
        }
        .allowsHitTesting(false)
    }
}

struct AdventureXGridOverlay: View {
    var body: some View {
        Canvas { context, size in
            var fineGrid = Path()
            for x in stride(from: CGFloat(0), through: size.width, by: 16) {
                fineGrid.move(to: CGPoint(x: x, y: 0))
                fineGrid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: CGFloat(0), through: size.height, by: 16) {
                fineGrid.move(to: CGPoint(x: 0, y: y))
                fineGrid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(
                fineGrid,
                with: .color(Color(red: 0.18, green: 0.23, blue: 0.18).opacity(0.055)),
                lineWidth: 0.7
            )

            var scanLines = Path()
            for y in stride(from: CGFloat(8), through: size.height, by: 32) {
                scanLines.move(to: CGPoint(x: 0, y: y))
                scanLines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(
                scanLines,
                with: .color(Color(red: 0.72, green: 0.27, blue: 0.11).opacity(0.07)),
                lineWidth: 1
            )
        }
        .allowsHitTesting(false)
    }
}

struct AdventureXHardwareMarks: View {
    var body: some View {
        GeometryReader { proxy in
            let color = Color(red: 0.29, green: 0.31, blue: 0.25).opacity(0.72)
            Group {
                Text("+").position(x: 10, y: 10)
                Text("+").position(x: proxy.size.width - 10, y: 10)
                Text("+").position(x: 10, y: proxy.size.height - 10)
                Text("+").position(x: proxy.size.width - 10, y: proxy.size.height - 10)
            }
            .font(AdventureXPixelFont.isAvailable
                ? .custom(AdventureXPixelFont.primaryPostScriptName, size: 13)
                : .system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
        }
        .allowsHitTesting(false)
    }
}

struct ThemeRectShape: InsettableShape {
    let radius: CGFloat
    let chamfer: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard chamfer > 0 else {
            return RoundedRectangle(
                cornerRadius: max(0, radius - insetAmount),
                style: .continuous
            ).path(in: rect)
        }

        let cut = min(chamfer, rect.width / 3, rect.height / 3)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> ThemeRectShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

struct CompactBarShape: InsettableShape {
    let radius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let r = min(max(0, radius - insetAmount), rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> CompactBarShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}


/// FROZEN UI (2026-08-03) — do not restyle. See `.cursor/rules/liquid-glass-ui-frozen.mdc`.
/// visionOS Glass Material tokens — aligned with Apple visionOS Figma Community kit:
/// ultra-thin vibrancy, dual inner shadows, and a 0.5–1pt rim light.
enum LiquidGlassPaint {
    enum Role {
        case compact
        case panel
        case card
        case overlay
        case control
    }

    static func washOpacity(role: Role, isHovering: Bool, isSelected: Bool) -> Double {
        switch role {
        case .compact:
            // Near-clear wash — wallpaper should dominate.
            return isHovering ? 0.02 : 0.0
        case .panel, .overlay:
            return 0.0
        case .card:
            return isSelected ? 0.04 : 0.015
        case .control:
            return isSelected ? 0.06 : 0.03
        }
    }

    /// Rim Light width from the Glass Material spec (0.5pt idle → 1pt emphasized).
    static func rimWidth(emphasized: Bool, role: Role) -> CGFloat {
        switch role {
        case .panel, .overlay:
            return 0.75
        case .card:
            return 0.5
        case .compact, .control:
            return emphasized ? 0.75 : 0.5
        }
    }

    static func rimGradient(emphasized: Bool, role: Role) -> LinearGradient {
        switch role {
        case .panel, .overlay:
            // Large sheets need a cleaner, more even rim — less milky than the bar.
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.42),
                    Color.white.opacity(0.14),
                    Color.white.opacity(0.28),
                    Color.white.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [
                    Color.white.opacity(emphasized ? 0.48 : 0.32),
                    Color.white.opacity(emphasized ? 0.22 : 0.14),
                    Color.white.opacity(emphasized ? 0.30 : 0.18),
                    Color.white.opacity(emphasized ? 0.16 : 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// Dual inner-shadow stack used by visionOS glass surfaces.
struct LiquidGlassInnerShadows<S: Shape>: View {
    let shape: S
    var role: LiquidGlassPaint.Role = .compact

    var body: some View {
        Group {
            switch role {
            case .compact, .control:
                // Soft edge only — avoid dense milk from heavy dual shadows.
                ZStack {
                    shape
                        .stroke(Color.white.opacity(0.06), lineWidth: 2.5)
                        .blur(radius: 1.2)
                    shape
                        .stroke(Color.black.opacity(0.14), lineWidth: 3)
                        .offset(y: 0.5)
                        .blur(radius: 2.2)
                }
            case .panel, .overlay:
                // Edge catch only — no dark/gray fill into the sheet.
                shape
                    .stroke(Color.white.opacity(0.08), lineWidth: 1.5)
                    .blur(radius: 0.8)
            case .card:
                // Content wells only need a soft inner catch — not full glass depth.
                shape
                    .stroke(Color.white.opacity(0.05), lineWidth: 1.5)
                    .blur(radius: 0.8)
            }
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

/// Aura frosted-glass plate. `auraOpacity` 0 ≈ clear tint, 1 = soft frost (still highly transparent).
/// Never paints an opaque white slab (that washed out light Aura text).
struct AuraPlateFill: View {
    var cornerRadius: CGFloat
    /// Compact bar silhouette: flat top + rounded bottom corners, like every other theme.
    /// The glass view gets a CAShapeLayer mask instead of a SwiftUI clipShape, which would
    /// freeze the blur solid.
    var flatTop: Bool = false
    @AppStorage(AuraOpacityPreference.defaultsKey) private var auraOpacity = AuraOpacityPreference.defaultValue

    private var resolved: Double { AuraOpacityPreference.clamped(auraOpacity) }

    /// Stick to thin materials only — `.popover` / menu fills are too milky for Aura.
    private var material: NSVisualEffectView.Material {
        resolved < 0.55 ? .underWindowBackground : .hudWindow
    }

    /// Floor stays very see-through; even 100% caps well below opaque.
    private var glassOpacity: Double { 0.10 + resolved * 0.48 }

    /// Barely-there pearl — just enough to read edges, never a wash.
    private var frostWash: Double { resolved * 0.05 }

    var body: some View {
        ZStack {
            AuraGlassBackdrop(cornerRadius: cornerRadius, flatTop: flatTop, material: material)
                .opacity(glassOpacity)
            if flatTop {
                CompactBarShape(radius: cornerRadius)
                    .fill(Color.white.opacity(frostWash))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(frostWash))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Slider shown inside Theme → Aura submenu.
struct AuraOpacitySliderView: View {
    @AppStorage(AuraOpacityPreference.defaultsKey) private var auraOpacity = AuraOpacityPreference.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LumaBarL10n.auraOpacity)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(Int((AuraOpacityPreference.clamped(auraOpacity) * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { AuraOpacityPreference.clamped(auraOpacity) },
                    set: { newValue in
                        let clamped = AuraOpacityPreference.clamped(newValue)
                        auraOpacity = clamped
                        NotificationCenter.default.post(
                            name: AuraOpacityPreference.didChangeNotification,
                            object: clamped
                        )
                    }
                ),
                in: AuraOpacityPreference.range
            )
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 232)
    }
}

/// Aura card/control frosted surface — lighter than the main plate, same opacity slider.
struct LiquidGlassSurface<S: InsettableShape>: View {
    let shape: S
    var role: LiquidGlassPaint.Role = .panel
    var isHovering: Bool = false
    var isSelected: Bool = false
    var selectedAccent: Color? = nil
    var cornerRadius: CGFloat = 16
    @AppStorage(AuraOpacityPreference.defaultsKey) private var auraOpacity = AuraOpacityPreference.defaultValue

    private var resolved: Double { AuraOpacityPreference.clamped(auraOpacity) }
    private var roleScale: Double { role == .card || role == .control ? 0.78 : 1.0 }

    var body: some View {
        ZStack {
            AuraGlassBackdrop(
                cornerRadius: cornerRadius,
                material: .underWindowBackground
            )
            .opacity((0.08 + resolved * 0.40) * roleScale)
            shape.fill(Color.white.opacity(resolved * 0.04 * roleScale))
            if isSelected, let selectedAccent {
                shape.fill(selectedAccent.opacity(0.10))
            }
        }
        .allowsHitTesting(false)
    }
}

struct CompactBarBackground: View {
    let isHovering: Bool
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let shape = CompactBarShape(radius: theme.compactCornerRadius)

        ZStack(alignment: .bottom) {
            switch theme {
            case .grid:
                shape.fill(Color(red: 0.025, green: 0.06, blue: 0.085).opacity(0.98))
                PixelGridOverlay()
                    .clipShape(shape)
                shape.strokeBorder(
                    theme.pixelBorder.opacity(isHovering ? 0.86 : 0.48),
                    lineWidth: isHovering ? 2 : 1
                )
            case .arcade:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.047, green: 0.11, blue: 0.16),
                            Color(red: 0.027, green: 0.075, blue: 0.11)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                shape.strokeBorder(
                    theme.pixelBorder.opacity(isHovering ? 0.95 : 0.68),
                    lineWidth: isHovering ? 2 : 1
                )
                Rectangle()
                    .fill(theme.primaryAccent.opacity(isHovering ? 0.9 : 0.58))
                    .frame(height: 1)
                    .clipShape(shape)
            case .nook:
                VisualEffectBackground(
                    material: .popover,
                    blendingMode: .behindWindow,
                    cornerRadius: NotchMetrics.compactHeight / 2
                )
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.88),
                            Color(red: 1.0, green: 0.955, blue: 0.91).opacity(0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.strokeBorder(
                    theme.pixelBorder.opacity(isHovering ? 0.68 : 0.38),
                    lineWidth: 1
                )
                Rectangle()
                    .fill(theme.primaryAccent.opacity(isHovering ? 0.72 : 0.42))
                    .frame(height: 1)
                    .clipShape(shape)
            case .horizon:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.995, blue: 1.0),
                            Color(red: 0.91, green: 0.96, blue: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                shape.strokeBorder(
                    theme.primaryAccent.opacity(isHovering ? 0.72 : 0.38),
                    lineWidth: isHovering ? 2 : 1
                )
            case .forge:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.925, green: 0.886, blue: 0.80),
                            Color(red: 0.973, green: 0.945, blue: 0.878),
                            Color(red: 0.914, green: 0.871, blue: 0.784)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                AdventureXGridOverlay()
                    .clipShape(shape)
                shape.strokeBorder(
                    theme.pixelBorder.opacity(isHovering ? 1 : 0.9),
                    lineWidth: isHovering ? 2 : 1
                )
                HStack(spacing: 2) {
                    Rectangle().fill(theme.primaryAccent).frame(width: 42)
                    Rectangle().fill(theme.activityAccent)
                }
                .frame(height: 3)
                .padding(.horizontal, 5)
                .padding(.bottom, 3)
                .clipShape(shape)
            case .aura:
                AuraPlateFill(
                    cornerRadius: NotchMetrics.compactHeight / 2,
                    flatTop: true
                )
            case .void:
                VisualEffectBackground(
                    material: .hudWindow,
                    blendingMode: .behindWindow,
                    cornerRadius: NotchMetrics.compactHeight / 2
                )
                shape.fill(NotchPaint.surface)
                shape.strokeBorder(NotchPaint.edge(isHovering: isHovering), lineWidth: 1)
            }
        }
        // Never clip liquid/bar glass with SwiftUI clipShape — it freezes blur solid.
        .modifier(CompactBarClipIfNeeded(theme: theme, shape: shape))
    }
}

struct CompactBarClipIfNeeded<S: Shape>: ViewModifier {
    let theme: IslandTheme
    let shape: S

    func body(content: Content) -> some View {
        if theme.usesBackdropMaterial {
            content
        } else {
            content.clipShape(shape)
        }
    }
}

struct ExpandedIslandBackground: View {
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let shape = ThemeRectShape(
            radius: theme.expandedCornerRadius,
            chamfer: 0
        )

        ZStack(alignment: .top) {
            switch theme {
            case .grid:
                shape.fill(Color(red: 0.025, green: 0.06, blue: 0.085).opacity(0.99))
                PixelGridOverlay()
                    .clipShape(shape)
                shape.strokeBorder(theme.pixelBorder.opacity(0.72), lineWidth: 2)
                PixelAccentRail()
                    .frame(height: 2)
                    .padding(.horizontal, 5)
                    .padding(.top, 4)
            case .arcade:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.047, green: 0.11, blue: 0.16),
                            Color(red: 0.027, green: 0.075, blue: 0.11)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                shape.strokeBorder(theme.pixelBorder.opacity(0.82), lineWidth: 2)
                PixelAccentRail()
                    .frame(height: 3)
                    .padding(.horizontal, 9)
                    .padding(.top, 5)
            case .nook:
                VisualEffectBackground(
                    material: .popover,
                    blendingMode: .behindWindow,
                    cornerRadius: theme.expandedCornerRadius
                )
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.82),
                            Color(red: 1.0, green: 0.955, blue: 0.91).opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.strokeBorder(Color.white.opacity(0.76), lineWidth: 1)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.primaryAccent, theme.activityAccent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 68, height: 2)
                    .padding(.top, 6)
            case .horizon:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.985, green: 0.997, blue: 1.0),
                            Color(red: 0.89, green: 0.95, blue: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.strokeBorder(theme.primaryAccent.opacity(0.44), lineWidth: 1.5)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [theme.primaryAccent, theme.activityAccent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 2)
                    .padding(.horizontal, 10)
                    .padding(.top, 5)
            case .forge:
                shape.fill(Color(red: 0.961, green: 0.933, blue: 0.863))
                AdventureXGridOverlay()
                    .clipShape(shape)
                shape.strokeBorder(theme.pixelBorder.opacity(0.98), lineWidth: 2)
                AdventureXHardwareMarks()
                    .clipShape(shape)
                HStack(spacing: 3) {
                    Rectangle().fill(theme.primaryAccent).frame(width: 82)
                    Rectangle().fill(theme.activityAccent).frame(width: 42)
                    Rectangle().fill(Color(red: 0.32, green: 0.34, blue: 0.28).opacity(0.64))
                }
                .frame(height: 4)
                .padding(.horizontal, 18)
                .padding(.top, 6)
            case .aura:
                AuraPlateFill(cornerRadius: theme.expandedCornerRadius)
            case .void:
                VisualEffectBackground(
                    material: .hudWindow,
                    blendingMode: .behindWindow,
                    cornerRadius: theme.expandedCornerRadius
                )
                shape.fill(NotchPaint.panel)
                shape.strokeBorder(.white.opacity(0.07), lineWidth: 1)
            }
        }
        .modifier(CompactBarClipIfNeeded(theme: theme, shape: shape))
    }
}

struct ThemedCardBackground: View {
    let isSelected: Bool
    let accent: Color?
    let cornerRadius: CGFloat?
    @Environment(\.islandTheme) private var theme

    init(isSelected: Bool = false, accent: Color? = nil, cornerRadius: CGFloat? = nil) {
        self.isSelected = isSelected
        self.accent = accent
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        let radius = cornerRadius ?? theme.cardCornerRadius
        let shape = ThemeRectShape(
            radius: radius,
            chamfer: 0
        )
        let selectedAccent = accent ?? theme.primaryAccent

        ZStack {
            switch theme {
            case .void:
                shape.fill(Color.white.opacity(isSelected ? 0.08 : 0.04))
                shape.strokeBorder(
                    isSelected ? selectedAccent.opacity(0.36) : Color.white.opacity(0.055),
                    lineWidth: 1
                )
            case .horizon:
                shape.fill(
                    isSelected
                        ? selectedAccent.opacity(0.16)
                        : Color.white.opacity(0.72)
                )
                shape.strokeBorder(
                    isSelected ? selectedAccent.opacity(0.68) : theme.pixelBorder.opacity(0.22),
                    lineWidth: isSelected ? 1.5 : 1
                )
            case .forge:
                shape.fill(
                    isSelected
                        ? Color(red: 0.906, green: 0.863, blue: 0.753)
                        : Color(red: 0.914, green: 0.875, blue: 0.788)
                )
                AdventureXGridOverlay()
                    .opacity(0.54)
                    .clipShape(shape)
                shape.strokeBorder(
                    isSelected ? selectedAccent.opacity(0.96) : theme.pixelBorder.opacity(0.8),
                    lineWidth: isSelected ? 2 : 1
                )
                RoundedRectangle(cornerRadius: max(1, radius - 2), style: .continuous)
                    .strokeBorder(Color.white.opacity(0.46), lineWidth: 1)
                    .padding(3)
            case .grid:
                shape.fill(isSelected ? selectedAccent.opacity(0.15) : Color.black.opacity(0.18))
                shape.strokeBorder(
                    isSelected ? selectedAccent.opacity(0.92) : theme.pixelBorder.opacity(0.25),
                    lineWidth: isSelected ? 2 : 1
                )
            case .arcade:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.106, green: 0.122, blue: 0.141),
                            Color(red: 0.078, green: 0.09, blue: 0.11)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                if isSelected {
                    shape.fill(selectedAccent.opacity(0.16))
                }
                shape.strokeBorder(
                    isSelected ? selectedAccent.opacity(0.9) : theme.pixelBorder.opacity(0.38),
                    lineWidth: isSelected ? 2 : 1
                )
            case .nook:
                shape.fill(isSelected ? selectedAccent.opacity(0.14) : Color.white.opacity(0.46))
                shape.strokeBorder(
                    isSelected ? selectedAccent.opacity(0.48) : Color.white.opacity(0.58),
                    lineWidth: 1
                )
            case .aura:
                LiquidGlassSurface(
                    shape: shape,
                    role: .card,
                    isSelected: isSelected,
                    selectedAccent: selectedAccent,
                    cornerRadius: radius
                )
            }
        }
        .modifier(CompactBarClipIfNeeded(theme: theme, shape: shape))
    }
}

struct PixelDogCompanion: View {
    let mode: IslandContentMode
    @State private var frames: [NSImage] = []

    private struct AnimationStep {
        let frame: Int
        let duration: TimeInterval
    }

    private var featuredFrame: Int {
        switch mode {
        case .music: return 9
        case .system: return 3
        case .agent: return 2
        case .token: return 6
        }
    }

    private var animationSteps: [AnimationStep] {
        [
            AnimationStep(frame: 8, duration: 0.88),
            AnimationStep(frame: 4, duration: 0.16),
            AnimationStep(frame: 8, duration: 0.72),
            AnimationStep(frame: featuredFrame, duration: 0.62),
            AnimationStep(frame: 8, duration: 0.82),
            AnimationStep(frame: 5, duration: 0.28),
            AnimationStep(frame: 7, duration: 0.54),
            AnimationStep(frame: 5, duration: 0.28),
            AnimationStep(frame: 8, duration: 0.78),
            AnimationStep(frame: 4, duration: 0.16),
            AnimationStep(frame: 10, duration: 0.64),
            AnimationStep(frame: 4, duration: 0.18),
            AnimationStep(frame: 8, duration: 0.86),
            AnimationStep(frame: 6, duration: 0.48),
            AnimationStep(frame: 0, duration: 0.44),
            AnimationStep(frame: 8, duration: 0.92),
            AnimationStep(frame: 2, duration: 0.56),
            AnimationStep(frame: 8, duration: 1.02)
        ]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let frameIndex = frames.count >= 11
                ? animationFrame(at: elapsed)
                : (frames.isEmpty ? 0 : Int(elapsed / 0.42) % frames.count)
            let bobOffset = CGFloat(sin(elapsed * .pi * 2.0 / 2.4)) * 0.55

            Group {
                if frames.indices.contains(frameIndex) {
                    Image(nsImage: frames[frameIndex])
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                }
            }
            .offset(y: bobOffset + 1)
        }
        .onAppear(perform: loadFrames)
        .accessibilityHidden(true)
    }

    private func animationFrame(at elapsed: TimeInterval) -> Int {
        let steps = animationSteps
        let cycleDuration = steps.reduce(0) { $0 + $1.duration }
        guard cycleDuration > 0 else { return 8 }

        var phase = elapsed.truncatingRemainder(dividingBy: cycleDuration)
        for step in steps {
            if phase < step.duration {
                return step.frame
            }
            phase -= step.duration
        }
        return steps.last?.frame ?? 8
    }

    private func loadFrames() {
        frames = (0..<11).compactMap { index in
            guard let url = Bundle.main.url(
                forResource: String(format: "pixel-dog-%02d", index),
               withExtension: "png",
                subdirectory: "PixelDog"
            ) else {
                return nil
            }
            return NSImage(contentsOf: url)
        }
    }
}

struct PixelPandaCompanion: View {
    let mode: IslandContentMode
    @State private var frames: [NSImage] = []

    private struct AnimationStep {
        let frame: Int
        let duration: TimeInterval
    }

    private var featuredFrame: Int {
        switch mode {
        case .music: return 0
        case .system: return 3
        case .agent: return 2
        case .token: return 6
        }
    }

    private var animationSteps: [AnimationStep] {
        [
            AnimationStep(frame: 1, duration: 0.92),
            AnimationStep(frame: 4, duration: 0.16),
            AnimationStep(frame: 1, duration: 0.72),
            AnimationStep(frame: featuredFrame, duration: 0.68),
            AnimationStep(frame: 1, duration: 0.74),
            AnimationStep(frame: 4, duration: 0.18),
            AnimationStep(frame: 1, duration: 0.78),
            AnimationStep(frame: 5, duration: 0.28),
            AnimationStep(frame: 8, duration: 0.62),
            AnimationStep(frame: 5, duration: 0.28),
            AnimationStep(frame: 1, duration: 0.82),
            AnimationStep(frame: 4, duration: 0.18),
            AnimationStep(frame: 7, duration: 0.62),
            AnimationStep(frame: 4, duration: 0.18),
            AnimationStep(frame: 1, duration: 0.88),
            AnimationStep(frame: 6, duration: 0.52),
            AnimationStep(frame: 0, duration: 0.42),
            AnimationStep(frame: 1, duration: 1.04)
        ]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let frameIndex = animationFrame(at: elapsed)
            let bob = CGFloat(sin(elapsed * .pi * 2 / 2.6)) * 0.45

            Group {
                if frames.indices.contains(frameIndex) {
                    Image(nsImage: frames[frameIndex])
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color(red: 0.392, green: 0.678, blue: 0.941))
                }
            }
            .offset(y: bob + 1)
        }
        .onAppear(perform: loadFrames)
        .accessibilityHidden(true)
    }

    private func animationFrame(at elapsed: TimeInterval) -> Int {
        let steps = animationSteps
        let cycleDuration = steps.reduce(0) { $0 + $1.duration }
        guard cycleDuration > 0 else { return 1 }

        var phase = elapsed.truncatingRemainder(dividingBy: cycleDuration)
        for step in steps {
            if phase < step.duration {
                return step.frame
            }
            phase -= step.duration
        }
        return steps.last?.frame ?? 1
    }

    private func loadFrames() {
        frames = (0..<9).compactMap { index in
            guard let url = Bundle.main.url(
                forResource: String(format: "pixel-panda-%02d", index),
                withExtension: "png",
                subdirectory: "PixelPanda"
            ) else {
                return nil
            }
            return NSImage(contentsOf: url)
        }
    }
}

struct PixelCatCompanion: View {
    let mode: IslandContentMode
    @State private var frames: [NSImage] = []

    private struct AnimationStep {
        let frame: Int
        let duration: TimeInterval
    }

    private var featuredFrame: Int {
        switch mode {
        case .music: return 9
        case .system: return 2
        case .agent: return 5
        case .token: return 0
        }
    }

    private var animationSteps: [AnimationStep] {
        [
            AnimationStep(frame: 1, duration: 0.78),
            AnimationStep(frame: 3, duration: 0.16),
            AnimationStep(frame: 6, duration: 0.16),
            AnimationStep(frame: 8, duration: 0.72),
            AnimationStep(frame: 7, duration: 0.13),
            AnimationStep(frame: 4, duration: 0.24),
            AnimationStep(frame: 7, duration: 0.13),
            AnimationStep(frame: 8, duration: 0.68),
            AnimationStep(frame: 6, duration: 0.16),
            AnimationStep(frame: featuredFrame, duration: 0.56),
            AnimationStep(frame: 6, duration: 0.16),
            AnimationStep(frame: 3, duration: 0.16),
            AnimationStep(frame: 0, duration: 0.42),
            AnimationStep(frame: 4, duration: 0.3),
            AnimationStep(frame: 1, duration: 0.86),
            AnimationStep(frame: 7, duration: 0.14),
            AnimationStep(frame: 10, duration: 0.58),
            AnimationStep(frame: 7, duration: 0.16),
            AnimationStep(frame: 1, duration: 1.08)
        ]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let frameIndex = animationFrame(at: elapsed)
            let bob = CGFloat(sin(elapsed * .pi * 2 / 2.2)) * 0.65

            Group {
                if frames.indices.contains(frameIndex) {
                    Image(nsImage: frames[frameIndex])
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    PixelCatSprite(frame: 0, mode: mode)
                }
            }
            .offset(y: bob + 1)
        }
        .onAppear(perform: loadFrames)
        .accessibilityHidden(true)
    }

    private func animationFrame(at elapsed: TimeInterval) -> Int {
        let steps = animationSteps
        let cycleDuration = steps.reduce(0) { $0 + $1.duration }
        guard cycleDuration > 0 else { return 1 }

        var phase = elapsed.truncatingRemainder(dividingBy: cycleDuration)
        for step in steps {
            if phase < step.duration {
                return step.frame
            }
            phase -= step.duration
        }
        return steps.last?.frame ?? 1
    }

    private func loadFrames() {
        frames = (0..<11).compactMap { index in
            guard let url = Bundle.main.url(
                forResource: String(format: "pixel-cat-%02d", index),
                withExtension: "png",
                subdirectory: "PixelCat"
            ) else {
                return nil
            }
            return NSImage(contentsOf: url)
        }
    }
}

struct PixelCatSprite: View {
    let frame: Int
    let mode: IslandContentMode

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let pixel = max(1, floor(min(size.width, size.height) / 20))
            let width = pixel * 20
            let height = pixel * 20
            let origin = CGPoint(
                x: floor((size.width - width) / 2),
                y: floor((size.height - height) / 2)
            )
            let outline = Color(red: 0.23, green: 0.16, blue: 0.15)
            let fur = Color(red: 1.0, green: 0.714, blue: 0.38)
            let furLight = Color(red: 1.0, green: 0.94, blue: 0.86)
            let blush = Color(red: 1.0, green: 0.553, blue: 0.427)
            let eye = Color(red: 0.12, green: 0.09, blue: 0.09)
            let collar: Color = mode == .system
                ? Color(red: 0.45, green: 0.78, blue: 1.0)
                : blush

            func block(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: Color) {
                let rect = CGRect(
                    x: origin.x + CGFloat(x) * pixel,
                    y: origin.y + CGFloat(y) * pixel,
                    width: CGFloat(w) * pixel,
                    height: CGFloat(h) * pixel
                )
                context.fill(Path(rect), with: .color(color))
            }

            block(4, 18, 12, 1, outline.opacity(0.22))

            block(15, 12, 3, 5, outline)
            block(16, 11, 2, 4, outline)
            block(15, 12, 2, 4, fur)

            block(5, 11, 10, 7, outline)
            block(6, 11, 8, 7, fur)
            block(7, 12, 6, 5, furLight)
            block(4, 17, 5, 2, outline)
            block(11, 17, 5, 2, outline)
            block(5, 17, 3, 1, furLight)
            block(12, 17, 3, 1, furLight)

            block(3, 2, 5, 5, outline)
            block(12, 2, 5, 5, outline)
            block(4, 3, 3, 3, fur)
            block(13, 3, 3, 3, fur)
            block(5, 4, 1, 2, blush)
            block(14, 4, 1, 2, blush)

            block(3, 5, 14, 8, outline)
            block(4, 4, 12, 10, outline)
            block(4, 6, 12, 6, fur)
            block(5, 5, 10, 8, fur)
            block(6, 9, 8, 4, furLight)

            if frame == 2 {
                block(6, 8, 3, 1, eye)
                block(12, 8, 2, 1, eye)
            } else if frame == 3 {
                block(6, 8, 2, 2, eye)
                block(12, 8, 3, 1, eye)
            } else {
                block(6, 7, 2, 3, eye)
                block(12, 7, 2, 3, eye)
                block(7, 7, 1, 1, Color.white.opacity(0.9))
                block(13, 7, 1, 1, Color.white.opacity(0.9))
            }

            block(9, 9, 2, 1, outline)
            block(9, 10, 1, 1, outline)
            block(11, 10, 1, 1, outline)
            block(9, 11, 3, 1, blush)
            block(5, 10, 1, 1, blush.opacity(0.85))
            block(14, 10, 1, 1, blush.opacity(0.85))
            block(6, 13, 8, 1, collar)

            if frame == 1 || mode == .agent {
                block(2, 10, 4, 3, outline)
                block(2, 9, 2, 3, outline)
                block(3, 9, 2, 3, furLight)
            }
        }
    }
}

struct PixelDesktopPetView: View {
    @ObservedObject var model: MusicPlayerModel
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void

    var body: some View {
        let mood = model.desktopPetMood

        ZStack {
            Group {
                if model.theme == .horizon {
                    PixelPandaCompanion(mode: model.activeMode)
                } else if model.theme.isNook {
                    PixelCatCompanion(mode: model.activeMode)
                } else {
                    PixelDogCompanion(mode: model.activeMode)
                }
            }
            .modifier(DesktopPetMoodMotion(mood: mood))

            DesktopPetEmotionOverlay(mood: mood, theme: model.theme)
        }
        .frame(width: 88, height: 88)
        // Hard-kill pet paint during Space settle / when theme hides companions.
        .opacity(model.theme.showsDesktopPet && !model.suppressTransientIslandSurfaces ? 1 : 0)
        .allowsHitTesting(model.theme.showsDesktopPet && !model.suppressTransientIslandSurfaces)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.55)
                .onEnded { _ in onLongPress() }
        )
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in
                    onDragChanged()
                }
                .onEnded { _ in
                    onDragEnded()
                }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 5)
        .padding(.bottom, 3)
        .help(LumaBarL10n.petHelp)
        .accessibilityLabel(model.theme.desktopPetName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(LumaBarL10n.petTalk), onTap)
    }
}

struct DesktopPetMoodMotion: ViewModifier {
    let mood: DesktopPetMood

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let workingShift = CGFloat(sin(elapsed * 18)) * 1.2
            let heatShake = CGFloat(sin(elapsed * 36)) * 0.9
            let stretchScale = 1 + CGFloat(sin(elapsed * 4)) * 0.035
            let voiceLift = CGFloat(sin(elapsed * 9)) * 1.1

            content
                .offset(
                    x: mood == .working ? workingShift : (mood == .hot ? heatShake : 0),
                    y: mood == .voice ? voiceLift : 0
                )
                .scaleEffect(
                    x: mood == .stretch ? 1.08 : 1,
                    y: mood == .stretch ? max(0.94, stretchScale) : 1,
                    anchor: .bottom
                )
        }
    }
}

struct DesktopPetEmotionOverlay: View {
    let mood: DesktopPetMood
    let theme: IslandTheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: mood == .idle)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let pixel = max(2, floor(min(size.width, size.height) / 32))
                let phase = Int(elapsed * 8) % 8
                let accent = theme.primaryAccent
                let hot = Color(red: 1.0, green: 0.28, blue: 0.18)
                let water = Color(red: 0.33, green: 0.78, blue: 1.0)
                let work = Color(red: 1.0, green: 0.72, blue: 0.22)

                func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color, opacity: Double = 1) {
                    let rect = CGRect(
                        x: x * pixel,
                        y: y * pixel,
                        width: w * pixel,
                        height: h * pixel
                    )
                    context.fill(Path(rect), with: .color(color.opacity(opacity)))
                }

                switch mood {
                case .idle:
                    break
                case .hot:
                    block(21, 2, 2, 5, hot, opacity: 0.9)
                    block(24, 4, 2, 4, hot.opacity(0.85))
                    block(27, 1, 1.5, 6, hot.opacity(0.72))
                    block(18, 6 + CGFloat(phase % 3), 2, 2, water)
                    block(29, 8 + CGFloat((phase + 1) % 3), 2, 2, water.opacity(0.86))
                case .working:
                    block(8, 24, 17, 4, Color.black.opacity(0.58))
                    for index in 0..<6 {
                        block(9 + CGFloat(index * 3), 25, 1.6, 1.2, work.opacity(index == phase % 6 ? 1 : 0.45))
                    }
                    block(5 + CGFloat(phase % 5), 19, 5, 4, work.opacity(0.9))
                    block(6 + CGFloat(phase % 5), 18, 3, 1, Color.white.opacity(0.78))
                case .stretch:
                    block(4, 11, 6, 1.5, accent.opacity(0.82))
                    block(23, 11, 6, 1.5, accent.opacity(0.82))
                    block(25, 4, 2, 5, water.opacity(0.92))
                    block(24, 8, 4, 3, water.opacity(0.72))
                case .voice:
                    let pulse = CGFloat((elapsed * 1.4).truncatingRemainder(dividingBy: 1))
                    let radius = min(size.width, size.height) * (0.38 + pulse * 0.18)
                    let rect = CGRect(
                        x: (size.width - radius) / 2,
                        y: (size.height - radius) / 2,
                        width: radius,
                        height: radius
                    )
                    context.stroke(Path(ellipseIn: rect), with: .color(accent.opacity(Double(1 - pulse) * 0.46)), lineWidth: 2)
                    block(14, 3, 4, 7, accent.opacity(0.95))
                    block(13, 8, 6, 2, accent.opacity(0.95))
                    block(15, 10, 2, 4, accent.opacity(0.86))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct PixelCompanionSpeechBubble: View {
    let text: String
    let tailOnRight: Bool
    @Environment(\.islandTheme) private var theme

    private var tailAlignment: Alignment {
        tailOnRight ? .bottomTrailing : .bottomLeading
    }

    private var surface: Color {
        switch theme {
        case .horizon:
            return Color(red: 0.965, green: 0.985, blue: 1.0)
        case .nook:
            return Color(red: 1.0, green: 0.965, blue: 0.93)
        default:
            return Color(red: 0.047, green: 0.11, blue: 0.16)
        }
    }

    private var border: Color {
        switch theme {
        case .horizon, .nook:
            return theme.primaryAccent
        default:
            return Color(red: 1.0, green: 0.70, blue: 0.31)
        }
    }

    private var textColor: Color {
        theme.isLight ? theme.foreground(opacity: 0.94) : .white
    }

    var body: some View {
        ZStack(alignment: tailAlignment) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(surface.opacity(0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(border.opacity(0.92), lineWidth: 2)
                }
                .padding(.bottom, 10)

            Rectangle()
                .fill(surface)
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(45))
                .overlay {
                    Rectangle()
                        .stroke(border.opacity(0.92), lineWidth: 1.5)
                        .rotationEffect(.degrees(45))
                }
                .offset(x: tailOnRight ? -28 : 28, y: -3)

            Text(text)
                .font(theme.font(size: 14, weight: .bold))
                .foregroundStyle(textColor)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

