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
protocol IslandPanelActionHandling: AnyObject {
    func islandPanel(_ panel: IslandPanel, didTrigger action: IslandPanelAction)
}

final class IslandPanel: NSPanel {
    var immediateActionRect: NSRect?
    var immediateAction: IslandPanelAction?
    var immediateActions: [(rect: NSRect, action: IslandPanelAction)] = []
    weak var actionHandler: IslandPanelActionHandling?

    /// When true, the expanded Agent / settings surface can take keyboard focus for TextFields.
    /// Compact notch panels keep this false so the glass chrome never flips to the inactive gray path.
    var allowsKeyboardFocus = false

    /// Spaces-friendly chrome: join the active Space’s animation, never pin as a
    /// stationary / all-Spaces overlay that WindowServer can’t re-snapshot (black square).
    /// Do **not** use `.canJoinAllSpaces` or `.stationary` on the main island.
    static let preferredCollectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .transient,
        .fullScreenAuxiliary,
        .ignoresCycle
    ]

    /// Must be ≥ statusBar so the island can sit in the menu-bar / camera notch band.
    /// `mainMenu - 1` is clamped below the menu bar and looks like the island “dropped”.
    static var preferredLevel: NSWindow.Level {
        .statusBar
    }

    /// Key only when Agent typing (or similar) needs a first responder.
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }

    /// Never let WindowServer restore off-screen frame snapshots across Spaces (causes expand/pet flash).
    override var isRestorable: Bool {
        get { false }
        set { super.isRestorable = false }
    }

    /// Never allow AppKit to flip these panels opaque during drag / Space / edge crossing.
    override var isOpaque: Bool {
        get { false }
        set { super.isOpaque = false }
    }

    override var hasShadow: Bool {
        get { false }
        set { super.hasShadow = false }
    }

    override var backgroundColor: NSColor! {
        get { .clear }
        set { super.backgroundColor = .clear }
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: backingStoreType,
            defer: flag
        )
        isRestorable = false
        animationBehavior = .none
        viewsNeedDisplay = true
        lockTransparentRenderChrome(stripFallbacks: true)
    }

    override var contentView: NSView? {
        get { super.contentView }
        set {
            super.contentView = newValue
            lockTransparentRenderChrome(stripFallbacks: true)
        }
    }

    /// Hard lock — re-applied whenever AppKit tries to mutate chrome during Spaces / drag.
    /// Reentrancy-guarded: strip/display must never call back into this during a lock pass.
    private var isLockingTransparentChrome = false

    func lockTransparentRenderChrome(stripFallbacks: Bool = false) {
        guard !isLockingTransparentChrome else { return }
        isLockingTransparentChrome = true
        defer { isLockingTransparentChrome = false }

        if isOpaque { super.isOpaque = false }
        if backgroundColor != .clear { super.backgroundColor = .clear }
        if hasShadow { super.hasShadow = false }
        if isRestorable { super.isRestorable = false }
        if hidesOnDeactivate { hidesOnDeactivate = false }
        if animationBehavior != .none { animationBehavior = .none }
        if abs(alphaValue - 1) > 0.001 { super.alphaValue = 1 }
        if !isExcludedFromWindowsMenu { isExcludedFromWindowsMenu = true }
        // Agent typing needs an activatable key window. Keep `.nonactivatingPanel` only for
        // compact notch chrome so hover-expand never steals focus from the frontmost app.
        let desiredMask: NSWindow.StyleMask = allowsKeyboardFocus
            ? [.borderless, .fullSizeContentView]
            : [.borderless, .fullSizeContentView, .nonactivatingPanel]
        if styleMask != desiredMask {
            styleMask = desiredMask
        }
        if allowsKeyboardFocus {
            if becomesKeyOnlyIfNeeded { becomesKeyOnlyIfNeeded = false }
        } else if !becomesKeyOnlyIfNeeded {
            becomesKeyOnlyIfNeeded = true
        }
        let desiredBehavior = Self.preferredCollectionBehavior
        if collectionBehavior != desiredBehavior {
            collectionBehavior = desiredBehavior
        }
        if #available(macOS 15.0, *) {
            if responds(to: Selector(("setAllowsAutomaticWindowTiling:"))) {
                setValue(false, forKey: "allowsAutomaticWindowTiling")
            }
        }
        if tabbingMode != .disallowed { tabbingMode = .disallowed }
        if level != Self.preferredLevel {
            level = Self.preferredLevel
        }
        installLayerBackedClearContent()
        // Full tree strip is expensive and was spinning the main thread when called
        // from the 5Hz visibility timer via orderFrontRegardless — only on attach.
        if stripFallbacks {
            stripAppKitGrayFallbackViews()
        }
    }

    /// Force layer-backed clear content so WindowServer never composites an opaque window plate.
    private func installLayerBackedClearContent() {
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.isOpaque = false
        contentView.layer?.masksToBounds = false
        if let themeFrame = contentView.superview {
            themeFrame.wantsLayer = true
            themeFrame.layer?.backgroundColor = NSColor.clear.cgColor
            themeFrame.layer?.isOpaque = false
        }
    }

    /// Remove / neutralize AppKit views that paint the inactive gray mask.
    func stripAppKitGrayFallbackViews() {
        guard let root = contentView?.superview ?? contentView else { return }
        Self.stripGrayFallback(in: root)
        installLayerBackedClearContent()
    }

    private static func stripGrayFallback(in view: NSView) {
        let className = NSStringFromClass(type(of: view))
        // Known AppKit chrome that paints the inactive gray plate behind borderless panels.
        let isFallbackMask =
            className.contains("NSTitlebarView")
            || className.contains("NSTitlebarContainerView")
            || className.contains("NSWindowBackground")
            || className.hasSuffix("WindowBackgroundView")
        if isFallbackMask {
            view.isHidden = true
            view.alphaValue = 0
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.isOpaque = false
        }

        // Kill leftover system material views — never let AppKit gray-composite them.
        // Aura glass is intentional behind-window material; keep it alive and forced active.
        if let aura = view as? AuraGlassEffectView {
            aura.isHidden = false
            aura.alphaValue = 1
            aura.lockActiveGlass()
        } else if view is NSVisualEffectView {
            view.isHidden = true
            view.alphaValue = 0
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.isOpaque = false
        }

        // Do not rewrite every SwiftUI subview layer — that thrashs layout on the visibility timer.
        for child in view.subviews {
            stripGrayFallback(in: child)
        }
    }

    override func orderFront(_ sender: Any?) {
        lockTransparentRenderChrome()
        super.orderFront(sender)
    }

    override func orderFrontRegardless() {
        lockTransparentRenderChrome()
        super.orderFrontRegardless()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == UInt16(kVK_Escape)
        {
            actionHandler?.islandPanel(self, didTrigger: .collapseExpanded)
            return
        }

        if event.type == .leftMouseDown {
            for item in immediateActions where item.rect.contains(event.locationInWindow) {
                actionHandler?.islandPanel(self, didTrigger: item.action)
                return
            }

            if
                let immediateActionRect,
                immediateActionRect.contains(event.locationInWindow),
                let immediateAction
            {
                actionHandler?.islandPanel(self, didTrigger: immediateAction)
                return
            }

            // Keep chrome locked; when keyboard focus is allowed, still pass the click through
            // so NSTextField / SecureField can become first responder.
            lockTransparentRenderChrome()

            // Non-key island windows never complete AppKit's NSSlider `nextEvent` loop
            // (mouseUp never arrives), which pegs a CPU core. Drop leftover system sliders
            // only — volume uses NativeIslandVolumeSliderView which manages its own scrub.
            // Do **not** drop NSScroller: SwiftUI ScrollView keeps an invisible scroller over
            // the track list, so dropping those hits made song rows untappable.
            if !allowsKeyboardFocus,
               let hit = contentView?.hitTest(event.locationInWindow),
               Self.usesAppKitMouseTrackingLoop(hit)
            {
                return
            }
        }

        super.sendEvent(event)
    }

    /// AppKit controls that wait on `nextEvent` until mouseUp. That wait never ends here.
    /// NSScroller and our custom scrubbers are intentionally excluded — see `sendEvent`.
    private static func usesAppKitMouseTrackingLoop(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let view = current {
            if view is NativeMusicSeekBarView || view is NativeIslandVolumeSliderView {
                return false
            }
            if view is NSSlider || view is NSStepper {
                return true
            }
            current = view.superview
        }
        return false
    }

    /// Last-resort cap: if some control still starts a tracking loop, do not wait forever.
    /// Custom seek/volume scrubbers set `IslandPanelScrubbing.isActive` and must not be capped.
    override func nextEvent(
        matching mask: NSEvent.EventTypeMask,
        until expiration: Date?,
        inMode mode: RunLoop.Mode,
        dequeue: Bool
    ) -> NSEvent? {
        if IslandPanelScrubbing.isActive {
            return super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue)
        }
        guard !allowsKeyboardFocus,
              mask.contains(.leftMouseUp) || mask.contains(.leftMouseDragged)
        else {
            return super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue)
        }

        let capped = Date().addingTimeInterval(0.05)
        let until = expiration.map { min($0, capped) } ?? capped
        return super.nextEvent(
            matching: mask,
            until: until,
            inMode: .eventTracking,
            dequeue: dequeue
        )
    }
}

