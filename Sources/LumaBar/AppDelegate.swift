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
final class AppDelegate: NSObject, NSApplicationDelegate, IslandPanelActionHandling {
    private let model = MusicPlayerModel()
    private var leftWindow: IslandPanel?
    private var cameraWindow: IslandPanel?
    private var rightWindow: IslandPanel?
    private var expandedWindow: IslandPanel?
    private var desktopPetWindow: IslandPanel?
    private var desktopPetBubbleWindow: IslandPanel?
    private var fullScreenCompletionToastWindow: IslandPanel?
    private var clipboardTranslationTimer: Timer?
    private var lastTranslationPasteboardChangeCount = 0
    private var lastClipboardTranslationString = ""
    private var lastClipboardTranslationChangeAt = Date.distantPast
    private var statusItem: NSStatusItem?
    private let menuBuilder = LumaBarMenuBuilder()
    private var permissionWindow: NSWindow?
    private var permissionOnboardingModel: PermissionOnboardingModel?
    private var visibilityTimer: Timer?
    private var fullScreenRecheckWorkItems: [DispatchWorkItem] = []
    private var isHiddenForFullScreen = false
    private var fullScreenRestoreUntil = Date.distantPast
    private var spaceTransitionExpandedHideUntil = Date.distantPast
    private var isSpaceTransitionPending = false
    private var spaceTransitionOriginWasFullScreen = false
    private var globalMouseDownMonitor: Any?
    private var globalBarHoverMonitor: Any?
    private var localBarHoverMonitor: Any?
    private var pendingBarHoverPoint: NSPoint?
    private var barHoverEvaluationWorkItem: DispatchWorkItem?
    private var barHoverCollapseWorkItem: DispatchWorkItem?
    private var isExpandedByBarHover = false
    /// True while the expanded panel is fading in. Hover must not restart that fade.
    private var expandedPanelRevealInFlight = false
    private var globalSelectionMouseUpMonitor: Any?
    private var localEscapeKeyMonitor: Any?
    private var globalEscapeKeyMonitor: Any?
    private var globalSpaceGestureMonitor: Any?
    private var spaceSwipeHorizontalAccumulator: CGFloat = 0
    private var lastPreemptiveSpaceTransitionDate = Date.distantPast
    /// True while a trackpad Space swipe is in progress (including mid-desktop hover).
    private var isSpaceSwipeGestureActive = false
    private var spaceSwipeGestureEndWorkItem: DispatchWorkItem?
    private var preemptiveSpaceTransitionRestoreWorkItem: DispatchWorkItem?
    private var spaceTransitionWatchdogWorkItem: DispatchWorkItem?
    private var fullScreenHideWorkItem: DispatchWorkItem?
    private var shellPromptHotKeys: [GlobalHotKey] = []
    private var voiceWhisperHotKey: GlobalHotKey?
    private var mainPanelHotKey: GlobalHotKey?
    private var lastShellPromptHotKeyAt = Date.distantPast
    private var lastMainPanelHotKeyAt = Date.distantPast
    private var selectionMouseDownPoint: NSPoint?
    private var selectionMouseDownHeldOption = false
    private var selectionTranslationWorkItem: DispatchWorkItem?
    private var desktopPetBubbleDismissWorkItem: DispatchWorkItem?
    private var fullScreenCompletionToastDismissWorkItem: DispatchWorkItem?
    private var lastDesktopPetMessageIndex: Int?
    private var lastDesktopPetMessageTheme: IslandTheme?
    private var desktopPetDragStartOrigin: NSPoint?
    private var desktopPetDragStartMouseLocation: NSPoint?
    private let desktopPetOriginXDefaultsKey = "LumaBar.desktopPetOriginX"
    private let desktopPetOriginYDefaultsKey = "LumaBar.desktopPetOriginY"
    private var cancellables = Set<AnyCancellable>()
    private var preserveExpandedPanelForBundleID: String?
    private var preserveExpandedPanelUntil = Date.distantPast
    private var suppressExpandedPanelUntil = Date.distantPast
    private var pendingExpandedActivationWorkItem: DispatchWorkItem?
    private let fullScreenTransitionDuration: TimeInterval = 0.86

    private var compactPreferredLeftWidth: CGFloat {
        NotchMetrics.compactLeftWidth
    }

    private var compactPreferredRightWidth: CGFloat {
        NotchMetrics.compactRightWidth
    }

    private var expandedPanelSize: NSSize {
        if model.taskCompletionNotice != nil {
            return NotchMetrics.codexTokenExpandedSize
        }
        if model.isCodexTokenAutoExpanded, model.showsKiroCredits || model.showsCodexWeeklyQuota {
            return NotchMetrics.kiroTokenExpandedSize
        }
        if model.usesCompactExpandedOverlay {
            return NotchMetrics.codexTokenExpandedSize
        }
        switch model.activeMode {
        case .music, .system, .agent:
            return NotchMetrics.expandedSize
        case .token:
            return NotchMetrics.codexTokenExpandedSize
        }
    }

    private var persistentIslandWindowLevel: NSWindow.Level {
        IslandPanel.preferredLevel
    }

    private var islandWindowCollectionBehavior: NSWindow.CollectionBehavior {
        IslandPanel.preferredCollectionBehavior
    }

    private var desktopPetSize: NSSize {
        NSSize(width: 112, height: 108)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AdventureXPixelFont.registerIfNeeded()
        NSApp.setActivationPolicy(.regular)
        terminateDuplicateInstances()
        buildMenu()
        buildStatusItem()
        model.requestExpandedPanelPreservation = { [weak self] bundleIdentifier, duration in
            self?.preserveExpandedPanelForExternalActivation(bundleIdentifier: bundleIdentifier, duration: duration)
        }
        model.requestExpandedPanelDismissal = { [weak self] in
            self?.dismissExpandedPanelImmediately()
        }
        model.requestDesktopPetMessage = { [weak self] message in
            self?.showDesktopPetMessage(message)
        }
        model.requestTaskCompletionPresentation = { [weak self] in
            guard let self else { return false }
            if self.isFrontmostApplicationFullScreen() {
                self.showFullScreenCompletionToast()
                return true
            }
            self.showExpandedPanel(animated: true)
            self.refreshInteractiveHitRegions()
            return false
        }
        buildWindows()
        installOutsideClickMonitors()
        installBarHoverMonitors()
        if AppStoreDistribution.allowsSelectionTranslation {
            if AppStoreDistribution.readsSelectionDirectly {
                installSelectionTranslationMonitor()
            } else {
                installClipboardTranslationMonitor()
            }
        }
        installEscapeKeyMonitor()
        installSpaceTransitionMonitor()
        if AppStoreDistribution.allowsShellAutomation {
            installShellPromptHotKey()
        }
        installVoiceWhisperHotKey()
        installMainPanelHotKey()
        installApplicationContextObserver()
        beginLicensedSession()
        model.applyActiveApplication(NSWorkspace.shared.frontmostApplication)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            NSApp.unhideWithoutActivation()
            // Settle launch-time drift only when the layout actually changed. An
            // unconditional applyLayout here rebuilds every hosting view with identical
            // frames, which makes the freshly drawn bar flicker once before it settles.
            self.relayoutCompactIfMenuBarAvoidanceChanged()
        }
        let timer = Timer(
            timeInterval: 0.2,
            target: self,
            selector: #selector(refreshVisibility(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer

        model.$isExpanded
            .removeDuplicates()
            .sink { [weak self] isExpanded in
                guard let self else { return }
                if !isExpanded {
                    self.isExpandedByBarHover = false
                    self.barHoverCollapseWorkItem?.cancel()
                    self.barHoverCollapseWorkItem = nil
                    // Normal collapse must not leave Space paint suppress stuck on.
                    if !self.isSpaceTransitionPending {
                        self.model.suppressTransientIslandSurfaces = false
                    }
                }
                self.menuBuilder.updatePanelVisibility(isExpanded: isExpanded)
                // Space settle / suppress windows: snap visibility — never animate expand/collapse.
                let animated = !self.isSpaceTransitionPending
                    && Date() >= self.suppressExpandedPanelUntil
                self.updateExpandedPanelVisibility(isExpanded: isExpanded, animated: animated)
            }
            .store(in: &cancellables)

        model.$activeMode
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshInteractiveHitRegions()
                self?.relayoutExpandedPanelIfNeeded()
            }
            .store(in: &cancellables)

