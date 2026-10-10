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

final class NativeMusicSeekBarView: NSView {
    var progress: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }

    var duration: TimeInterval = 0 {
        didSet {
            needsDisplay = true
        }
    }

    var theme = IslandTheme.void {
        didSet {
            needsDisplay = true
        }
    }

    var onPreview: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?
    /// Live playhead without SwiftUI publishes — keeps the knob moving while the island stays still.
    var liveProgressProvider: (() -> Double)?
    var allowsScrubbing = true {
        didSet {
            guard allowsScrubbing != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private(set) var isTrackingSeek = false
    private var liveProgressTimer: Timer?
    private var scrubPollTimer: Timer?
    private var localSeekMonitor: Any?
    private var globalSeekMonitor: Any?
    private var scrubGeneration = UUID()

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 18)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: allowsScrubbing && duration > 0 ? .pointingHand : .arrow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if isTrackingSeek {
                commitSeekTracking(atScreenLocation: NSEvent.mouseLocation)
            }
            stopLiveProgressTimer()
        } else {
            startLiveProgressTimerIfNeeded()
        }
    }

    fileprivate func startLiveProgressTimerIfNeeded() {
        guard liveProgressTimer == nil, window != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isTrackingSeek, let provider = self.liveProgressProvider else { return }
                let next = min(1, max(0, provider()))
                if abs(next - self.progress) > 0.002 {
                    self.progress = next
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveProgressTimer = timer
    }

    private func stopLiveProgressTimer() {
        liveProgressTimer?.invalidate()
        liveProgressTimer = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard allowsScrubbing, duration > 0, bounds.width > 1 else { return }
        // Return immediately and track via monitors + poll. A blocking nextEvent loop
        // on this nonactivating panel never sees dragged events, so drag felt like click-only.
        beginSeekTracking(at: screenPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingSeek else { return }
        applySeek(atScreenLocation: screenPoint(for: event), commit: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTrackingSeek else { return }
        commitSeekTracking(atScreenLocation: screenPoint(for: event))
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
    }

    private func beginSeekTracking(at screenPoint: NSPoint) {
        finishSeekTracking(commit: false)
        let generation = UUID()
        scrubGeneration = generation
        isTrackingSeek = true
        IslandPanelScrubbing.isActive = true
        applySeek(atScreenLocation: screenPoint, commit: false)

        let poll = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scrubGeneration == generation, self.isTrackingSeek else {
                    self?.scrubPollTimer?.invalidate()
                    self?.scrubPollTimer = nil
                    return
                }
                self.applySeek(atScreenLocation: NSEvent.mouseLocation, commit: false)
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        RunLoop.main.add(poll, forMode: .eventTracking)
        scrubPollTimer = poll

        localSeekMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, self.scrubGeneration == generation, self.isTrackingSeek else {
                return event
            }
            if event.type == .leftMouseUp {
                self.commitSeekTracking(atScreenLocation: NSEvent.mouseLocation)
                return nil
            }
            self.applySeek(atScreenLocation: NSEvent.mouseLocation, commit: false)
            return nil
        }

        globalSeekMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.scrubGeneration == generation, self.isTrackingSeek else { return }
                if event.type == .leftMouseUp {
                    self.commitSeekTracking(atScreenLocation: NSEvent.mouseLocation)
                } else {
                    self.applySeek(atScreenLocation: NSEvent.mouseLocation, commit: false)
                }
            }
        }
    }

    private func commitSeekTracking(atScreenLocation screenPoint: NSPoint) {
        guard isTrackingSeek else { return }
        applySeek(atScreenLocation: screenPoint, commit: true)
        finishSeekTracking(commit: false)
    }

    private func finishSeekTracking(commit: Bool) {
        scrubPollTimer?.invalidate()
        scrubPollTimer = nil
        if let localSeekMonitor {
            NSEvent.removeMonitor(localSeekMonitor)
            self.localSeekMonitor = nil
        }
        if let globalSeekMonitor {
            NSEvent.removeMonitor(globalSeekMonitor)
            self.globalSeekMonitor = nil
        }
        if commit {
            onCommit?(progress)
        }
        isTrackingSeek = false
        IslandPanelScrubbing.isActive = false
        needsDisplay = true
    }

    func applyExternalProgress(_ value: Double) {
        guard !isTrackingSeek else { return }
        progress = min(1, max(0, value))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if theme.isPixelStyled {
            drawPixelTrack()
        } else {
            drawBarTrack()
        }
    }

    private func drawPixelTrack() {
        let segmentCount = 32
        let gap: CGFloat = 2
        let segmentWidth = max(1, (bounds.width - gap * CGFloat(segmentCount - 1)) / CGFloat(segmentCount))
        let trackHeight: CGFloat = 7
        let trackY = (bounds.height - trackHeight) / 2
        let filledSegments = duration > 0
            ? Int(ceil(min(1, max(0, progress)) * Double(segmentCount)))
            : 0

        for index in 0..<segmentCount {
            let segmentRect = NSRect(
                x: CGFloat(index) * (segmentWidth + gap),
                y: trackY,
                width: segmentWidth,
                height: trackHeight
            )
            let color: NSColor
            if theme.isArcade {
                color = index < filledSegments
                    ? NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.31, alpha: 1.0)
                    : NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.30, alpha: 1.0)
            } else if theme.isNook {
                color = index < filledSegments
                    ? NSColor(calibratedRed: 1.0, green: 0.714, blue: 0.38, alpha: 1.0)
                    : NSColor(calibratedRed: 0.25, green: 0.18, blue: 0.17, alpha: 1.0)
            } else if theme.isForge {
                color = index < filledSegments
                    ? NSColor(calibratedRed: 0.843, green: 0.353, blue: 0.153, alpha: 1.0)
                    : NSColor(calibratedRed: 0.741, green: 0.706, blue: 0.616, alpha: 1.0)
            } else {
                color = index < filledSegments
                    ? NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.40, alpha: 1.0)
                    : NSColor(calibratedRed: 0.33, green: 0.96, blue: 0.78, alpha: 0.14)
            }
            color.setFill()
            NSBezierPath(rect: segmentRect).fill()
        }

        guard duration > 0, allowsScrubbing else { return }
        let markerWidth: CGFloat = 4
        let markerX = min(
            bounds.width - markerWidth,
            max(0, bounds.width * CGFloat(min(1, max(0, progress))) - markerWidth / 2)
        )
        let markerColor: NSColor
        if theme.isArcade {
            markerColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
        } else if theme.isNook {
            markerColor = NSColor(calibratedRed: 1.0, green: 0.553, blue: 0.427, alpha: 1.0)
        } else if theme.isForge {
            markerColor = NSColor(calibratedRed: 0.176, green: 0.439, blue: 0.286, alpha: 1.0)
        } else {
            markerColor = NSColor(calibratedRed: 0.49, green: 1.0, blue: 0.42, alpha: 1.0)
        }
        markerColor.setFill()
        NSBezierPath(
            rect: NSRect(x: markerX, y: trackY - 3, width: markerWidth, height: trackHeight + 6)
        ).fill()
    }

    private func drawBarTrack() {

        let trackHeight: CGFloat = 5
        let trackRect = bounds.insetBy(
            dx: 0,
            dy: max(0, (bounds.height - trackHeight) / 2)
        )

        let trackColor = theme.isLight
            ? NSColor(calibratedRed: 0.392, green: 0.678, blue: 0.941, alpha: 0.16)
            : NSColor.white.withAlphaComponent(0.11)
        trackColor.setFill()
        NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackHeight / 2,
            yRadius: trackHeight / 2
        ).fill()

        guard duration > 0 else { return }

        let effectiveProgress = min(1, max(0, progress))
        let filledWidth = max(trackHeight, trackRect.width * CGFloat(effectiveProgress))
        let filledRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: min(trackRect.width, filledWidth),
            height: trackRect.height
        )

        let progressColor = theme.isLight
            ? NSColor(calibratedRed: 0.235, green: 0.51, blue: 0.82, alpha: 1.0)
            : NSColor(calibratedRed: 1.0, green: 0.56, blue: 0.22, alpha: 1.0)
        progressColor.setFill()
        NSBezierPath(
            roundedRect: filledRect,
            xRadius: trackHeight / 2,
            yRadius: trackHeight / 2
        ).fill()

        guard allowsScrubbing else { return }

        let knobDiameter: CGFloat = 12
        let knobX = min(
            bounds.width - knobDiameter,
            max(0, trackRect.width * CGFloat(effectiveProgress) - knobDiameter / 2)
        )
        let knobRect = NSRect(
            x: knobX,
            y: (bounds.height - knobDiameter) / 2,
            width: knobDiameter,
            height: knobDiameter
        )

        (theme.isLight
            ? NSColor(calibratedRed: 0.235, green: 0.51, blue: 0.82, alpha: 0.24)
            : NSColor.black.withAlphaComponent(0.28)
        ).setFill()
        NSBezierPath(ovalIn: knobRect.offsetBy(dx: 0, dy: -1)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    private func applySeek(atScreenLocation screenPoint: NSPoint, commit: Bool) {
        let nextProgress = progress(atScreenLocation: screenPoint)
        if abs(nextProgress - progress) > 0.0005 || commit {
            progress = nextProgress
            // Immediate paint — waiting for the run loop makes the knob feel stuck.
            display()
        }
        // Draw locally while dragging. Publishing into SwiftUI mid-drag rebuilds the
        // representable and kills tracking on the non-key island window.
        if commit {
            onCommit?(nextProgress)
        }
    }

    private func progress(atScreenLocation screenPoint: NSPoint) -> Double {
        guard let window else { return progress }
        let inWindow = window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
        let x = convert(inWindow, from: nil).x
        return min(1, max(0, Double(x / max(1, bounds.width))))
    }
}