/// Shared flag so IslandPanel does not truncate mouse tracking for custom scrubbers.
enum IslandPanelScrubbing {
    // Touched only on the main thread from AppKit mouse handlers.
    nonisolated(unsafe) static var isActive = false
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var isOpaque: Bool { false }

    override var allowsVibrancy: Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        // Keep hover hit-testing alive after expand/collapse frame changes.
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeAlways,
            .inVisibleRect,
            .enabledDuringMouseDrag
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }
}

final class GlobalHotKey: @unchecked Sendable {
    private let hotKeyID: EventHotKeyID
    private let action: @MainActor @Sendable () -> Void
    private var eventHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private(set) var registrationStatus: OSStatus = noErr

    init(
        signature: OSType,
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        self.hotKeyID = EventHotKeyID(signature: signature, id: id)
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { nextHandler, event, userData in
                guard let event, let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                var receivedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard status == noErr,
                      receivedID.signature == hotKey.hotKeyID.signature,
                      receivedID.id == hotKey.hotKeyID.id
                else {
                    return CallNextEventHandler(nextHandler, event)
                }

                let action = hotKey.action
                Task { @MainActor in
                    action()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )

        registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &eventHotKeyRef
        )
    }

    deinit {
        if let eventHotKeyRef {
            UnregisterEventHotKey(eventHotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    static func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.prefix(4).reduce(OSType(0)) { result, byte in
            (result << 8) + OSType(byte)
        }
    }
}

/// Posted by AppDelegate around Space transitions. `userInfo["visible"]` is Bool;
/// optional `userInfo["isDark"]` picks cover color.
extension Notification.Name {
    static let lumaBarSpaceTransitionGlassCover = Notification.Name(
        "com.lumabar.app.spaceTransitionGlassCover"
    )
}

/// Hardcoded layer fill — no NSVisualEffectView / system materials (those gray out on unfocus).
/// Non-Aura themes keep this path. Aura uses `AuraGlassBackdrop` instead.
struct VisualEffectBackground: NSViewRepresentable {
    /// Legacy unused — call sites still pass material/blending; ignored.
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized: Bool = true
    var appearanceName: NSAppearance.Name? = nil
    var cornerRadius: CGFloat = 0
    /// Fixed tint that never changes with focus, Spaces, or inactive state.
    var fillColor: NSColor = NSColor.black.withAlphaComponent(0.2)

    func makeNSView(context: Context) -> LockedClearBackgroundView {
        let view = LockedClearBackgroundView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: LockedClearBackgroundView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: LockedClearBackgroundView) {
        view.cornerRadius = cornerRadius
        view.fillColor = fillColor
        view.lockFixedLayer()
        _ = material
        _ = blendingMode
        _ = isEmphasized
        _ = appearanceName
    }
}

/// Aura-only: real behind-window glass that mirrors wallpaper / windows underneath.
/// Forces `.active` so non-key island panels do not milk into inactive gray.
struct AuraGlassBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat = 16
    /// Flat top + rounded bottom corners (compact bar stadium) instead of a uniform
    /// rounded rect. Implemented as a CAShapeLayer mask so the blur stays live.
    var flatTop: Bool = false
    /// Ultra-thin see-through glass (user preference: highly transparent Aura).
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> AuraGlassEffectView {
        let view = AuraGlassEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: AuraGlassEffectView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: AuraGlassEffectView) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.cornerRadius = cornerRadius
        view.flatTop = flatTop
        view.lockActiveGlass()
    }
}