        model.$musicLibrarySource
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.relayoutExpandedPanelIfNeeded()
            }
            .store(in: &cancellables)

        model.$activeAppContext
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshInteractiveHitRegions()
            }
            .store(in: &cancellables)

        model.$theme
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] theme in
                self?.updateThemeMenuState(theme)
                DispatchQueue.main.async { [weak self] in
                    guard self?.model.theme == theme else { return }
                    self?.desktopPetBubbleDismissWorkItem?.cancel()
                    self?.desktopPetBubbleWindow?.orderOut(nil)
                    self?.applyLayout()
                }
            }
            .store(in: &cancellables)

        model.$showsKiroCreditsOverlay
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.model.isCodexTokenAutoExpanded else { return }
                self.applyLayout()
            }
            .store(in: &cancellables)

        model.$showsCodexWeeklyQuotaOverlay
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.model.isCodexTokenAutoExpanded else { return }
                self.applyLayout()
            }
            .store(in: &cancellables)

        model.$isSelectionTranslationEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isEnabled in
                self?.menuBuilder.updateSelectionTranslationState(isEnabled: isEnabled)
                if isEnabled {
                    AgentContextProvider.requestAccessibilityAccess()
                }
            }
            .store(in: &cancellables)

        if model.isSelectionTranslationEnabled {
            AgentContextProvider.requestAccessibilityAccess()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if CommandLine.arguments.contains("--test-cursor-completion")
            || CommandLine.arguments.contains("--test-task-completions")
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.model.presentMultiTaskCompletionDemo()
            }
        }
        if CommandLine.arguments.contains("--test-context-limit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.model.presentContextLimitTestReaction()
            }
        }
        if CommandLine.arguments.contains("--test-pet-praise") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showDesktopPetMessage("你今天也太厉害了，宠物认证！")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func terminateDuplicateInstances() {
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier

        for application in NSWorkspace.shared.runningApplications
        where application.processIdentifier != currentProcessIdentifier
            && application.bundleIdentifier == bundleIdentifier
        {
            application.terminate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        visibilityTimer?.invalidate()
        cancelFullScreenVisibilityRechecks()
        selectionTranslationWorkItem?.cancel()
        desktopPetBubbleDismissWorkItem?.cancel()
        fullScreenCompletionToastDismissWorkItem?.cancel()
        pendingExpandedActivationWorkItem?.cancel()
        barHoverCollapseWorkItem?.cancel()
        barHoverEvaluationWorkItem?.cancel()
        preemptiveSpaceTransitionRestoreWorkItem?.cancel()
        spaceTransitionWatchdogWorkItem?.cancel()
        fullScreenHideWorkItem?.cancel()
        removeOutsideClickMonitors()
        removeBarHoverMonitors()
        removeSelectionTranslationMonitor()
        removeClipboardTranslationMonitor()
        removeEscapeKeyMonitor()
        removeSpaceTransitionMonitor()
        removeApplicationContextObserver()
        shellPromptHotKeys.removeAll()
        voiceWhisperHotKey = nil
        mainPanelHotKey = nil
        HelpGuidePresenter.close()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    @objc private func screenParametersChanged() {
        MenuBarStatusItemProbe.invalidate()
        applyLayout()
    }

    private var islandScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard
                let leftArea = screen.auxiliaryTopLeftArea,
                let rightArea = screen.auxiliaryTopRightArea
            else {
                return false
            }
            return rightArea.minX > leftArea.maxX
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func installOutsideClickMonitors() {
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            let screenPoint = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self] in
                self?.collapseExpandedPanelIfClickOutside(screenPoint: screenPoint)
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private func installBarHoverMonitors() {
        // Global: other apps key. Local: our panels key. Also catch mouseDragged so
        // enter/exit still evaluate when the cursor is held down.
        let moveEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        globalBarHoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: moveEvents) { [weak self] _ in
            let screenPoint = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self] in
                self?.scheduleBarHoverEvaluation(screenPoint: screenPoint)
            }
        }
        localBarHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: moveEvents) { [weak self] event in
            self?.scheduleBarHoverEvaluation(screenPoint: NSEvent.mouseLocation)
            return event
        }
    }

    private func removeBarHoverMonitors() {
        if let globalBarHoverMonitor {
            NSEvent.removeMonitor(globalBarHoverMonitor)
            self.globalBarHoverMonitor = nil
        }
        if let localBarHoverMonitor {
            NSEvent.removeMonitor(localBarHoverMonitor)
            self.localBarHoverMonitor = nil
        }
        barHoverEvaluationWorkItem?.cancel()
        barHoverEvaluationWorkItem = nil
        pendingBarHoverPoint = nil
        barHoverCollapseWorkItem?.cancel()
        barHoverCollapseWorkItem = nil
        isExpandedByBarHover = false
    }

    private func scheduleBarHoverEvaluation(screenPoint: NSPoint) {
        pendingBarHoverPoint = screenPoint
        guard barHoverEvaluationWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let point = self.pendingBarHoverPoint
            self.pendingBarHoverPoint = nil
            self.barHoverEvaluationWorkItem = nil
            if let point {
                self.handleBarHover(screenPoint: point)
            }
        }
        barHoverEvaluationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func handleBarHover(screenPoint: NSPoint) {
        guard !isHiddenForFullScreen,
              !isSpaceTransitionPending,
              Date() >= suppressExpandedPanelUntil,
              Date() >= model.suppressAutomaticExpansionUntilDate,
              leftWindow?.isVisible == true,
              rightWindow?.isVisible == true
        else {
            return
        }

        // Compact trigger strips must always accept mouse for subsequent hovers.
        leftWindow?.ignoresMouseEvents = false
        rightWindow?.ignoresMouseEvents = false

        let layout = notchLayout()
        let compactFrame = layout.leftFrame
            .union(layout.cameraFrame)
            .union(layout.rightFrame)
        if compactFrame.contains(screenPoint) {
            barHoverCollapseWorkItem?.cancel()
            barHoverCollapseWorkItem = nil
            expandFromBarHoverIfNeeded()
            return
        }

        guard isExpandedByBarHover, model.isExpanded else { return }
        if let expandedWindow,
           expandedWindow.isVisible,
           expandedWindow.frame.insetBy(dx: -4, dy: -4).contains(screenPoint)
        {
            barHoverCollapseWorkItem?.cancel()
            barHoverCollapseWorkItem = nil
            return
        }

        guard barHoverCollapseWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isExpandedByBarHover, self.model.isExpanded else { return }
            self.isExpandedByBarHover = false
            self.model.collapse()
            self.barHoverCollapseWorkItem = nil
        }
        barHoverCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: workItem)
    }

    /// Hover expand must recover from "isExpanded=true but panel orderOut / opacity-0" deadlocks.
    private func expandFromBarHoverIfNeeded() {
        // User is on the bar — lift Space paint suppress so the next show isn't a no-op.
        if model.suppressTransientIslandSurfaces, !isSpaceTransitionPending {
            model.suppressTransientIslandSurfaces = false
        }

        isExpandedByBarHover = true
        if !model.isExpanded {
            model.isExpanded = true
            return
        }
        // A reveal starts at alpha 0. Hover used to see that and call show again,
        // which reset alpha to 0 and replayed the completion spring over and over.
        if expandedPanelRevealInFlight {
            return
        }

        if expandedWindow?.isVisible != true {
            showExpandedPanel(animated: true)
        } else if (expandedWindow?.alphaValue ?? 1) < 0.05 {
            showExpandedPanel(animated: false)
        }
    }

    private func installSelectionTranslationMonitor() {
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]
        globalSelectionMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            let eventType = event.type
            let eventLocation = event.locationInWindow
            let clickCount = event.clickCount
            let heldOption = event.modifierFlags.contains(.option)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if eventType == .leftMouseDown {
                    guard !self.shouldSuppressSelectionTranslationForFrontmostApplication() else {
                        self.selectionTranslationWorkItem?.cancel()
                        self.selectionTranslationWorkItem = nil
                        self.selectionMouseDownPoint = nil
                        self.selectionMouseDownHeldOption = false
                        return
                    }
                    self.selectionMouseDownPoint = eventLocation
                    self.selectionMouseDownHeldOption = heldOption
                    return
                }

                let mouseUpPoint = eventLocation
                let mouseDownPoint = self.selectionMouseDownPoint
                let mouseDownHeldOption = self.selectionMouseDownHeldOption
                self.selectionMouseDownPoint = nil
                self.selectionMouseDownHeldOption = false

                // Require ⌥ during select so normal select + ⌘C never fights translation.
                guard mouseDownHeldOption || heldOption else { return }

                let didDragSelection = mouseDownPoint.map {
                    hypot(mouseUpPoint.x - $0.x, mouseUpPoint.y - $0.y) >= 4
                } ?? false
                guard didDragSelection || clickCount >= 2 else { return }
                guard !self.shouldSuppressSelectionTranslationForFrontmostApplication() else { return }
                self.scheduleSelectionTranslation()
            }
        }
    }

    private func removeSelectionTranslationMonitor() {
        selectionTranslationWorkItem?.cancel()
        selectionTranslationWorkItem = nil
        selectionMouseDownPoint = nil
        selectionMouseDownHeldOption = false
        if let globalSelectionMouseUpMonitor {
            NSEvent.removeMonitor(globalSelectionMouseUpMonitor)
            self.globalSelectionMouseUpMonitor = nil
        }
    }

    /// Translate a second copy of the same text, for builds that cannot read a selection.
    ///
    /// Select-to-translate needs the frontmost app's Accessibility tree, which App Sandbox refuses.
    /// The pasteboard is the one piece of another app's text a sandboxed build may read. A single
    /// ⌘C must stay a normal copy; Option-Command-C is Cocoa's Copy Style. So translation arms
    /// only on a second copy of the same string inside a short window (DeepL-style double-copy).
    private func installClipboardTranslationMonitor() {
        lastTranslationPasteboardChangeCount = NSPasteboard.general.changeCount
        lastClipboardTranslationString = ""
        lastClipboardTranslationChangeAt = .distantPast
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.translateNewlyCopiedTextIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTranslationTimer = timer
    }

    private func removeClipboardTranslationMonitor() {
        clipboardTranslationTimer?.invalidate()
        clipboardTranslationTimer = nil
        lastClipboardTranslationString = ""
        lastClipboardTranslationChangeAt = .distantPast
    }

    private func translateNewlyCopiedTextIfNeeded() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastTranslationPasteboardChangeCount else { return }
        lastTranslationPasteboardChangeCount = changeCount

        guard model.isSelectionTranslationEnabled,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              // Our own copies — Agent actions, the copy button — must not translate themselves.
              frontmost.processIdentifier != NSRunningApplication.current.processIdentifier,
              !shouldSuppressSelectionTranslationForFrontmostApplication(),
              let copied = pasteboard.string(forType: .string)
        else {
            return
        }

        let normalized = copied
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let now = Date()
        let dt = now.timeIntervalSince(lastClipboardTranslationChangeAt)
        let sameText = normalized == lastClipboardTranslationString
        lastClipboardTranslationString = normalized
        lastClipboardTranslationChangeAt = now

        // One Copy often writes the pasteboard twice; collapse that into a single copy.
        if sameText, dt < 0.18 { return }
        // Second intentional copy of the same text → translate. A lone ⌘C never does.
        guard sameText, dt <= 1.1 else { return }

        model.translateCopiedText(copied)
    }

    private func installEscapeKeyMonitor() {
        localEscapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self,
                  event.keyCode == UInt16(kVK_Escape),
                  self.model.isExpanded
            else {
                return event
            }

            self.dismissExpandedPanelImmediately()
            return nil
        }

        globalEscapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.isExpanded else { return }
                self.dismissExpandedPanelImmediately()
            }
        }
    }

    private func removeEscapeKeyMonitor() {
        if let localEscapeKeyMonitor {
            NSEvent.removeMonitor(localEscapeKeyMonitor)
            self.localEscapeKeyMonitor = nil
        }
        if let globalEscapeKeyMonitor {
            NSEvent.removeMonitor(globalEscapeKeyMonitor)
            self.globalEscapeKeyMonitor = nil
        }
    }

    private func installSpaceTransitionMonitor() {
        let events: NSEvent.EventTypeMask = [.scrollWheel, .swipe, .keyDown]
        globalSpaceGestureMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            // Each accessor below throws for the wrong event type (scroll deltas on key presses,
            // keyCode on scrolls), and AppKit logs every one of those exceptions.
            let eventType = event.type
            var deltaX: CGFloat = 0
            var deltaY: CGFloat = 0
            var phase: NSEvent.Phase = []
            var keyCode: UInt16 = 0
            switch eventType {
            case .swipe:
                deltaX = event.deltaX
                deltaY = event.deltaY
            case .scrollWheel:
                deltaX = event.scrollingDeltaX
                deltaY = event.scrollingDeltaY
                phase = event.phase
            case .keyDown:
                keyCode = event.keyCode
            default:
                return
            }
            let modifiers = event.modifierFlags

            DispatchQueue.main.async { [weak self] in
                self?.handlePotentialSpaceTransition(
                    eventType: eventType,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    phase: phase,
                    keyCode: keyCode,
                    hasControlModifier: modifiers.contains(.control)
                )
            }
        }
    }

    private func removeSpaceTransitionMonitor() {
        if let globalSpaceGestureMonitor {
            NSEvent.removeMonitor(globalSpaceGestureMonitor)
            self.globalSpaceGestureMonitor = nil
        }
        preemptiveSpaceTransitionRestoreWorkItem?.cancel()
        preemptiveSpaceTransitionRestoreWorkItem = nil
        spaceTransitionWatchdogWorkItem?.cancel()
        spaceTransitionWatchdogWorkItem = nil
        spaceSwipeHorizontalAccumulator = 0
        isSpaceSwipeGestureActive = false
        spaceSwipeGestureEndWorkItem?.cancel()
        spaceSwipeGestureEndWorkItem = nil
    }

    private func handlePotentialSpaceTransition(
        eventType: NSEvent.EventType,
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: NSEvent.Phase,
        keyCode: UInt16,
        hasControlModifier: Bool
    ) {
        if eventType == .keyDown {
            let isArrow = keyCode == UInt16(kVK_LeftArrow) || keyCode == UInt16(kVK_RightArrow)
            if isArrow, hasControlModifier {
                beginPreemptiveSpaceTransition()
            }
            return
        }

        if eventType == .swipe {
            guard abs(deltaX) > abs(deltaY), abs(deltaX) > 0.1 else { return }
            isSpaceSwipeGestureActive = true
            beginPreemptiveSpaceTransition()
            return
        }

        guard eventType == .scrollWheel else { return }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            spaceSwipeHorizontalAccumulator = 0
        }

        let isHorizontal = abs(deltaX) > abs(deltaY) * 1.2
        if isHorizontal {
            spaceSwipeHorizontalAccumulator += deltaX
            let isEarlyHorizontalSwipe = (phase.contains(.began) || phase.contains(.mayBegin))
                && abs(deltaX) >= 2
            let isMidSwipeHold = phase.contains(.changed) && abs(spaceSwipeHorizontalAccumulator) >= 6
            if isEarlyHorizontalSwipe || isMidSwipeHold || abs(spaceSwipeHorizontalAccumulator) >= 12 {
                isSpaceSwipeGestureActive = true
                // Keep cover up for the entire finger-down / mid-desktop hover period.
                ensureSpaceTransitionGlassCoverVisible()
                beginPreemptiveSpaceTransition()
                if abs(spaceSwipeHorizontalAccumulator) >= 12 {
                    spaceSwipeHorizontalAccumulator = 0
                }
            }
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            spaceSwipeHorizontalAccumulator = 0
            markSpaceSwipeGestureEnded()
        }
    }

    private func ensureSpaceTransitionGlassCoverVisible() {
        // With moveToActiveSpace, WindowServer already composites the island into the
        // Space swipe. A solid cover is what read as the "black square" — do not paint it
        // for managed desktop transitions. Still refresh chrome so dirty regions redraw.
        for window in [cameraWindow, leftWindow, rightWindow, expandedWindow] {
            refreshVisualEffectViews(in: window?.contentView)
            if let window {
                configureIslandWindowChrome(window, level: persistentIslandWindowLevel)
                window.displayIfNeeded()
            }
        }
    }

    private func markSpaceSwipeGestureEnded() {
        isSpaceSwipeGestureActive = false
        spaceSwipeGestureEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // If Spaces never finished switching, lift the cover shortly after finger-up.
            if self.isSpaceTransitionPending {
                self.finishSpaceTransition()
            } else {
                self.scheduleHideSpaceTransitionGlassCover()
            }
        }
        spaceSwipeGestureEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func beginPreemptiveSpaceTransition() {
        let now = Date()
        // Already mid-transition (finger hovering between desktops): extend watchdog only.
        if isSpaceTransitionPending {
            hardHideExpandedAndPetForSpaceTransition()
            armSpaceTransitionWatchdog()
            return
        }
        guard now.timeIntervalSince(lastPreemptiveSpaceTransitionDate) >= 0.2 else {
            return
        }
        lastPreemptiveSpaceTransitionDate = now

        // Cancel pending hover expand so Space never flashes an expanded sheet.
        barHoverEvaluationWorkItem?.cancel()
        barHoverEvaluationWorkItem = nil
        pendingBarHoverPoint = nil
        barHoverCollapseWorkItem?.cancel()
        barHoverCollapseWorkItem = nil
        if isExpandedByBarHover, model.isExpanded {
            isExpandedByBarHover = false
            model.collapse()
        }
        isExpandedByBarHover = false
        suppressExpandedPanelUntil = now.addingTimeInterval(0.85)
        model.suppressAutomaticExpansion(for: 0.85)
        // Kill expanded + pet paint immediately — before WindowServer Spaces snapshot.
        hardHideExpandedAndPetForSpaceTransition()

        spaceTransitionOriginWasFullScreen = isHiddenForFullScreen
            || isFrontmostApplicationFullScreen()
        isSpaceTransitionPending = true
        armSpaceTransitionWatchdog()
        let transitionSettleDuration = fullScreenTransitionDuration + 0.15
        spaceTransitionExpandedHideUntil = now.addingTimeInterval(transitionSettleDuration)

        // Desktop ↔ desktop: keep compact island at alpha 1 so it rides the Space animation.
        // Full-screen exits still use the dedicated hide path elsewhere.
        if !spaceTransitionOriginWasFullScreen {
            keepIslandWindowsFullyOpaqueForSpaceTransition()
            for window in spaceChromeWindows(includeExpanded: false) {
                window.orderFrontRegardless()
                window.displayIfNeeded()
            }
        }

        preemptiveSpaceTransitionRestoreWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isSpaceTransitionPending else { return }
            // Finger still down mid-swipe — do not restore yet or glass flashes gray.
            if self.isSpaceSwipeGestureActive {
                self.armSpaceTransitionWatchdog()
                return
            }
            self.spaceTransitionExpandedHideUntil = .distantPast
            self.finishSpaceTransition()
        }
        preemptiveSpaceTransitionRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + transitionSettleDuration, execute: workItem)
    }

    private func armSpaceTransitionWatchdog() {
        spaceTransitionWatchdogWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isSpaceTransitionPending else { return }
            if self.isSpaceSwipeGestureActive {
                self.armSpaceTransitionWatchdog()
                return
            }
            self.spaceTransitionExpandedHideUntil = .distantPast
            self.finishSpaceTransition()
        }
        spaceTransitionWatchdogWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }

    private func installShellPromptHotKey() {
        let hotKey = GlobalHotKey(
            signature: GlobalHotKey.fourCharacterCode("LBSH"),
            id: 1,
            keyCode: UInt32(kVK_Return),
            modifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.handleShellPromptHotKey()
        }
        shellPromptHotKeys = [hotKey]

        if hotKey.registrationStatus != noErr {
            NSLog("luma bar failed to register Shell Prompt hotkey (Command-Shift-Return): \(hotKey.registrationStatus)")
        }
    }

    private func installVoiceWhisperHotKey() {
        voiceWhisperHotKey = GlobalHotKey(
            signature: GlobalHotKey.fourCharacterCode("LBVW"),
            id: 2,
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.toggleVoiceWhisper()
        }

        if voiceWhisperHotKey?.registrationStatus != noErr {
            NSLog("luma bar failed to register Voice Whisper hotkey: \(voiceWhisperHotKey?.registrationStatus ?? -1)")
        }
    }

    private func installMainPanelHotKey() {
        // ⌘⇧Space often collides with input-source / system bindings; ⌘⇧L is reserved for Luma.
        mainPanelHotKey = GlobalHotKey(
            signature: GlobalHotKey.fourCharacterCode("LBMP"),
            id: 4,
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.handleMainPanelHotKey()
        }

        if mainPanelHotKey?.registrationStatus != noErr {
            NSLog("luma bar failed to register main panel hotkey (Command-Shift-L): \(mainPanelHotKey?.registrationStatus ?? -1)")
        }
    }

    private func handleMainPanelHotKey() {
        let now = Date()
        guard now.timeIntervalSince(lastMainPanelHotKeyAt) >= 0.35 else { return }
        lastMainPanelHotKeyAt = now

        prepareExplicitExpandedPanelRequest()

        if model.isExpanded {
            collapseExpandedPanel()
            return
        }

        isExpandedByBarHover = false
        model.isExpanded = true
        refreshInteractiveHitRegions()

        DispatchQueue.main.async { [weak self] in
            guard let self, let expandedWindow = self.expandedWindow else { return }
            self.activateForUserInteraction(panel: expandedWindow)
        }
    }

    private func handleShellPromptHotKey() {
        let now = Date()
        guard now.timeIntervalSince(lastShellPromptHotKeyAt) >= 0.35 else { return }
        lastShellPromptHotKeyAt = now
        showAgentShellPrompt()
    }

    private func showAgentShellPrompt() {
        prepareExplicitExpandedPanelRequest()

        if model.isExpanded,
           model.activeMode == .agent,
           model.isAgentShellRequestMode
        {
            model.agentFocusRequestID = UUID()
            refreshInteractiveHitRegions()
            DispatchQueue.main.async { [weak self] in
                guard let self, let expandedWindow = self.expandedWindow else { return }
                self.activateForUserInteraction(panel: expandedWindow)
            }
            return
        }

        model.beginAgentShellRequest()
        model.isExpanded = true
        refreshInteractiveHitRegions()

        DispatchQueue.main.async { [weak self] in
            guard let self, let expandedWindow = self.expandedWindow else { return }
            self.activateForUserInteraction(panel: expandedWindow)
        }
    }

    private func toggleVoiceWhisper() {
        if model.isVoiceWhisperRecording {
            model.finishVoiceWhisper()
        } else {
            showVoiceWhisper()
        }
    }

    private func showVoiceWhisper() {
        prepareExplicitExpandedPanelRequest()

        model.beginVoiceWhisper()
        refreshInteractiveHitRegions()

        DispatchQueue.main.async { [weak self] in
            guard let self, let expandedWindow = self.expandedWindow else { return }
            self.activateForUserInteraction(panel: expandedWindow)
        }
    }

    private func prepareExplicitExpandedPanelRequest() {
        pendingExpandedActivationWorkItem?.cancel()
        pendingExpandedActivationWorkItem = nil
        suppressExpandedPanelUntil = .distantPast
    }

    private func scheduleSelectionTranslation() {
        selectionTranslationWorkItem?.cancel()
        guard !shouldSuppressSelectionTranslationForFrontmostApplication() else {
            selectionTranslationWorkItem = nil
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.shouldSuppressSelectionTranslationForFrontmostApplication()
            else {
                return
            }
            self.model.handleExternalSelectionMouseUp()
        }
        selectionTranslationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func shouldSuppressSelectionTranslationForFrontmostApplication() -> Bool {
        guard model.isProActive,
              model.isSelectionTranslationEnabled,
              let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != NSRunningApplication.current.processIdentifier
        else {
            return true
        }
        return AgentContextProvider.isWindowFullScreen(processID: application.processIdentifier)
    }

    private func collapseExpandedPanelIfClickOutside(screenPoint: NSPoint) {
        guard model.isExpanded else { return }
        guard !model.isCodexTokenAutoExpanded else { return }
        guard !isPointInsideIslandWindows(screenPoint) else { return }
        collapseExpandedPanel()
    }

    private func isPointInsideIslandWindows(_ point: NSPoint) -> Bool {
        [expandedWindow, leftWindow, rightWindow, cameraWindow].contains { window in
            guard let window, window.isVisible else { return false }
            return window.frame.insetBy(dx: -3, dy: -3).contains(point)
        }
    }

    private func installApplicationContextObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    private func removeApplicationContextObserver() {
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if isSpaceTransitionPending {
            model.applyActiveApplication(application)
            suppressSelectionTranslationIfFullScreen(application)
            return
        }

        let enteringFullScreen = application.map {
            AgentContextProvider.isWindowFullScreen(processID: $0.processIdentifier)
        } ?? false

        if enteringFullScreen {
            // Hide first so swipe/fullscreen activation never waits on panel collapse.
            hideIslandPanelsForFullScreen()
        }

        if !enteringFullScreen {
            collapseExpandedPanelIfNeeded(forActivatedApplication: application)
        }
        model.applyActiveApplication(application)
        suppressSelectionTranslationIfFullScreen(application)
        syncIslandVisibilityForFullScreen()
        scheduleFullScreenVisibilityRechecks()
    }

    @objc private func activeSpaceChanged(_ notification: Notification) {
        let application = NSWorkspace.shared.frontmostApplication
        suppressSelectionTranslationIfFullScreen(application)

        // When leaving a fullscreen space the island is already hidden. Restore
        // it directly on the destination desktop instead of playing another
        // exit animation and making it disappear twice.
        if !isFrontmostApplicationFullScreen() {
            preemptiveSpaceTransitionRestoreWorkItem?.cancel()
            preemptiveSpaceTransitionRestoreWorkItem = nil
            spaceTransitionWatchdogWorkItem?.cancel()
            spaceTransitionWatchdogWorkItem = nil
            model.applyActiveApplication(application)
            isSpaceTransitionPending = false
            spaceTransitionOriginWasFullScreen = false
            spaceTransitionExpandedHideUntil = .distantPast
            // Block hover / auto-expand flashes while Spaces finishes settling.
            suppressTransientExpansionAfterSpaceChange()
            // Instant restore — no alpha fade (avoids gray→transparent ramp after Spaces).
            restoreIslandVisibility(fadeIn: false)
            // Wait for the destination desktop to finish compositing, then lift the flat cover.
            scheduleHideSpaceTransitionGlassCover()
            scheduleFullScreenVisibilityRechecks()
            return
        }

        // Keep the preemptive exit animation alive instead of snapping alpha to zero.
        preemptiveSpaceTransitionRestoreWorkItem?.cancel()
        preemptiveSpaceTransitionRestoreWorkItem = nil
        if !isSpaceTransitionPending {
            spaceTransitionOriginWasFullScreen = isHiddenForFullScreen
            isSpaceTransitionPending = true
            hardHideExpandedAndPetForSpaceTransition()
            armSpaceTransitionWatchdog()
            if !spaceTransitionOriginWasFullScreen {
                keepIslandWindowsFullyOpaqueForSpaceTransition()
            }
        }
        spaceTransitionExpandedHideUntil = max(
            spaceTransitionExpandedHideUntil,
            Date().addingTimeInterval(fullScreenTransitionDuration + 0.08)
        )
        scheduleFullScreenVisibilityRechecks()
    }

    private func suppressSelectionTranslationIfFullScreen(_ application: NSRunningApplication?) {
        guard model.isSelectionTranslationEnabled,
              let application,
              AgentContextProvider.isWindowFullScreen(processID: application.processIdentifier)
        else {
            return
        }
        selectionTranslationWorkItem?.cancel()
        selectionTranslationWorkItem = nil
        selectionMouseDownPoint = nil
        selectionMouseDownHeldOption = false
        model.dismissSelectionTranslationForFullScreen()
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.model.applyActiveApplication(NSWorkspace.shared.frontmostApplication)
        }
    }

    private func collapseExpandedPanelIfNeeded(forActivatedApplication application: NSRunningApplication?) {
        guard model.isExpanded else { return }
        guard application?.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
        guard application?.activationPolicy != .prohibited else { return }
        if shouldPreserveExpandedPanel(forActivatedApplication: application) {
            return
        }
        collapseExpandedPanel()
    }

    private func preserveExpandedPanelForExternalActivation(bundleIdentifier: String, duration: TimeInterval) {
        preserveExpandedPanelForBundleID = bundleIdentifier
        preserveExpandedPanelUntil = Date().addingTimeInterval(duration)
    }

    private func shouldPreserveExpandedPanel(forActivatedApplication application: NSRunningApplication?) -> Bool {
        guard Date() < preserveExpandedPanelUntil else {
            preserveExpandedPanelForBundleID = nil
            return false
        }
        return application?.bundleIdentifier == preserveExpandedPanelForBundleID
    }

    @objc private func refreshVisibility(_ timer: Timer) {
        syncIslandVisibilityForFullScreen()
    }

    private func scheduleFullScreenVisibilityRechecks() {
        cancelFullScreenVisibilityRechecks()
        let delays: [TimeInterval] = [0.24, 0.48, 0.76, 1.08]
        fullScreenRecheckWorkItems = delays.map { delay in
            let workItem = DispatchWorkItem { [weak self] in
                self?.refreshActiveApplicationAndVisibility()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }

    private func cancelFullScreenVisibilityRechecks() {
        fullScreenRecheckWorkItems.forEach { $0.cancel() }
        fullScreenRecheckWorkItems.removeAll()
    }

    private func refreshActiveApplicationAndVisibility() {
        if isSpaceTransitionPending {
            guard Date() >= spaceTransitionExpandedHideUntil else { return }
            finishSpaceTransition()
            return
        }
        model.applyActiveApplication(NSWorkspace.shared.frontmostApplication)
        syncIslandVisibilityForFullScreen()
    }

    private func syncIslandVisibilityForFullScreen() {
        if isSpaceTransitionPending {
            return
        }
        if Date() < fullScreenRestoreUntil {
            return
        }

        let shouldHide = isFrontmostApplicationFullScreen()
        if shouldHide {
            hideIslandPanelsForFullScreen()
            return
        }

        if isHiddenForFullScreen {
            restoreIslandVisibility()
            return
        }

        // Already visible: keep panels alive without rebuilding SwiftUI content,
        // otherwise Cursor/Codex overlays flicker every poll.
        keepCompactPanelsVisible()
        updateDesktopPetVisibility()
        maintainExpandedPanelWithoutRebuild()
    }

    private func isFrontmostApplicationFullScreen() -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return false
        }
        return AgentContextProvider.isWindowFullScreen(processID: application.processIdentifier)
    }

    private func hideDesktopPetForFullScreen() {
        desktopPetBubbleDismissWorkItem?.cancel()
        desktopPetBubbleWindow?.alphaValue = 0
        desktopPetWindow?.alphaValue = 0
        desktopPetBubbleWindow?.orderOut(nil)
        desktopPetWindow?.orderOut(nil)
    }

    private func animatePanelsOutForSpaceTransition() {
        let windows = [cameraWindow, leftWindow, rightWindow, expandedWindow, desktopPetWindow, desktopPetBubbleWindow]
            .compactMap { $0 }
            .filter { $0.isVisible && $0.alphaValue > 0.01 }
        guard !windows.isEmpty else { return }

        // Prefer window.alphaValue over contentView.layer.opacity. Fading the
        // content layer freezes Liquid Glass / HUD materials into solid gray/black
        // after Mission Control / Space switches.
        for window in windows {
            window.contentView?.wantsLayer = true
            if let layer = window.contentView?.layer {
                layer.removeAnimation(forKey: "spaceTransitionExit")
                layer.removeAnimation(forKey: "spaceTransitionOpacity")
                let isPet = window === desktopPetWindow || window === desktopPetBubbleWindow
                let targetScale: CGFloat = isPet ? 0.86 : 0.92
                let targetTranslationY: CGFloat = isPet ? 8 : 6
                var target = CATransform3DMakeScale(targetScale, targetScale, 1)
                target = CATransform3DTranslate(target, 0, targetTranslationY, 0)
                let animation = CABasicAnimation(keyPath: "transform")
                animation.fromValue = layer.presentation()?.transform ?? layer.transform
                animation.toValue = target
                animation.duration = fullScreenTransitionDuration
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.transform = target
                layer.add(animation, forKey: "spaceTransitionExit")
                // Keep layer.opacity at 1 so materials keep a valid backdrop binding.
                layer.opacity = 1
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fullScreenTransitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            windows.forEach { $0.animator().alphaValue = 0 }
        }
    }

    private func resetSpaceTransitionVisualState() {
        for window in [cameraWindow, leftWindow, rightWindow, expandedWindow, desktopPetWindow, desktopPetBubbleWindow] {
            guard let layer = window?.contentView?.layer else { continue }
            layer.removeAnimation(forKey: "spaceTransitionExit")
            layer.removeAnimation(forKey: "spaceTransitionOpacity")
            layer.removeAnimation(forKey: "directFullScreenExit")
            layer.removeAnimation(forKey: "directFullScreenOpacity")
            layer.removeAnimation(forKey: "fullScreenRestore")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            CATransaction.commit()
        }
    }

    private func prepareFullScreenRestoreVisualState() {
        for window in [cameraWindow, leftWindow, rightWindow, expandedWindow, desktopPetWindow, desktopPetBubbleWindow] {
            guard let window else { continue }
            window.alphaValue = 0
            window.contentView?.wantsLayer = true
            guard let layer = window.contentView?.layer else { continue }
            layer.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            CATransaction.commit()
        }
    }

    private func animatePanelsInFromNotch(_ windows: [IslandPanel]) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fullScreenTransitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            windows.forEach { $0.animator().alphaValue = 1 }
        }
    }

    private func finishSpaceTransition() {
        preemptiveSpaceTransitionRestoreWorkItem?.cancel()
        preemptiveSpaceTransitionRestoreWorkItem = nil
        spaceTransitionWatchdogWorkItem?.cancel()
        spaceTransitionWatchdogWorkItem = nil
        spaceSwipeGestureEndWorkItem?.cancel()
        spaceSwipeGestureEndWorkItem = nil
        isSpaceSwipeGestureActive = false
        let application = NSWorkspace.shared.frontmostApplication
        model.applyActiveApplication(application)
        suppressSelectionTranslationIfFullScreen(application)
        isSpaceTransitionPending = false
        spaceTransitionOriginWasFullScreen = false
        suppressTransientExpansionAfterSpaceChange()

        if isFrontmostApplicationFullScreen() {
            hideIslandPanelsForFullScreen()
            setSpaceTransitionGlassCoverVisible(false)
        } else {
            // Instant — no fadeIn alpha animation after Space settle.
            restoreIslandVisibility(fadeIn: false)
            scheduleHideSpaceTransitionGlassCover()
        }
    }

    /// After Spaces, ignore stale hover / playerInfo-driven expand for a short settle.
    private func suppressTransientExpansionAfterSpaceChange() {
        barHoverEvaluationWorkItem?.cancel()
        barHoverEvaluationWorkItem = nil
        pendingBarHoverPoint = nil
        barHoverCollapseWorkItem?.cancel()
        barHoverCollapseWorkItem = nil
        isExpandedByBarHover = false
        suppressExpandedPanelUntil = Date().addingTimeInterval(0.65)
        model.suppressAutomaticExpansion(for: 0.65)
        // If still collapsed, keep the expanded panel fully out of the window list.
        if !model.isExpanded {
            hideExpandedPanel(animated: false)
            // Keep paint suppress until after restore settles — prevents 1-frame expand flash.
            model.suppressTransientIslandSurfaces = true
            DispatchQueue.main.async { [weak self] in
                self?.endTransientIslandSurfaceSuppress()
            }
        } else {
            endTransientIslandSurfaceSuppress()
        }
    }

    /// Always clear Space paint suppress when safe; remount expanded panel if still requested.
    private func endTransientIslandSurfaceSuppress() {
        guard !isSpaceTransitionPending else { return }
        if !model.isExpanded {
            expandedWindow?.orderOut(nil)
        }
        model.suppressTransientIslandSurfaces = false
        updateDesktopPetVisibility()
        // Recover "expanded in model, blank/hidden on screen" after Space settle.
        if model.isExpanded {
            showExpandedPanel(animated: false)
        }
        leftWindow?.contentView?.updateTrackingAreas()
        rightWindow?.contentView?.updateTrackingAreas()
    }

    /// Order out expanded + pet and zero their opacity so Spaces snapshots cannot flash them.
    private func hardHideExpandedAndPetForSpaceTransition() {
        model.suppressTransientIslandSurfaces = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for window in [expandedWindow, desktopPetWindow, desktopPetBubbleWindow] {
            guard let window else { continue }
            window.animationBehavior = .none
            window.isRestorable = false
            window.alphaValue = 0
            window.orderOut(nil)
            window.contentView?.layer?.opacity = 0
        }
        CATransaction.commit()
    }

    private var hideSpaceTransitionGlassCoverWorkItem: DispatchWorkItem?

    private func keepIslandWindowsFullyOpaqueForSpaceTransition() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            for window in spaceChromeWindows(includeExpanded: model.isExpanded) {
                window.animationBehavior = .none
                window.animator().alphaValue = 1
                window.alphaValue = 1
                configureIslandWindowChrome(window, level: persistentIslandWindowLevel)
            }
        }
        // Never resurrect a collapsed expanded panel via alpha / chrome refresh.
        if !model.isExpanded {
            expandedWindow?.orderOut(nil)
            expandedWindow?.alphaValue = 1
        }
    }

    private func spaceChromeWindows(includeExpanded: Bool) -> [IslandPanel] {
        var windows = [cameraWindow, leftWindow, rightWindow]
            .compactMap { $0 }
        if !model.suppressTransientIslandSurfaces {
            if let desktopPetWindow { windows.append(desktopPetWindow) }
            if let desktopPetBubbleWindow { windows.append(desktopPetBubbleWindow) }
        }
        if includeExpanded, let expandedWindow {
            windows.append(expandedWindow)
        }
        return windows
    }

    private func setSpaceTransitionGlassCoverVisible(_ visible: Bool) {
        hideSpaceTransitionGlassCoverWorkItem?.cancel()
        hideSpaceTransitionGlassCoverWorkItem = nil
        // Prefer theme-aware flat color so Liquid Glass / dark skins don't flash white.
        let isDark = !model.theme.isLight || model.theme == .aura || model.theme == .void
        NotificationCenter.default.post(
            name: .lumaBarSpaceTransitionGlassCover,
            object: nil,
            userInfo: [
                "visible": visible,
                "isDark": isDark
            ]
        )
        // Snap windows to fully opaque whenever we manage the cover.
        if model.theme.usesBackdropMaterial {
            keepIslandWindowsFullyOpaqueForSpaceTransition()
        }
    }

    private func scheduleHideSpaceTransitionGlassCover() {
        hideSpaceTransitionGlassCoverWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Instant cover removal — no system alpha ramp.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.setSpaceTransitionGlassCoverVisible(false)
            self.keepIslandWindowsFullyOpaqueForSpaceTransition()
            CATransaction.commit()
            // Re-sample wallpaper once the flat cover is gone — never front a collapsed expanded panel.
            for window in self.spaceChromeWindows(includeExpanded: self.model.isExpanded) {
                self.refreshVisualEffectViews(in: window.contentView)
                window.alphaValue = 1
                window.displayIfNeeded()
            }
            if !self.model.isExpanded {
                self.hideExpandedPanel(animated: false)
            }
        }
        hideSpaceTransitionGlassCoverWorkItem = workItem
        // Short settle so the destination Space has a backdrop, then snap (no fade).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func hideIslandPanelsForFullScreen() {
        let windows = [cameraWindow, leftWindow, rightWindow, expandedWindow, desktopPetWindow, desktopPetBubbleWindow]
        guard !isHiddenForFullScreen else { return }

        isHiddenForFullScreen = true
        fullScreenRestoreUntil = .distantPast
        // Keep model.isExpanded / token overlay state so leaving fullscreen can
        // restore instantly without waiting for another Cursor/Codex activation.
        fullScreenHideWorkItem?.cancel()
        let visibleWindows = windows.compactMap { $0 }.filter(\.isVisible)
        if visibleWindows.contains(where: { $0.alphaValue > 0.01 }) {
            for window in visibleWindows {
                window.contentView?.wantsLayer = true
                if let layer = window.contentView?.layer {
                    layer.removeAnimation(forKey: "directFullScreenExit")
                    layer.removeAnimation(forKey: "directFullScreenOpacity")
                    let isPet = window === desktopPetWindow || window === desktopPetBubbleWindow
                    var target = CATransform3DMakeScale(isPet ? 0.86 : 0.92, isPet ? 0.86 : 0.92, 1)
                    target = CATransform3DTranslate(target, 0, isPet ? 8 : 6, 0)
                    let animation = CABasicAnimation(keyPath: "transform")
                    animation.fromValue = layer.presentation()?.transform ?? layer.transform
                    animation.toValue = target
                    animation.duration = fullScreenTransitionDuration
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    layer.transform = target
                    layer.add(animation, forKey: "directFullScreenExit")
                    // Do not fade contentView.layer.opacity — breaks translucent themes.
                    layer.opacity = 1
                }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fullScreenTransitionDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                visibleWindows.forEach { $0.animator().alphaValue = 0 }
            }
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isHiddenForFullScreen else { return }
            windows.forEach {
                $0?.alphaValue = 0
                $0?.orderOut(nil)
            }
        }
        fullScreenHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + fullScreenTransitionDuration + 0.04,
            execute: workItem
        )
        desktopPetBubbleDismissWorkItem?.cancel()
    }

    private func restoreIslandVisibility(fadeIn: Bool = true) {
        fullScreenHideWorkItem?.cancel()
        fullScreenHideWorkItem = nil
        if fadeIn {
            fullScreenRestoreUntil = Date().addingTimeInterval(fullScreenTransitionDuration)
            prepareFullScreenRestoreVisualState()
        } else {
            fullScreenRestoreUntil = .distantPast
            resetSpaceTransitionVisualState()
        }
        NSApp.unhideWithoutActivation()
        if isFrontmostApplicationFullScreen() {
            hideIslandPanelsForFullScreen()
            return
        }

        let wasHiddenForFullScreen = isHiddenForFullScreen
        isHiddenForFullScreen = false
        let layout = notchLayout()
        for window in [cameraWindow, leftWindow, rightWindow, expandedWindow] {
            window?.level = persistentIslandWindowLevel
            window?.collectionBehavior = islandWindowCollectionBehavior
        }
        leftWindow?.setFrame(layout.leftFrame, display: false)
        cameraWindow?.setFrame(layout.leftFrame.union(layout.cameraFrame).union(layout.rightFrame), display: false)
        rightWindow?.setFrame(layout.rightFrame, display: false)
        keepCompactPanelsVisible(alphaValue: fadeIn ? 0 : 1)
        updateDesktopPetVisibility()

        // Honor existing expand state only — never flip isExpanded from Space / fullscreen restore.
        // (Hover, clicks, and explicit product actions are the only expand sources.)
        if model.isExpanded, !model.suppressTransientIslandSurfaces {
            if wasHiddenForFullScreen || expandedWindow?.isVisible != true {
                showExpandedPanel(animated: false)
            } else {
                maintainExpandedPanelWithoutRebuild()
            }
        } else {
            hideExpandedPanel(animated: false)
        }

        if fadeIn {
            let visibleWindows = [cameraWindow, leftWindow, rightWindow, expandedWindow, desktopPetWindow]
                .compactMap { $0 }
                .filter(\.isVisible)
            visibleWindows.forEach { $0.alphaValue = 0 }
            animatePanelsInFromNotch(visibleWindows)
            // After Spaces, rebuild translucent surfaces so glass isn't stuck gray/black.
            DispatchQueue.main.asyncAfter(deadline: .now() + fullScreenTransitionDuration + 0.05) { [weak self] in
                self?.refreshTranslucentSurfacesAfterSpaceChange(rebuildHosting: true)
            }
        } else {
            // Instant Space restore: keep hosting views, only re-assert chrome + glass.
            refreshTranslucentSurfacesAfterSpaceChange(rebuildHosting: false)
        }
    }

    private func refreshTranslucentSurfacesAfterSpaceChange(rebuildHosting: Bool = true) {
        resetSpaceTransitionVisualState()

        let includeExpanded = model.isExpanded && !model.suppressTransientIslandSurfaces
        for window in spaceChromeWindows(includeExpanded: includeExpanded) {
            // Never resurrect pet / bubble while Space suppress is active.
            if model.suppressTransientIslandSurfaces,
               window === desktopPetWindow || window === desktopPetBubbleWindow
            {
                window.alphaValue = 0
                window.orderOut(nil)
                continue
            }
            window.animationBehavior = .none
            window.alphaValue = 1
            configureIslandWindowChrome(window, level: persistentIslandWindowLevel)
            if !isHiddenForFullScreen {
                window.orderFrontRegardless()
            }
        }
        if !includeExpanded {
            hideExpandedPanel(animated: false)
        }

        guard model.theme.usesBackdropMaterial else { return }

        if rebuildHosting {
            // Drop + recreate hosting views so layer backgrounds remount cleanly.
            applyLayout()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.theme.usesBackdropMaterial else { return }
            for window in self.spaceChromeWindows(includeExpanded: self.model.isExpanded) {
                self.refreshVisualEffectViews(in: window.contentView)
                window.alphaValue = 1
                window.viewsNeedDisplay = true
                window.displayIfNeeded()
            }
            if !self.model.isExpanded {
                self.hideExpandedPanel(animated: false)
            }
        }
        // Second pass after Spaces finish compositing the destination desktop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.model.theme.usesBackdropMaterial else { return }
            if rebuildHosting {
                self.applyLayout()
            }
            for window in self.spaceChromeWindows(includeExpanded: self.model.isExpanded) {
                self.refreshVisualEffectViews(in: window.contentView)
                window.alphaValue = 1
                window.displayIfNeeded()
            }
            if !self.model.isExpanded {
                self.hideExpandedPanel(animated: false)
            }
        }
    }

    private func refreshVisualEffectViews(in root: NSView?) {
        guard let root else { return }
        if let aura = root as? AuraGlassEffectView {
            aura.isHidden = false
            aura.alphaValue = 1
            aura.lockActiveGlass()
        } else if let locked = root as? LockedClearBackgroundView {
            locked.lockFixedLayer()
        } else if root is NSVisualEffectView {
            // Neutralize non-Aura system material views (they milk gray when inactive).
            root.isHidden = true
            root.alphaValue = 0
            root.wantsLayer = true
            root.layer?.backgroundColor = NSColor.clear.cgColor
            root.layer?.isOpaque = false
        }
        for child in root.subviews {
            refreshVisualEffectViews(in: child)
        }
    }

    private func maintainExpandedPanelWithoutRebuild() {
        guard model.isExpanded, let expandedWindow else { return }
        guard Date() >= suppressExpandedPanelUntil else { return }
        guard !isFrontmostApplicationFullScreen() else { return }
        guard !isSpaceTransitionPending else { return }

        // Recover stuck Space paint suppress without waiting for another hover.
        if model.suppressTransientIslandSurfaces {
            model.suppressTransientIslandSurfaces = false
        }

        let targetFrame = expandedFrame()
        if expandedWindow.frame != targetFrame {
            expandedWindow.setFrame(targetFrame, display: true)
        }
        expandedWindow.alphaValue = 1
        expandedWindow.ignoresMouseEvents = false
        if !expandedWindow.isVisible {
            showExpandedPanel(animated: false)
        }
    }

    private func keepCompactPanelsVisible(alphaValue: CGFloat = 1) {
        if isFrontmostApplicationFullScreen() {
            hideIslandPanelsForFullScreen()
            return
        }

        relayoutCompactIfMenuBarAvoidanceChanged()

        for window in [cameraWindow, leftWindow, rightWindow] {
            guard let window else { continue }
            window.animationBehavior = .none
            if abs(window.alphaValue - alphaValue) > 0.01 {
                window.alphaValue = alphaValue
            }
            // Cheap level/opaque lock only when something drifted — never full tree strip.
            if window.level != persistentIslandWindowLevel
                || window.isOpaque
                || window.hasShadow
                || window.backgroundColor != .clear
            {
                configureIslandWindowChrome(window, level: persistentIslandWindowLevel)
            }
            if !window.isVisible, alphaValue > 0.01 {
                window.orderFrontRegardless()
            }
        }
    }

    private func refreshInteractiveHitRegions() {
        if let rightWindow {
            rightWindow.immediateActions = rightImmediateActions(for: rightWindow.frame.size)
        }
        expandedWindow?.immediateActions = expandedImmediateActions()
        expandedWindow?.immediateActionRect = expandedCollapseHitRect()
    }

    private func buildWindows() {
        let layout = notchLayout()
        let compactBackgroundFrame = layout.leftFrame
            .union(layout.cameraFrame)
            .union(layout.rightFrame)

        cameraWindow = makePanel(
            frame: compactBackgroundFrame,
            title: "luma bar Camera Mask",
            level: persistentIslandWindowLevel,
            rootView: CameraBarView()
                .frame(width: compactBackgroundFrame.width, height: compactBackgroundFrame.height)
                .environment(\.islandTheme, model.theme)
                .preferredColorScheme(model.theme.preferredColorScheme)
        )
        cameraWindow?.ignoresMouseEvents = true

        leftWindow = makePanel(
            frame: layout.leftFrame,
            title: "luma bar Music Left",
            level: persistentIslandWindowLevel,
            rootView: CompactLeftView(model: model)
                .frame(width: layout.leftFrame.width, height: layout.leftFrame.height)
                .environment(\.islandTheme, model.theme)
                .preferredColorScheme(model.theme.preferredColorScheme)
        )
        leftWindow?.immediateActions = [
            (
                rect: NSRect(x: 0, y: 0, width: layout.leftFrame.width, height: layout.leftFrame.height),
                action: .toggleExpanded
            )
        ]
        leftWindow?.actionHandler = self

        rightWindow = makePanel(
            frame: layout.rightFrame,
            title: "luma bar Music Right",
            level: persistentIslandWindowLevel,
            rootView: CompactRightView(model: model)
                .frame(width: layout.rightFrame.width, height: layout.rightFrame.height)
                .environment(\.islandTheme, model.theme)
                .preferredColorScheme(model.theme.preferredColorScheme)
        )
        rightWindow?.immediateActions = rightImmediateActions(for: layout.rightFrame.size)
        rightWindow?.actionHandler = self

        expandedWindow = makePanel(
            frame: expandedFrame(),
            title: "luma bar Music Player",
            level: persistentIslandWindowLevel,
            rootView: MusicExpandedView(model: model)
                .frame(width: expandedPanelSize.width, height: expandedPanelSize.height)
                .environment(\.islandTheme, model.theme)
                .preferredColorScheme(model.theme.preferredColorScheme)
        )
        expandedWindow?.contentView = makeExpandedHostingView()
        expandedWindow?.immediateActions = expandedImmediateActions()
        expandedWindow?.immediateActionRect = expandedCollapseHitRect()
        expandedWindow?.immediateAction = .collapseExpanded
        expandedWindow?.actionHandler = self
        // Collapsed by default — never leave an on-screen snapshot for Spaces to restore.
        expandedWindow?.orderOut(nil)

        buildDesktopPetWindow()
        desktopPetWindow?.orderOut(nil)
    }

    private func makePanel<Content: View>(
        frame: NSRect,
        title: String,
        level: NSWindow.Level? = nil,
        rootView: Content
    ) -> IslandPanel {
        let panel = IslandPanel(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.alphaValue = 1
        panel.title = title
        let resolvedLevel = level ?? IslandPanel.preferredLevel
        configureIslandWindowChrome(panel, level: resolvedLevel)
        panel.level = resolvedLevel
        panel.collectionBehavior = IslandPanel.preferredCollectionBehavior
        panel.contentView = FirstMouseHostingView(rootView: rootView)
        // Force an immediate layout/display pass so glass is ready before first Spaces swipe.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        panel.alphaValue = 1

        return panel
    }

    private func makeExpandedHostingView() -> NSView {
        let hostingView = FirstMouseHostingView(
            rootView: ExpandedIslandSurface(
                model: model,
                size: expandedPanelSize
            )
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = model.usesCompactExpandedOverlay
            ? model.theme.tokenOverlayCornerRadius
            : model.theme.expandedCornerRadius
        hostingView.layer?.cornerCurve = model.theme.isGrid ? .circular : .continuous
        // Layer-backed fixed fills; clipping is safe (no backdrop material sampling).
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.isOpaque = false
        return hostingView
    }

    private func buildDesktopPetWindow() {
        desktopPetWindow = makePanel(
            frame: desktopPetFrame(),
            title: LumaBarL10n.companionTitle,
            rootView: makeDesktopPetView()
            .frame(width: desktopPetSize.width, height: desktopPetSize.height)
            .preferredColorScheme(model.theme.preferredColorScheme)
        )
        desktopPetWindow?.hasShadow = false
    }

    private func makeDesktopPetHostingView() -> NSView {
        FirstMouseHostingView(
            rootView: makeDesktopPetView()
            .frame(width: desktopPetSize.width, height: desktopPetSize.height)
            .preferredColorScheme(model.theme.preferredColorScheme)
        )
    }

    private func makeDesktopPetView() -> PixelDesktopPetView {
        PixelDesktopPetView(
            model: model,
            onTap: { [weak self] in
                self?.showDesktopPetMessage()
            },
            onLongPress: { [weak self] in
                self?.toggleVoiceWhisper()
            },
            onDragChanged: { [weak self] in
                self?.dragDesktopPet()
            },
            onDragEnded: { [weak self] in
                self?.finishDesktopPetDrag()
            }
        )
    }

    private func desktopPetFrame() -> NSRect {
        let screen = islandScreen
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = desktopPetSize
        let defaultOrigin = NSPoint(
            x: frame.maxX - size.width - 12,
            y: frame.minY + 12
        )
        let defaults = UserDefaults.standard
        let savedOrigin: NSPoint
        if defaults.object(forKey: desktopPetOriginXDefaultsKey) != nil,
           defaults.object(forKey: desktopPetOriginYDefaultsKey) != nil {
            savedOrigin = NSPoint(
                x: defaults.double(forKey: desktopPetOriginXDefaultsKey),
                y: defaults.double(forKey: desktopPetOriginYDefaultsKey)
            )
        } else {
            savedOrigin = defaultOrigin
        }
        let origin = constrainedDesktopPetOrigin(savedOrigin)
        return NSRect(
            x: origin.x,
            y: origin.y,
            width: size.width,
            height: size.height
        )
    }

    private func constrainedDesktopPetOrigin(_ origin: NSPoint) -> NSPoint {
        let size = desktopPetSize
        let center = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: max(frame.minX, min(origin.x, frame.maxX - size.width)),
            y: max(frame.minY, min(origin.y, frame.maxY - size.height))
        )
    }

    private func dragDesktopPet() {
        guard model.theme.showsDesktopPet, let window = desktopPetWindow else { return }
        if desktopPetDragStartOrigin == nil {
            desktopPetDragStartOrigin = window.frame.origin
            desktopPetDragStartMouseLocation = NSEvent.mouseLocation
            desktopPetBubbleDismissWorkItem?.cancel()
            desktopPetBubbleWindow?.orderOut(nil)
        }
        guard
            let startOrigin = desktopPetDragStartOrigin,
            let startMouseLocation = desktopPetDragStartMouseLocation
        else {
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        let proposedOrigin = NSPoint(
            x: startOrigin.x + mouseLocation.x - startMouseLocation.x,
            y: startOrigin.y + mouseLocation.y - startMouseLocation.y
        )
        window.setFrameOrigin(constrainedDesktopPetOrigin(proposedOrigin))
        configureIslandWindowChrome(window, level: persistentIslandWindowLevel)
        refreshVisualEffectViews(in: window.contentView)
    }

    private func finishDesktopPetDrag() {
        guard desktopPetDragStartOrigin != nil, let origin = desktopPetWindow?.frame.origin else { return }
        desktopPetDragStartOrigin = nil
        desktopPetDragStartMouseLocation = nil
        if let window = desktopPetWindow {
            configureIslandWindowChrome(window, level: persistentIslandWindowLevel)
            refreshVisualEffectViews(in: window.contentView)
        }
        UserDefaults.standard.set(Double(origin.x), forKey: desktopPetOriginXDefaultsKey)
        UserDefaults.standard.set(Double(origin.y), forKey: desktopPetOriginYDefaultsKey)
    }

    private func desktopPetBubblePlacement() -> (frame: NSRect, tailOnRight: Bool) {
        let bubbleSize = NSSize(width: 246, height: 82)
        let petFrame = desktopPetWindow?.frame ?? desktopPetFrame()
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let tailOnRight = petFrame.midX >= screenFrame.midX
        let proposedX = tailOnRight
            ? petFrame.maxX - bubbleSize.width - 34
            : petFrame.minX + 34
        let proposedY = petFrame.maxY - 8
        let frame = NSRect(
            x: max(screenFrame.minX + 8, min(proposedX, screenFrame.maxX - bubbleSize.width - 8)),
            y: max(screenFrame.minY + 8, min(proposedY, screenFrame.maxY - bubbleSize.height - 8)),
            width: bubbleSize.width,
            height: bubbleSize.height
        )
        return (frame, tailOnRight)
    }

    private func updateDesktopPetVisibility() {
        if isSpaceTransitionPending || model.suppressTransientIslandSurfaces {
            desktopPetBubbleDismissWorkItem?.cancel()
            desktopPetBubbleWindow?.alphaValue = 0
            desktopPetWindow?.alphaValue = 0
            desktopPetBubbleWindow?.orderOut(nil)
            desktopPetWindow?.orderOut(nil)
            return
        }
        if isHiddenForFullScreen || isFrontmostApplicationFullScreen() {
            hideDesktopPetForFullScreen()
            return
        }

        guard model.theme.showsDesktopPet else {
            desktopPetBubbleDismissWorkItem?.cancel()
            desktopPetBubbleWindow?.orderOut(nil)
            desktopPetWindow?.orderOut(nil)
            return
        }

        if desktopPetDragStartOrigin == nil {
            desktopPetWindow?.setFrame(desktopPetFrame(), display: true)
        }
        desktopPetWindow?.contentView?.layer?.opacity = 1
        desktopPetWindow?.alphaValue = 1
        if desktopPetWindow?.isVisible != true {
            desktopPetWindow?.orderFrontRegardless()
        }
    }

    private func showDesktopPetMessage(_ explicitMessage: String? = nil) {
        let theme = model.theme
        let messages = theme.desktopPetMessages
        guard theme.showsDesktopPet,
              !isHiddenForFullScreen,
              !isSpaceTransitionPending,
              !isFrontmostApplicationFullScreen(),
              explicitMessage != nil || !messages.isEmpty
        else {
            return
        }

        let message: String
        if let explicitMessage {
            message = explicitMessage
        } else if let moodMessage = model.desktopPetMoodMessage {
            message = moodMessage
        } else {
            let previousIndex = lastDesktopPetMessageTheme == theme ? lastDesktopPetMessageIndex : nil
            let availableIndices = messages.indices.filter { $0 != previousIndex }
            let index = availableIndices.randomElement() ?? messages.startIndex
            lastDesktopPetMessageIndex = index
            lastDesktopPetMessageTheme = theme
            message = messages[index]
        }
        let placement = desktopPetBubblePlacement()
        let frame = placement.frame

        if desktopPetBubbleWindow == nil {
            desktopPetBubbleWindow = makePanel(
                frame: frame,
                title: "Luma Companion Message",
                rootView: PixelCompanionSpeechBubble(text: message, tailOnRight: placement.tailOnRight)
                    .frame(width: frame.width, height: frame.height)
                    .environment(\.islandTheme, theme)
                    .preferredColorScheme(theme.preferredColorScheme)
            )
            desktopPetBubbleWindow?.ignoresMouseEvents = true
            desktopPetBubbleWindow?.hasShadow = false
        } else {
            desktopPetBubbleWindow?.contentView = FirstMouseHostingView(
                rootView: PixelCompanionSpeechBubble(text: message, tailOnRight: placement.tailOnRight)
                    .frame(width: frame.width, height: frame.height)
                    .environment(\.islandTheme, theme)
                    .preferredColorScheme(theme.preferredColorScheme)
            )
            desktopPetBubbleWindow?.setFrame(frame, display: true)
        }

        desktopPetBubbleDismissWorkItem?.cancel()
        desktopPetBubbleWindow?.alphaValue = 0
        desktopPetBubbleWindow?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.allowsImplicitAnimation = true
            desktopPetBubbleWindow?.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hideDesktopPetMessage()
            }
        }
        desktopPetBubbleDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2, execute: workItem)
    }

    private func hideDesktopPetMessage() {
        guard let window = desktopPetBubbleWindow, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 0
        } completionHandler: { [weak window] in
            Task { @MainActor in
                window?.orderOut(nil)
                window?.alphaValue = 1
            }
        }
    }

    private func showFullScreenCompletionToast() {
        let size = NSSize(width: 324, height: 76)
        let screenFrame = (NSScreen.main ?? islandScreen ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Top-right, flush with the top edge of the screen — the frame derives
        // automatically from the active screen's visible frame.
        let frame = NSRect(
            x: screenFrame.maxX - size.width - 18,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        let rootView: AnyView
        if let notice = model.taskCompletionNotice {
            rootView = AnyView(
                FullScreenTaskCompletionToastView(notice: notice)
                    .frame(width: size.width, height: size.height)
                    .environment(\.islandTheme, model.theme)
                    .preferredColorScheme(model.theme.preferredColorScheme)
            )
        } else {
            return
        }

        if fullScreenCompletionToastWindow == nil {
            fullScreenCompletionToastWindow = makePanel(
                frame: frame,
                title: "Island Notice Toast",
                level: persistentIslandWindowLevel,
                rootView: rootView
            )
            fullScreenCompletionToastWindow?.ignoresMouseEvents = true
            fullScreenCompletionToastWindow?.hasShadow = true
        } else {
            fullScreenCompletionToastWindow?.contentView = FirstMouseHostingView(rootView: rootView)
            fullScreenCompletionToastWindow?.setFrame(frame, display: true)
        }

        guard let window = fullScreenCompletionToastWindow else { return }
        fullScreenCompletionToastDismissWorkItem?.cancel()
        window.level = persistentIslandWindowLevel
        window.collectionBehavior = islandWindowCollectionBehavior
        // Never pin toasts as stationary — same Spaces black-square class of bug.
        // Toast still follows the active Space via moveToActiveSpace.
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.hideFullScreenCompletionToast()
        }
        fullScreenCompletionToastDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: workItem)
    }

    private func hideFullScreenCompletionToast() {
        guard let window = fullScreenCompletionToastWindow, window.isVisible else {
            model.dismissTaskCompletionNotice()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                window?.orderOut(nil)
                window?.alphaValue = 1
                self?.fullScreenCompletionToastDismissWorkItem = nil
                self?.model.dismissTaskCompletionNotice()
            }
        }
    }

    private func applyLayout() {
        let layout = notchLayout()
        let compactBackgroundFrame = layout.leftFrame
            .union(layout.cameraFrame)
            .union(layout.rightFrame)

        model.cameraGapWidth = layout.cameraGapWidth

        leftWindow?.contentView = FirstMouseHostingView(
            rootView: CompactLeftView(model: model)
                .frame(width: layout.leftFrame.width, height: layout.leftFrame.height)
                .environment(\.islandTheme, model.theme)
                .preferredColorScheme(model.theme.preferredColorScheme)
        )
        rightWindow?.contentView = FirstMouseHostingView(
            rootView: CompactRightView(model: model)
                .frame(width: layout.rightFrame.width, height: layout.rightFrame.height)
                .environment(\.islandTheme, model.theme)
                .preferredColorScheme(model.theme.preferredColorScheme)
        )
        cameraWindow?.contentView = FirstMouseHostingView(
            rootView: CameraBarView()
                .frame(width: compactBackgroundFrame.width, height: compactBackgroundFrame.height)
                .environment(\.islandTheme, model.theme)
                .preferredColorScheme(model.theme.preferredColorScheme)
        )
        cameraWindow?.ignoresMouseEvents = true
        leftWindow?.ignoresMouseEvents = false
        rightWindow?.ignoresMouseEvents = false
        expandedWindow?.contentView = makeExpandedHostingView()
        desktopPetWindow?.contentView = makeDesktopPetHostingView()

        leftWindow?.setFrame(layout.leftFrame, display: true)
        cameraWindow?.setFrame(compactBackgroundFrame, display: true)
        rightWindow?.setFrame(layout.rightFrame, display: true)
        expandedWindow?.setFrame(expandedFrame(), display: true)
        desktopPetWindow?.setFrame(desktopPetFrame(), display: true)
        expandedWindow?.immediateActions = expandedImmediateActions()
        leftWindow?.immediateActions = [
            (
                rect: NSRect(x: 0, y: 0, width: layout.leftFrame.width, height: layout.leftFrame.height),
                action: .toggleExpanded
            )
        ]
        rightWindow?.immediateActions = rightImmediateActions(for: layout.rightFrame.size)
        expandedWindow?.immediateActionRect = expandedCollapseHitRect()
        leftWindow?.contentView?.updateTrackingAreas()
        rightWindow?.contentView?.updateTrackingAreas()

        NSApp.unhideWithoutActivation()
        if isFrontmostApplicationFullScreen() {
            hideIslandPanelsForFullScreen()
        } else {
            cameraWindow?.orderFrontRegardless()
            leftWindow?.orderFrontRegardless()
            rightWindow?.orderFrontRegardless()
            updateExpandedPanelVisibility(isExpanded: model.isExpanded, animated: false)
        }

        updateDesktopPetVisibility()
    }

    private func beginLicensedSession() {
        applyLayout()
        if PermissionOnboardingModel.hasCompletedSetup {
            model.scanLocalMusic()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showPermissionOnboarding()
            }
        }
    }

    private func collapseExpandedPanel() {
        dismissExpandedPanelImmediately()
    }

    private func toggleExpandedPanel() {
        if model.isExpanded {
            collapseExpandedPanel()
        } else {
            model.isExpanded = true
        }
    }

    private func updateExpandedPanelVisibility(isExpanded: Bool, animated: Bool) {
        if isExpanded {
            showExpandedPanel(animated: animated)
        } else {
            hideExpandedPanel(animated: animated)
        }
    }

    private func relayoutExpandedPanelIfNeeded() {
        guard model.isExpanded, let expandedWindow, expandedWindow.isVisible else { return }
        let frame = expandedFrame()
        let sizeChanged = expandedWindow.frame.size != frame.size
        if expandedWindow.frame != frame {
            // Don't display yet. A forced draw of the old view, then a brand-new
            // hosting view, paints the transport controls at the top-left for a frame.
            expandedWindow.setFrame(frame, display: false)
        }
        // The hosting view already observes the model. Replacing it when only the
        // library source changes (local → Apple Music) flashes the play buttons.
        if expandedWindow.contentView == nil || sizeChanged {
            expandedWindow.contentView = makeExpandedHostingView()
        }
        refreshInteractiveHitRegions()
    }

    private func showExpandedPanel(animated: Bool) {
        guard let expandedWindow else { return }
        if expandedPanelRevealInFlight {
            return
        }
        guard !isSpaceTransitionPending else {
            expandedWindow.alphaValue = 0
            expandedWindow.orderOut(nil)
            return
        }
        // Hover / user expand always lifts paint suppress — otherwise the panel stays opacity-0 forever.
        if model.suppressTransientIslandSurfaces {
            model.suppressTransientIslandSurfaces = false
        }
        guard !isHiddenForFullScreen, !isFrontmostApplicationFullScreen() else {
            hideIslandPanelsForFullScreen()
            return
        }
        guard model.taskCompletionNotice != nil
            || Date() >= suppressExpandedPanelUntil
        else {
            expandedWindow.orderOut(nil)
            expandedWindow.alphaValue = 1
            return
        }

        expandedWindow.ignoresMouseEvents = false
        expandedWindow.setFrame(expandedFrame(), display: true)
        expandedWindow.contentView = makeExpandedHostingView()
        expandedWindow.contentView?.updateTrackingAreas()

        // IslandPanel: use makeKey when Agent keyboard input is needed; otherwise
        // orderFrontRegardless keeps hover expand reliable without activating chrome.
        let bringFront: () -> Void = {
            if expandedWindow.allowsKeyboardFocus {
                expandedWindow.makeKeyAndOrderFront(nil)
            } else {
                expandedWindow.orderFrontRegardless()
            }
        }
        let reveal: () -> Void = { [weak self] in
            guard let self else { return }
            if !animated {
                expandedWindow.alphaValue = 1
                bringFront()
                return
            }
            self.expandedPanelRevealInFlight = true
            expandedWindow.alphaValue = 0
            bringFront()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.allowsImplicitAnimation = true
                expandedWindow.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.expandedPanelRevealInFlight = false
                }
            }
        }
        if model.usesCompactExpandedOverlay {
            reveal()
            return
        }
        reveal()
    }

    private func hideExpandedPanel(animated: Bool) {
        guard let expandedWindow else { return }
        expandedPanelRevealInFlight = false
        isExpandedByBarHover = false
        barHoverCollapseWorkItem?.cancel()
        barHoverCollapseWorkItem = nil

        guard expandedWindow.isVisible else {
            expandedWindow.alphaValue = 1
            expandedWindow.orderOut(nil)
            leftWindow?.contentView?.updateTrackingAreas()
            rightWindow?.contentView?.updateTrackingAreas()
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                expandedWindow.animator().alphaValue = 0
            } completionHandler: { [weak self, weak expandedWindow] in
                Task { @MainActor in
                    guard let expandedWindow else { return }
                    guard self?.model.isExpanded != true else {
                        expandedWindow.alphaValue = 1
                        return
                    }
                    expandedWindow.orderOut(nil)
                    expandedWindow.alphaValue = 1
                    self?.leftWindow?.contentView?.updateTrackingAreas()
                    self?.rightWindow?.contentView?.updateTrackingAreas()
                }
            }
        } else {
            expandedWindow.orderOut(nil)
            expandedWindow.alphaValue = 1
            leftWindow?.contentView?.updateTrackingAreas()
            rightWindow?.contentView?.updateTrackingAreas()
        }
    }

    func islandPanel(_ panel: IslandPanel, didTrigger action: IslandPanelAction) {
        switch action {
        case .toggleExpanded:
            // Hover already expands a preview. An explicit click should pin it open,
            // not toggle it closed (that made compact Ask/expand feel broken).
            if model.isExpanded, isExpandedByBarHover {
                pinExpandedPanelFromUserClick()
            } else if model.isExpanded {
                collapseExpandedPanel()
            } else {
                pinExpandedPanelFromUserClick(expandIfNeeded: true)
            }
        case .collapseExpanded:
            collapseExpandedPanel()
        case .togglePlayback:
            model.togglePlayback()
        case .nextTrack:
            model.nextTrack()
        case .openAgent:
            // Ask toggles: open/pin Agent, press again to close once it's pinned open.
            if model.isExpanded, model.activeMode == .agent, !isExpandedByBarHover {
                collapseExpandedPanel()
            } else {
                model.showAgent()
                pinExpandedPanelFromUserClick(expandIfNeeded: true)
            }
        case .showMusic:
            expandedWindow?.makeFirstResponder(nil)
            expandedWindow?.allowsKeyboardFocus = false
            expandedWindow?.lockTransparentRenderChrome()
            model.showMusic()
            refreshInteractiveHitRegions()
            relayoutExpandedPanelIfNeeded()
        case .showSystem:
            expandedWindow?.makeFirstResponder(nil)
            expandedWindow?.allowsKeyboardFocus = false
            expandedWindow?.lockTransparentRenderChrome()
            model.showSystem()
            refreshInteractiveHitRegions()
            relayoutExpandedPanelIfNeeded()
        case .showAgentMode:
            if let expandedWindow {
                expandedWindow.allowsKeyboardFocus = true
                expandedWindow.lockTransparentRenderChrome()
            }
            model.showAgent()
            refreshInteractiveHitRegions()
            relayoutExpandedPanelIfNeeded()
            if let expandedWindow {
                activateForUserInteraction(panel: expandedWindow)
            }
        case .openExternalToken:
            // Same as a normal bar click: open Music / System / Agent, not the token sheet.
            pinExpandedPanelFromUserClick(expandIfNeeded: true)
        case .agentQuickAction(let kind):
            if let expandedWindow {
                activateForUserInteraction(panel: expandedWindow)
            }
            model.runAgentQuickAction(kind)
        case .setMusicLibrarySource(let source):
            expandedWindow?.makeFirstResponder(nil)
            expandedWindow?.allowsKeyboardFocus = false
            expandedWindow?.lockTransparentRenderChrome()
            model.setMusicLibrarySource(source)
            refreshInteractiveHitRegions()
            relayoutExpandedPanelIfNeeded()
        }
    }

    private func pinExpandedPanelFromUserClick(expandIfNeeded: Bool = false) {
        isExpandedByBarHover = false
        barHoverCollapseWorkItem?.cancel()
        barHoverCollapseWorkItem = nil
        model.prepareExpandedContentForUserInteraction()
        if expandIfNeeded {
            model.isExpanded = true
        }
        if let expandedWindow {
            activateForUserInteraction(panel: expandedWindow)
        }
        refreshInteractiveHitRegions()
    }

    private func activateForUserInteraction(panel: IslandPanel) {
        if panel === expandedWindow, Date() < suppressExpandedPanelUntil {
            return
        }

        // Only Agent needs a key window for text input; Music/System stay non-activating.
        if panel === expandedWindow, model.activeMode == .agent {
            panel.allowsKeyboardFocus = true
            panel.lockTransparentRenderChrome()
        }

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        if panel.allowsKeyboardFocus || panel.canBecomeKey {
            panel.makeKey()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }

        if panel === expandedWindow {
            pendingExpandedActivationWorkItem?.cancel()
        }

        let workItem = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            if panel === self.expandedWindow, !self.model.isExpanded {
                return
            }
            if panel === self.expandedWindow, Date() < self.suppressExpandedPanelUntil {
                return
            }
            if panel === self.expandedWindow, self.model.activeMode == .agent {
                panel.allowsKeyboardFocus = true
                panel.lockTransparentRenderChrome()
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            if panel.allowsKeyboardFocus || panel.canBecomeKey {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }
        if panel === expandedWindow {
            pendingExpandedActivationWorkItem = workItem
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func dismissExpandedPanelImmediately() {
        lastShellPromptHotKeyAt = Date()
        suppressExpandedPanelUntil = Date().addingTimeInterval(1.25)
        pendingExpandedActivationWorkItem?.cancel()
        pendingExpandedActivationWorkItem = nil
        model.suppressAutomaticExpansion(for: 1.25)
        model.collapse()

        guard let expandedWindow else { return }
        expandedWindow.makeFirstResponder(nil)
        expandedWindow.allowsKeyboardFocus = false
        expandedWindow.lockTransparentRenderChrome()
        expandedWindow.orderOut(nil)
        expandedWindow.alphaValue = 1
    }

    private func expandedImmediateActions() -> [(rect: NSRect, action: IslandPanelAction)] {
        var actions: [(rect: NSRect, action: IslandPanelAction)] = []

        // Mode pills sit left of the collapse control. Route them as immediate
        // actions so Agent's focused TextField can't swallow the first click.
        let size = expandedPanelSize
        let pad = NotchMetrics.expandedHeaderPadding
        let rowH = NotchMetrics.expandedHeaderRowHeight
        let pillW = NotchMetrics.expandedModePillWidth
        let pillGap = NotchMetrics.expandedModePillSpacing
        let collapseW = NotchMetrics.expandedCollapseButton
        let y = size.height - pad - rowH
        var cursorX = size.width - pad - collapseW - 6

        let modeItems: [(CGFloat, IslandPanelAction)] = [
            (pillW, .showAgentMode),
            (pillW, .showSystem),
            (pillW, .showMusic)
        ]
        for (width, action) in modeItems {
            cursorX -= width
            actions.append((
                rect: NSRect(x: cursorX - 2, y: y - 2, width: width + 4, height: rowH + 4),
                action: action
            ))
            cursorX -= pillGap
        }

        // Music source pills sit on the next row. Same AppKit mouseDown path — SwiftUI
        // Buttons on this non-key panel need a full press/release that timer rebuilds cancel.
        if model.activeMode == .music {
            let sourceFont = model.theme.isPixelStyled
                ? NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
                : NSFont.systemFont(ofSize: 10, weight: .semibold)
            let sourceY = y - 7 - 26
            var sourceX = pad
            for source in IslandMusicLibrarySource.allCases {
                let textWidth = (source.title as NSString)
                    .size(withAttributes: [.font: sourceFont]).width
                // Generous hit pad — localized titles + font metrics drift vs SwiftUI layout.
                let width = ceil(textWidth) + 22
                actions.append((
                    rect: NSRect(x: sourceX - 4, y: sourceY - 4, width: width + 8, height: 34),
                    action: .setMusicLibrarySource(source)
                ))
                sourceX += ceil(textWidth) + 18 + 6
            }
        }

        guard model.activeMode == .agent else { return actions }

        let font = model.theme.isPixelStyled
            ? NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
            : NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        var x: CGFloat = pad
        // Quick actions sit below the compact header + context row.
        let quickY = size.height - pad - rowH - 8 - 52
        for quickAction in model.agentQuickActions {
            let textWidth = (quickAction.title as NSString).size(withAttributes: [.font: font]).width
            let width = ceil(textWidth) + 35
            defer { x += width + 7 }
            actions.append((
                rect: NSRect(x: x, y: max(8, quickY), width: width, height: 28),
                action: .agentQuickAction(quickAction.kind)
            ))
        }
        return actions
    }

    private func expandedCollapseHitRect() -> NSRect {
        let size = expandedPanelSize
        let pad = NotchMetrics.expandedHeaderPadding
        let button = NotchMetrics.expandedCollapseButton
        // Tight hit target — the old 82×82 zone covered Music/System/Agent pills.
        return NSRect(
            x: size.width - pad - button - 2,
            y: size.height - pad - button - 2,
            width: button + 4,
            height: button + 4
        )
    }

    private func compactMusicControlRects(for size: NSSize) -> (
        play: NSRect,
        expand: NSRect,
        next: NSRect
    ) {
        // Must match CompactRightView music-mode layout:
        // horizontally centered row, spacing from NotchMetrics.compactRightControlSpacing,
        // play 24, ring 24, next 24.
        let spacing = NotchMetrics.compactRightControlSpacing
        let playWidth: CGFloat = 24
        let ringWidth: CGFloat = 24
        let nextWidth: CGFloat = 24
        let rowWidth = playWidth + spacing + ringWidth + spacing + nextWidth
        let rowOriginX = max(0, (size.width - rowWidth) / 2)
        let controlHeight = max(size.height, 28)
        let y: CGFloat = 0
        let playX = rowOriginX
        let expandX = playX + playWidth + spacing
        let nextX = expandX + ringWidth + spacing
        return (
            play: NSRect(x: playX - 2, y: y, width: playWidth + spacing, height: controlHeight),
            expand: NSRect(x: expandX - 2, y: y, width: ringWidth + spacing, height: controlHeight),
            next: NSRect(x: nextX - 2, y: y, width: max(nextWidth + 6, size.width - (nextX - 2)), height: controlHeight)
        )
    }

    private func rightImmediateActions(for size: NSSize) -> [(rect: NSRect, action: IslandPanelAction)] {
        if model.activeMode == .agent {
            return [
                (
                    rect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                    action: .openAgent
                )
            ]
        }
        if model.activeMode == .system || model.activeMode == .token {
            return [
                (
                    rect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                    action: .toggleExpanded
                )
            ]
        }

        let controls = compactMusicControlRects(for: size)
        return [
            (rect: controls.play, action: .togglePlayback),
            (
                rect: controls.expand,
                action: .toggleExpanded
            ),
            (rect: controls.next, action: .nextTrack)
        ]
    }

    private func notchLayout() -> (
        leftFrame: NSRect,
        cameraFrame: NSRect,
        rightFrame: NSRect,
        cameraGapWidth: CGFloat
    ) {
        let screen = islandScreen
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topY = screenFrame.maxY - NotchMetrics.compactHeight

        if
            let leftArea = screen?.auxiliaryTopLeftArea,
            let rightArea = screen?.auxiliaryTopRightArea,
            rightArea.minX > leftArea.maxX
        {
            let leftWidth = min(compactPreferredLeftWidth, leftArea.width)
            let rightWidth = min(compactPreferredRightWidth, rightArea.width)
            let leftFrame = NSRect(
                x: leftArea.maxX - leftWidth,
                y: leftArea.minY,
                width: leftWidth + NotchMetrics.notchEdgeOverlap,
                height: leftArea.height
            )
            let rightFrame = NSRect(
                x: rightArea.minX - NotchMetrics.notchEdgeOverlap,
                y: rightArea.minY,
                width: rightWidth + NotchMetrics.notchEdgeOverlap,
                height: rightArea.height
            )
            let cameraFrame = NSRect(
                x: leftArea.maxX,
                y: leftArea.minY,
                width: rightArea.minX - leftArea.maxX,
                height: leftArea.height
            )
            return (leftFrame, cameraFrame, rightFrame, rightArea.minX - leftArea.maxX)
        }

        var leftWidth = NotchMetrics.compactFallbackLeftWidth
        var rightWidth = NotchMetrics.compactFallbackRightWidth
        var gap = NotchMetrics.fallbackCameraGap
        let overlap = NotchMetrics.notchEdgeOverlap
        let centerX = screenFrame.midX

        if let screen {
            let statusLeft = MenuBarStatusItemProbe.leftEdge(on: screen)
            let allowedMaxX = statusLeft.map { $0 - NotchMetrics.statusItemClearance } ?? screenFrame.maxX
            let allowedMinX = screenFrame.minX + 240
            let maxHalf = min(centerX - allowedMinX, allowedMaxX - centerX)
            let maxTotal = max(NotchMetrics.compactGapMinWidth, maxHalf * 2)
            let naturalTotal = leftWidth + gap + rightWidth
            if naturalTotal > maxTotal {
                var excess = naturalTotal - maxTotal
                let shrinkableLeft = max(0, leftWidth - NotchMetrics.compactLeftMinWidth)
                let shrinkableRight = max(0, rightWidth - NotchMetrics.compactRightMinWidth)
                let capsuleBudget = shrinkableLeft + shrinkableRight
                if capsuleBudget > 0 {
                    let shrinkCapsules = min(excess, capsuleBudget)
                    let leftShare = shrinkCapsules * (shrinkableLeft / capsuleBudget)
                    leftWidth -= leftShare
                    rightWidth -= shrinkCapsules - leftShare
                    excess -= shrinkCapsules
                }
                if excess > 0 {
                    gap = max(NotchMetrics.compactGapMinWidth, gap - excess)
                }
            }
        }

        // Windows snap to whole points; fractional frames never match the computed layout,
        // so the 0.2s menu-bar relayout check would rebuild every panel on every tick.
        leftWidth = leftWidth.rounded(.down)
        rightWidth = rightWidth.rounded(.down)
        gap = gap.rounded(.down)
        let originX = (centerX - (leftWidth + gap + rightWidth) / 2).rounded()

        let leftFrame = NSRect(
            x: originX,
            y: topY,
            width: leftWidth + overlap,
            height: NotchMetrics.compactHeight
        )
        let cameraFrame = NSRect(
            x: originX + leftWidth,
            y: topY,
            width: gap,
            height: NotchMetrics.compactHeight
        )
        let rightFrame = NSRect(
            x: originX + leftWidth + gap - overlap,
            y: topY,
            width: rightWidth + overlap,
            height: NotchMetrics.compactHeight
        )
        return (leftFrame, cameraFrame, rightFrame, gap)
    }

    private func relayoutCompactIfMenuBarAvoidanceChanged() {
        guard let screen = islandScreen else { return }
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX
        {
            return
        }

        let layout = notchLayout()
        let widthChanged =
            abs((leftWindow?.frame.width ?? 0) - layout.leftFrame.width) > 0.5
            || abs((rightWindow?.frame.width ?? 0) - layout.rightFrame.width) > 0.5
        let positionChanged =
            abs((leftWindow?.frame.minX ?? 0) - layout.leftFrame.minX) > 0.5
            || abs((rightWindow?.frame.minX ?? 0) - layout.rightFrame.minX) > 0.5
        guard widthChanged || positionChanged else { return }

        if widthChanged {
            applyLayout()
            return
        }

        leftWindow?.setFrame(layout.leftFrame, display: true)
        cameraWindow?.setFrame(
            layout.leftFrame.union(layout.cameraFrame).union(layout.rightFrame),
            display: true
        )
        rightWindow?.setFrame(layout.rightFrame, display: true)
        if model.isExpanded {
            expandedWindow?.setFrame(expandedFrame(), display: true)
        }
    }

    private func expandedFrame() -> NSRect {
        let screen = islandScreen
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let layout = notchLayout()
        let expandedSize = expandedPanelSize
        let centerX = (layout.leftFrame.minX + layout.rightFrame.maxX) / 2
            + NotchMetrics.expandedVisualOffsetX

        return NSRect(
            x: centerX - expandedSize.width / 2,
            y: frame.maxY - expandedSize.height - NotchMetrics.expandedTopInset,
            width: expandedSize.width,
            height: expandedSize.height
        )
    }

    private func buildMenu() {
        menuBuilder.target = self
        NSApp.mainMenu = menuBuilder.makeApplicationMenu()
        menuBuilder.updateThemeState(model.theme)
        menuBuilder.updatePanelVisibility(isExpanded: model.isExpanded)
        menuBuilder.updateSelectionTranslationState(isEnabled: model.isSelectionTranslationEnabled)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "LumaBar.statusItem"
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "capsule.fill",
                accessibilityDescription: LumaBarL10n.appName
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = LumaBarL10n.appName
        }

        menuBuilder.target = self
        item.menu = menuBuilder.makeStatusMenu()
        statusItem = item
        menuBuilder.updateThemeState(model.theme)
        menuBuilder.updatePanelVisibility(isExpanded: model.isExpanded)
        menuBuilder.updateSelectionTranslationState(isEnabled: model.isSelectionTranslationEnabled)
    }

    @objc func quitFromMenu() {
        AppController.quitFromUserAction()
    }

    @objc func showAboutFromMenu() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Luma Bar Core Team"
        let alert = NSAlert()
        alert.messageText = LumaBarL10n.appName
        alert.informativeText = LumaBarL10n.aboutVersion(
            version: version,
            build: build,
            copyright: copyright
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: LumaBarL10n.aboutOK)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func showHelpFromMenu() {
        HelpGuidePresenter.show()
    }

    @objc func toggleMainPanelFromMenu() {
        handleMainPanelHotKey()
    }

    @objc func showPermissionSetupFromMenu() {
        showPermissionOnboarding()
    }

    private func rebuildLocalizedChrome() {
        buildMenu()
        if let statusItem {
            menuBuilder.target = self
            statusItem.menu = menuBuilder.makeStatusMenu()
            menuBuilder.updateThemeState(model.theme)
            menuBuilder.updatePanelVisibility(isExpanded: model.isExpanded)
            menuBuilder.updateSelectionTranslationState(isEnabled: model.isSelectionTranslationEnabled)
            statusItem.button?.toolTip = LumaBarL10n.appName
        }
        HelpGuidePresenter.reloadForLanguageChange()
        if permissionWindow != nil {
            permissionWindow?.title = LumaBarL10n.permissionWindowTitle
            let allowsAutoFinish = !PermissionOnboardingModel.hasCompletedSetup
            let onboardingModel = PermissionOnboardingModel(
                onFinished: { [weak self] in
                    self?.finishPermissionOnboarding()
                },
                allowsAutoFinish: allowsAutoFinish
            )
            onboardingModel.onPermissionBecameAuthorized = { [weak self] permission in
                self?.handlePermissionBecameAuthorized(permission)
            }
            onboardingModel.onSoftReminder = { [weak self] message in
                self?.model.requestDesktopPetMessage?(message)
            }
            permissionOnboardingModel = onboardingModel
            permissionWindow?.contentView = NSHostingView(
                rootView: PermissionOnboardingView(model: onboardingModel)
            )
        }
        model.refreshLocalizedChromeAfterLanguageChange()
        model.objectWillChange.send()
        relayoutExpandedPanelIfNeeded()
    }

    @objc private func handleAuraOpacityDidChange(_ notification: Notification) {
        model.objectWillChange.send()
        for window in [cameraWindow, leftWindow, rightWindow, expandedWindow] {
            window?.contentView?.needsDisplay = true
            window?.viewsNeedDisplay = true
        }
    }

    @objc func selectVoidTheme() {
        model.theme = .void
    }

    @objc func selectHorizonTheme() {
        model.theme = .horizon
    }

    @objc func selectForgeTheme() {
        model.theme = .forge
    }

    @objc func selectGridTheme() {
        model.theme = .grid
    }

    @objc func selectArcadeTheme() {
        model.theme = .arcade
    }

    @objc func selectNookTheme() {
        model.theme = .nook
    }

    @objc func selectAuraTheme() {
        model.theme = .aura
    }

    @objc private func openShellPromptFromMenu() {
        showAgentShellPrompt()
    }

    @objc private func openVoiceWhisperFromMenu() {
        toggleVoiceWhisper()
    }

    @objc private func testCursorCompletionFromMenu() {
        model.presentMultiTaskCompletionDemo()
    }

    @objc private func testContextLimitFromMenu() {
        model.presentContextLimitTestReaction()
    }

    private static let selectionTranslationConsentKey = "LumaBar.selectionTranslationConsented"

    @objc func toggleSelectionTranslation() {
        if !model.isSelectionTranslationEnabled,
           AppStoreDistribution.isAppStoreBuild,
           !UserDefaults.standard.bool(forKey: Self.selectionTranslationConsentKey) {
            // Copied text leaves the device for a third-party AI service; ask once before the first send.
            let alert = NSAlert()
            alert.messageText = LumaBarL10n.selectionTranslationConsentTitle
            alert.informativeText = LumaBarL10n.selectionTranslationConsentBody
            alert.alertStyle = .informational
            alert.addButton(withTitle: LumaBarL10n.selectionTranslationConsentAllow)
            alert.addButton(withTitle: LumaBarL10n.selectionTranslationConsentDecline)
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true, forKey: Self.selectionTranslationConsentKey)
        }
        model.isSelectionTranslationEnabled.toggle()
    }

    @objc private func requestAccessibilityAccessFromMenu() {
        AgentContextProvider.requestAccessibilityAccess()
    }

    #if LUMA_APP_STORE
    @objc func grantCursorFolderAccess() {
        let keys = SecurityScopedBookmarks.Key.allCases.filter {
            !SecurityScopedBookmarks.hasBookmark(for: $0)
        }
        var granted = false
        for key in keys {
            if SecurityScopedBookmarks.promptAndStore(for: key) != nil {
                granted = true
            }
        }
        if granted {
            model.requestDesktopPetMessage?("已授权数据目录。")
        }
    }
    #endif

    private func updateThemeMenuState(_ theme: IslandTheme) {
        menuBuilder.updateThemeState(theme)
    }

    private func showPermissionOnboarding() {
        if let permissionWindow {
            NSApp.activate(ignoringOtherApps: true)
            permissionWindow.makeKeyAndOrderFront(nil)
            permissionOnboardingModel?.refresh()
            return
        }

        // After first-run completion, keep the panel open until the user closes it —
        // never auto-dismiss when reopened from the menu.
        let allowsAutoFinish = !PermissionOnboardingModel.hasCompletedSetup
        let onboardingModel = PermissionOnboardingModel(
            onFinished: { [weak self] in
                self?.finishPermissionOnboarding()
            },
            allowsAutoFinish: allowsAutoFinish
        )
        onboardingModel.onPermissionBecameAuthorized = { [weak self] permission in
            self?.handlePermissionBecameAuthorized(permission)
        }
        onboardingModel.onSoftReminder = { [weak self] message in
            self?.model.requestDesktopPetMessage?(message)
        }
        let contentView = PermissionOnboardingView(model: onboardingModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = LumaBarL10n.permissionWindowTitle
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        permissionOnboardingModel = onboardingModel
        permissionWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finishPermissionOnboarding() {
        permissionWindow?.contentView = nil
        permissionWindow?.orderOut(nil)
        permissionWindow = nil
        permissionOnboardingModel = nil
        applyGrantedCapabilities(forceMusicScan: true, announce: true)
    }

    private func handlePermissionBecameAuthorized(_ permission: LumaBarPermission) {
        switch permission {
        case .accessibility:
            // Only the direct trigger depends on this grant; the clipboard trigger needs nothing.
            if AppStoreDistribution.allowsSelectionTranslation, AppStoreDistribution.readsSelectionDirectly {
                removeSelectionTranslationMonitor()
                installSelectionTranslationMonitor()
            }
            model.requestDesktopPetMessage?(LumaBarL10n.permissionAccessibilityGranted)
        case .automation:
            model.requestDesktopPetMessage?(LumaBarL10n.permissionAutomationGranted)
        case .screenRecording:
            model.requestDesktopPetMessage?(LumaBarL10n.permissionScreenGranted)
        }
    }

    /// Reload features that depend on TCC after the user grants them in System Settings.
    private func applyGrantedCapabilities(forceMusicScan: Bool, announce: Bool) {
        if forceMusicScan {
            model.scanLocalMusic()
        }

        #if !LUMA_APP_STORE
        if AppStoreDistribution.allowsSelectionTranslation, AXIsProcessTrusted() {
            removeSelectionTranslationMonitor()
            installSelectionTranslationMonitor()
        }
        #endif

        applyLayout()
        refreshInteractiveHitRegions()

        if announce {
            model.requestDesktopPetMessage?(LumaBarL10n.permissionUpdated)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissionOnboardingModel?.syncFromSystemSettings()
        // Users often toggle Accessibility / Screen Recording in Settings then return —
        // pick up the new TCC state and refresh content without requiring a relaunch.
        applyGrantedCapabilities(forceMusicScan: false, announce: false)
    }

}