struct MusicSeekBar: NSViewRepresentable {
    let progress: Double
    let duration: TimeInterval
    /// ViewModel scrub lock — when true, ignore live `progress` from timers.
    let isSeeking: Bool
    let previewProgress: Double
    let allowsScrubbing: Bool
    let onPreview: (Double) -> Void
    let onCommit: (Double) -> Void
    var liveProgressProvider: (() -> Double)? = nil
    @Environment(\.islandTheme) private var theme

    func makeNSView(context: Context) -> NativeMusicSeekBarView {
        NativeMusicSeekBarView(frame: .zero)
    }

    func updateNSView(_ view: NativeMusicSeekBarView, context: Context) {
        view.theme = theme
        view.allowsScrubbing = allowsScrubbing
        view.duration = duration
        view.liveProgressProvider = liveProgressProvider
        view.onPreview = { value in
            onPreview(value)
        }
        view.onCommit = { value in
            onCommit(value)
        }
        view.alphaValue = duration > 0 ? 1 : 0.38
        // Never push SwiftUI progress into a live scrub — that snaps the knob back.
        if view.isTrackingSeek {
            return
        }
        let displayProgress = isSeeking ? previewProgress : progress
        view.applyExternalProgress(displayProgress)
        view.startLiveProgressTimerIfNeeded()
    }
}