/// System material glass for Aura. Keeps Space-transition cover without falling back to solid gray fill.
final class AuraGlassEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat = 0 {
        didSet { lockActiveGlass() }
    }

    /// Compact bar silhouette: flat top, rounded bottom corners. Uses a CAShapeLayer mask —
    /// a SwiftUI clipShape around the effect view freezes the blur solid.
    var flatTop: Bool = false {
        didSet { lockActiveGlass() }
    }

    private let stadiumMask = CAShapeLayer()

    private func refreshStadiumMask() {
        guard flatTop else {
            stadiumMask.path = nil
            return
        }
        let rect = bounds
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = min(cornerRadius, rect.height / 2, rect.width / 2)
        // AppKit layers use a bottom-left origin unless the view is flipped. The flat edge
        // must sit at the visual top of the bar, so pick the edge by the view's flippedness.
        let flatY = isFlipped ? rect.minY : rect.maxY
        let roundY = isFlipped ? rect.maxY : rect.minY
        let curveSign: CGFloat = isFlipped ? -1 : 1
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: flatY))
        path.addLine(to: CGPoint(x: rect.maxX, y: flatY))
        path.addLine(to: CGPoint(x: rect.maxX, y: roundY + curveSign * radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: roundY),
            control: CGPoint(x: rect.maxX, y: roundY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: roundY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: roundY + curveSign * radius),
            control: CGPoint(x: rect.minX, y: roundY)
        )
        path.closeSubpath()
        stadiumMask.path = path
    }

    private let spaceTransitionCover: NSView = {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.isHidden = true
        view.autoresizingMask = [.width, .height]
        return view
    }()

    private nonisolated(unsafe) var spaceCoverObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        isEmphasized = true
        wantsLayer = true
        stadiumMask.fillColor = NSColor.black.cgColor
        lockActiveGlass()
        spaceTransitionCover.frame = bounds
        addSubview(spaceTransitionCover)

        spaceCoverObserver = NotificationCenter.default.addObserver(
            forName: .lumaBarSpaceTransitionGlassCover,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let visible = (notification.userInfo?["visible"] as? Bool) ?? false
            let isDark = (notification.userInfo?["isDark"] as? Bool)
            DispatchQueue.main.async {
                self?.setSpaceTransitionCoverVisible(visible, isDark: isDark)
            }
        }
    }

    deinit {
        if let spaceCoverObserver {
            NotificationCenter.default.removeObserver(spaceCoverObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lockActiveGlass()
    }

    override func layout() {
        super.layout()
        refreshStadiumMask()
        spaceTransitionCover.frame = bounds
        spaceTransitionCover.layer?.cornerRadius = cornerRadius
        spaceTransitionCover.layer?.cornerCurve = .continuous
        lockActiveGlass()
    }

    /// Keep vibrancy alive even when the island panel is non-key / inactive.
    func lockActiveGlass() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if state != .active { state = .active }
        if blendingMode != .behindWindow { blendingMode = .behindWindow }
        isEmphasized = true
        wantsLayer = true
        if let layer {
            refreshStadiumMask()
            if flatTop {
                layer.mask = stadiumMask
                layer.cornerRadius = 0
                layer.masksToBounds = false
            } else {
                layer.mask = nil
                layer.masksToBounds = cornerRadius > 0
                layer.cornerRadius = cornerRadius
            }
            layer.cornerCurve = .continuous
            layer.isOpaque = false
            // Never paint an opaque fill over the material.
            if layer.backgroundColor != nil {
                layer.backgroundColor = nil
            }
        }
        CATransaction.commit()
    }

    func setSpaceTransitionCoverVisible(_ visible: Bool, isDark: Bool? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spaceTransitionCover.layer?.cornerRadius = cornerRadius
        spaceTransitionCover.layer?.cornerCurve = .continuous
        spaceTransitionCover.layer?.backgroundColor = LockedClearBackgroundView.coverColorForAura(isDark: isDark).cgColor
        spaceTransitionCover.frame = bounds
        spaceTransitionCover.isHidden = !visible
        if visible {
            spaceTransitionCover.layer?.zPosition = 10_000
            addSubview(spaceTransitionCover)
        }
        CATransaction.commit()
    }
}

/// Plain layer-backed view with a fixed background color — never vibrancy / material.
final class LockedClearBackgroundView: NSView {
    var fillColor: NSColor = NSColor.black.withAlphaComponent(0.2)
    var cornerRadius: CGFloat = 0

    /// Flat cover while Spaces animate (solid paint only — not system blur).
    private let spaceTransitionCover: NSView = {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.isHidden = true
        view.autoresizingMask = [.width, .height]
        return view
    }()

    private nonisolated(unsafe) var spaceCoverObserver: NSObjectProtocol?

    override var allowsVibrancy: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        lockFixedLayer()
        spaceTransitionCover.frame = bounds
        addSubview(spaceTransitionCover)

        spaceCoverObserver = NotificationCenter.default.addObserver(
            forName: .lumaBarSpaceTransitionGlassCover,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let visible = (notification.userInfo?["visible"] as? Bool) ?? false
            let isDark = (notification.userInfo?["isDark"] as? Bool)
            DispatchQueue.main.async {
                self?.setSpaceTransitionCoverVisible(visible, isDark: isDark)
            }
        }
    }

    deinit {
        if let spaceCoverObserver {
            NotificationCenter.default.removeObserver(spaceCoverObserver)
        }
    }

    override func layout() {
        super.layout()
        spaceTransitionCover.frame = bounds
        spaceTransitionCover.layer?.cornerRadius = cornerRadius
        spaceTransitionCover.layer?.cornerCurve = .continuous
        lockFixedLayer()
    }

    /// Idempotent layer paint — never sets `needsDisplay` (that re-enters `updateLayer` forever).
    func lockFixedLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wantsLayer = true
        layerUsesCoreImageFilters = false
        if let layer {
            layer.backgroundColor = fillColor.cgColor
            layer.isOpaque = false
            layer.masksToBounds = cornerRadius > 0
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
        }
        CATransaction.commit()
    }

    func setSpaceTransitionCoverVisible(_ visible: Bool, isDark: Bool? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spaceTransitionCover.layer?.cornerRadius = cornerRadius
        spaceTransitionCover.layer?.cornerCurve = .continuous
        spaceTransitionCover.layer?.backgroundColor = Self.coverColor(isDark: isDark).cgColor
        spaceTransitionCover.frame = bounds
        spaceTransitionCover.isHidden = !visible
        if visible {
            spaceTransitionCover.layer?.zPosition = 10_000
            addSubview(spaceTransitionCover)
        }
        CATransaction.commit()
    }

    private static func coverColor(isDark: Bool?) -> NSColor {
        coverColorForAura(isDark: isDark)
    }

    /// Shared with Aura glass Space-transition cover.
    static func coverColorForAura(isDark: Bool?) -> NSColor {
        let dark: Bool
        if let isDark {
            dark = isDark
        } else {
            dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return dark
            ? NSColor(srgbRed: 0.165, green: 0.165, blue: 0.165, alpha: 1)
            : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Only lock this view's layer — do NOT call panel.lockTransparentRenderChrome()
        // here (that re-enters strip/display during window attach and spins the CPU).
        lockFixedLayer()
    }

    override func updateLayer() {
        // Apply fixed fill without marking needsDisplay again.
        if let layer {
            layer.backgroundColor = fillColor.cgColor
            layer.isOpaque = false
        }
        super.updateLayer()
    }
}

/// Shared chrome so island panels stay transparent while dragged across edges / Spaces.
@MainActor
func configureIslandWindowChrome(_ window: NSWindow, level: NSWindow.Level? = nil) {
    if let panel = window as? IslandPanel {
        panel.lockTransparentRenderChrome()
    } else {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.alphaValue = 1
        if let panel = window as? NSPanel {
            panel.styleMask = [.borderless, .fullSizeContentView, .nonactivatingPanel]
            panel.becomesKeyOnlyIfNeeded = true
        }
        window.collectionBehavior = IslandPanel.preferredCollectionBehavior
        if #available(macOS 15.0, *) {
            if window.responds(to: Selector(("setAllowsAutomaticWindowTiling:"))) {
                window.setValue(false, forKey: "allowsAutomaticWindowTiling")
            }
        }
        window.tabbingMode = .disallowed
    }
    if let level {
        window.level = level
    } else {
        window.level = IslandPanel.preferredLevel
    }
}