/// Volume scrubber for the non-key island — SwiftUI `Slider`/`NSSlider` cannot finish a
/// mouse-tracking loop here (events are dropped on purpose to avoid a CPU spin).
final class NativeIslandVolumeSliderView: NSView {
    var value: Double = 0 {
        didSet { needsDisplay = true }
    }

    var theme = IslandTheme.void {
        didSet { needsDisplay = true }
    }

    var onEditingChanged: ((Bool) -> Void)?
    var onValueChanged: ((Double) -> Void)?

    private(set) var isTracking = false
    private var scrubPollTimer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var scrubGeneration = UUID()

    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 18)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isTracking {
            endTracking(commit: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard bounds.width > 1 else { return }
        beginTracking(at: screenPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        applyValue(atScreenLocation: screenPoint(for: event), notify: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        applyValue(atScreenLocation: screenPoint(for: event), notify: true)
        endTracking(commit: true)
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
    }

    private func beginTracking(at screenPoint: NSPoint) {
        endTracking(commit: false)
        let generation = UUID()
        scrubGeneration = generation
        isTracking = true
        IslandPanelScrubbing.isActive = true
        onEditingChanged?(true)
        applyValue(atScreenLocation: screenPoint, notify: true)

        let poll = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scrubGeneration == generation, self.isTracking else {
                    self?.scrubPollTimer?.invalidate()
                    self?.scrubPollTimer = nil
                    return
                }
                self.applyValue(atScreenLocation: NSEvent.mouseLocation, notify: true)
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        RunLoop.main.add(poll, forMode: .eventTracking)
        scrubPollTimer = poll

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, self.scrubGeneration == generation, self.isTracking else {
                return event
            }
            if event.type == .leftMouseUp {
                self.applyValue(atScreenLocation: NSEvent.mouseLocation, notify: true)
                self.endTracking(commit: true)
                return nil
            }
            self.applyValue(atScreenLocation: NSEvent.mouseLocation, notify: true)
            return nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.scrubGeneration == generation, self.isTracking else { return }
                if event.type == .leftMouseUp {
                    self.applyValue(atScreenLocation: NSEvent.mouseLocation, notify: true)
                    self.endTracking(commit: true)
                } else {
                    self.applyValue(atScreenLocation: NSEvent.mouseLocation, notify: true)
                }
            }
        }
    }

    private func endTracking(commit: Bool) {
        scrubPollTimer?.invalidate()
        scrubPollTimer = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        let wasTracking = isTracking
        isTracking = false
        IslandPanelScrubbing.isActive = false
        if wasTracking, commit {
            onEditingChanged?(false)
        }
        needsDisplay = true
    }

    private func applyValue(atScreenLocation screenPoint: NSPoint, notify: Bool) {
        guard let window else { return }
        let inWindow = window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
        let x = convert(inWindow, from: nil).x
        let next = min(1, max(0, Double(x / max(1, bounds.width))))
        if abs(next - value) > 0.0005 {
            value = next
            display()
            if notify {
                onValueChanged?(next)
            }
        }
    }

    func applyExternalValue(_ next: Double) {
        guard !isTracking else { return }
        value = min(1, max(0, next))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let trackHeight: CGFloat = 4
        let trackRect = bounds.insetBy(dx: 0, dy: max(0, (bounds.height - trackHeight) / 2))
        let trackColor = theme.isLight
            ? NSColor(calibratedRed: 0.392, green: 0.678, blue: 0.941, alpha: 0.16)
            : NSColor.white.withAlphaComponent(0.14)
        trackColor.setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

        let filledWidth = max(trackHeight, trackRect.width * CGFloat(min(1, max(0, value))))
        let filledRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: min(trackRect.width, filledWidth),
            height: trackRect.height
        )
        let fillColor = theme.isLight
            ? NSColor(calibratedRed: 0.235, green: 0.51, blue: 0.82, alpha: 1.0)
            : NSColor.white.withAlphaComponent(0.82)
        fillColor.setFill()
        NSBezierPath(roundedRect: filledRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

        let knob: CGFloat = 11
        let knobX = min(
            bounds.width - knob,
            max(0, trackRect.width * CGFloat(min(1, max(0, value))) - knob / 2)
        )
        let knobRect = NSRect(
            x: knobX,
            y: (bounds.height - knob) / 2,
            width: knob,
            height: knob
        )
        NSColor.black.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: knobRect.offsetBy(dx: 0, dy: -1)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }
}

struct IslandVolumeSlider: NSViewRepresentable {
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    @Environment(\.islandTheme) private var theme

    func makeNSView(context: Context) -> NativeIslandVolumeSliderView {
        NativeIslandVolumeSliderView(frame: .zero)
    }

    func updateNSView(_ view: NativeIslandVolumeSliderView, context: Context) {
        view.theme = theme
        view.onEditingChanged = onEditingChanged
        view.onValueChanged = { next in
            value = next
        }
        view.applyExternalValue(value)
    }
}

