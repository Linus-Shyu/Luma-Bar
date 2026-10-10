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

let netEaseMusicBundleIdentifier = "com.netease.163music"
let appleMusicBundleIdentifier = "com.apple.Music"

/// Bundle-ID targeted transport — never global NX_KEYTYPE broadcasts to whatever owns Now Playing.
enum ExclusiveAudioFocus {
    private static let scriptTimeoutSeconds = 1
    /// Wall-clock cap for hung NetEase AppleEvent handlers after playlist switches.
    private static let netEaseTier1WallTimeout: TimeInterval = 0.5

    /// Run AppleScript; returns false on compile/runtime failure.
    @discardableResult
    nonisolated static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else { return false }
        _ = appleScript.executeAndReturnError(&error)
        return error == nil
    }

    /// Run AppleScript but abandon the wait after `wallTimeout` if the AE handler is wedged.
    @discardableResult
    nonisolated static func runAppleScript(
        _ source: String,
        wallTimeout: TimeInterval
    ) -> Bool {
        let box = AppleScriptResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.success = runAppleScript(source)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + wallTimeout) == .timedOut {
            return false
        }
        return box.success
    }

    private final class AppleScriptResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _success = false
        var success: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _success
            }
            set {
                lock.lock()
                _success = newValue
                lock.unlock()
            }
        }
    }

    /// Synchronous AppleScript pause aimed at one app only.
    nonisolated static func pauseApplication(bundleIdentifier: String) {
        let script = """
        tell application id "\(bundleIdentifier)"
          with timeout of \(scriptTimeoutSeconds) seconds
            try
              pause
            end try
          end timeout
        end tell
        """
        _ = runAppleScript(script)
    }

    /// Synchronous AppleScript play aimed at one app only.
    nonisolated static func playApplication(bundleIdentifier: String) {
        let script = """
        tell application id "\(bundleIdentifier)"
          with timeout of \(scriptTimeoutSeconds) seconds
            try
              play
            end try
          end timeout
        end tell
        """
        _ = runAppleScript(script)
    }

    /// Synchronous AppleScript playpause aimed at one app only.
    nonisolated static func playPauseApplication(bundleIdentifier: String) {
        let script = """
        tell application id "\(bundleIdentifier)"
          with timeout of \(scriptTimeoutSeconds) seconds
            try
              playpause
            end try
          end timeout
        end tell
        """
        _ = runAppleScript(script)
    }

    nonisolated static func pauseAppleMusic() {
        pauseApplication(bundleIdentifier: appleMusicBundleIdentifier)
    }

    nonisolated static func playAppleMusic(knownTrack: Bool = false) {
        if knownTrack {
            // `exists current track` makes Music resolve the library object before `play`,
            // which is often several seconds. A bare play resumes the song we already show.
            let script = """
            tell application id "\(appleMusicBundleIdentifier)"
              try
                play
              end try
            end tell
            """
            _ = runAppleScript(script)
            return
        }
        // No mirrored track yet — avoid Music's empty-queue error dialog.
        if AppleMusicService.playCurrentTrackIfAvailable() {
            return
        }
        playApplication(bundleIdentifier: appleMusicBundleIdentifier)
    }

    nonisolated static func playPauseAppleMusic() {
        playPauseApplication(bundleIdentifier: appleMusicBundleIdentifier)
    }

    // MARK: - NetEase force transport (orpheus:// deep link → Controls menu, never activate)

    /// Pause NetEase without raising its window.
    /// - Important: the direct build's Space fallback **toggles**. If NetEase is already paused,
    ///   Space would *resume* it (ghost play), so only send it when the caller believes NetEase
    ///   is currently playing.
    @discardableResult
    nonisolated static func pauseNetEase(likelyPlaying: Bool = true) -> Bool {
#if LUMA_APP_STORE
        // `orpheus://` is the only transport NetEase exposes to a sandboxed app, and it needs
        // no entitlement, no permission grant, and never raises the NetEase window.
        // The command name is historical: the call sends both `pause` and `pausePlayer`.
        return NetEaseScripting.deepLinkTransport("pausePlayer")
#else
        if pauseNetEaseOnceViaAppleScript() {
            return true
        }
        if NetEaseScripting.deepLinkTransport("pausePlayer") {
            return true
        }
        guard likelyPlaying else { return false }
        return sendNetEaseSpaceKeyViaSystemEvents(bringToFront: false)
#endif
    }

    /// Play NetEase in the background — never activate / raise the NetEase window.
    @discardableResult
    nonisolated static func playNetEase() -> Bool {
#if LUMA_APP_STORE
        return NetEaseScripting.deepLinkTransport("resume")
#else
        if playNetEaseOnceViaAppleScript() {
            return true
        }
        if NetEaseScripting.deepLinkTransport("resume") {
            return true
        }
        // Last resort: Space into the NetEase process without making it frontmost.
        return sendNetEaseSpaceKeyViaSystemEvents(bringToFront: false)
#endif
    }

    /// Blocking exclusive handoff: silence every rival **before** the caller issues play.
    /// Must run off the main thread. No delays — pause completes (or times out) then returns.
    nonisolated static func silenceRivals(
        of target: IslandMusicLibrarySource,
        netEaseLikelyPlaying: Bool
    ) {
        switch target {
        case .appleMusic:
            pauseNetEase(likelyPlaying: netEaseLikelyPlaying)
        case .netEase:
            pauseAppleMusic()
        case .local:
            pauseAppleMusic()
            pauseNetEase(likelyPlaying: netEaseLikelyPlaying)
        }
    }

    @discardableResult
    nonisolated static func playPauseNetEase() -> Bool {
#if LUMA_APP_STORE
        // Resolve the direction first: pause and resume are separate deep links, and NetEase has
        // no toggle. Audible output is the only playback state a sandboxed app can observe.
        return NetEaseAudioActivity.isAudible ? pauseNetEase() : playNetEase()
#else
        // Avoid playpause dictionary — same server-side rejection as pause on some playlists.
        return sendNetEaseSpaceKeyViaSystemEvents(bringToFront: false)
#endif
    }

#if !LUMA_APP_STORE
    /// Single AppleScript pause — never `activate`; stay in background.
    /// NetEase ships no scripting dictionary, so this only ever succeeds on builds that may
    /// also fall back to key events. The store build does not send it at all.
    nonisolated private static func pauseNetEaseOnceViaAppleScript() -> Bool {
        let script = """
        try
          with timeout of 0.5 seconds
            tell application id "\(netEaseMusicBundleIdentifier)"
              if it is running then
                launch
                pause
              end if
            end tell
          end timeout
          return "ok"
        on error
          error "netease-pause-unsupported"
        end try
        """
        return runAppleScript(script, wallTimeout: netEaseTier1WallTimeout)
    }

    /// Single AppleScript play — `launch` keeps the app alive without raising its windows.
    nonisolated private static func playNetEaseOnceViaAppleScript() -> Bool {
        let script = """
        try
          with timeout of 0.5 seconds
            tell application id "\(netEaseMusicBundleIdentifier)"
              if it is running then
                launch
                play
              end if
            end tell
          end timeout
          return "ok"
        on error
          error "netease-play-unsupported"
        end try
        """
        return runAppleScript(script, wallTimeout: netEaseTier1WallTimeout)
    }
#endif

    /// Space into the NetEase process without activating it.
    /// Prefer `CGEvent.postToPid` so the key never requires `set frontmost to true`.
    @discardableResult
    nonisolated static func sendNetEaseSpaceKeyViaSystemEvents(bringToFront: Bool = false) -> Bool {
        // bringToFront is intentionally ignored — raising NetEase steals focus from Luma Bar.
        _ = bringToFront

        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: netEaseMusicBundleIdentifier
        )
        guard let app = apps.first(where: { !$0.isTerminated }) else {
            return false
        }

#if LUMA_APP_STORE
        // Sandbox: System Events is not in the Apple Events exception list and UI scripting
        // is out of scope for the store build. Only the direct NetEase AppleScript path runs.
        _ = app
        return false
#else
        // Best path: deliver Space directly to NetEase's PID (no activate / no frontmost).
        if postSpaceKey(to: app.processIdentifier) {
            return true
        }

        // Fallback: System Events key code without ever setting frontmost.
        let script = """
        try
          with timeout of 1 seconds
            tell application "System Events"
              set procs to every process whose bundle identifier is "\(netEaseMusicBundleIdentifier)"
              if (count of procs) > 0 then
                tell item 1 of procs
                  key code 49
                end tell
                return "ok"
              end if
              if exists process "NetEaseMusic" then
                tell process "NetEaseMusic"
                  key code 49
                end tell
                return "ok"
              end if
              if exists process "NeteaseMusic" then
                tell process "NeteaseMusic"
                  key code 49
                end tell
                return "ok"
              end if
            end tell
          end timeout
        on error
          error "space-key-failed"
        end try
        error "no-netease-process"
        """
        return runAppleScript(script, wallTimeout: 1.2)
#endif
    }

#if !LUMA_APP_STORE
    /// Post Space to a specific PID so NetEase can toggle playback without becoming frontmost.
    nonisolated private static func postSpaceKey(to pid: pid_t) -> Bool {
        let spaceKey: CGKeyCode = 49 // kVK_Space
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: spaceKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: spaceKey, keyDown: false)
        else {
            return false
        }
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }

    nonisolated private static func postSpaceKeyCGEvent() -> Bool {
        // Legacy global tap — only used if a caller still references it; prefer postToPid.
        let spaceKey: CGKeyCode = 49
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: spaceKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: spaceKey, keyDown: false)
        else {
            return false
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
#endif
}

enum NotchMetrics {
    static let compactHeight: CGFloat = 40
    static let compactLeftWidth: CGFloat = 148
    static let compactRightWidth: CGFloat = 134
    /// Wider bars for screens without notch safe areas (centered fallback layout):
    /// roomy enough for title + subtitle on the left and the transport on the right.
    static let compactFallbackLeftWidth: CGFloat = 250
    static let compactFallbackRightWidth: CGFloat = 220
    /// Spacing between the compact music controls — shared by the view and the
    /// hit-rect math so they can never drift apart.
    static let compactRightControlSpacing: CGFloat = 8
    static let notchEdgeOverlap: CGFloat = 10
    static let fallbackCameraGap: CGFloat = 72
    /// One expanded size for Music / System / Agent (room for a usable track list).
    static let expandedSize = NSSize(width: 460, height: 340)
    static let expandedMusicSize = expandedSize
    static let expandedSystemSize = expandedSize
    static let expandedAgentSize = expandedSize
    static let codexTokenExpandedSize = NSSize(width: 420, height: 118)
    static let kiroTokenExpandedSize = NSSize(width: 420, height: 168)
    static let expandedCornerRadius: CGFloat = 18
    static let codexTokenCornerRadius: CGFloat = 26
    static let expandedTopInset: CGFloat = 52
    static let expandedVisualOffsetX: CGFloat = 0
    /// Matches MusicExpandedView header: pad + row height used for hit testing.
    static let expandedHeaderPadding: CGFloat = 10
    static let expandedHeaderRowHeight: CGFloat = 34
    static let expandedCollapseButton: CGFloat = 28
    static let expandedModePillWidth: CGFloat = 30
    static let expandedModePillSpacing: CGFloat = 4
    /// Breathing room kept between the island and the nearest menu-bar icon.
    static let statusItemClearance: CGFloat = 8
    /// Floors for the centered avoidance shrink: below these the compact row
    /// can no longer show artwork on the left or the transport on the right.
    static let compactLeftMinWidth: CGFloat = 96
    static let compactRightMinWidth: CGFloat = 96
    static let compactGapMinWidth: CGFloat = 28
}

/// Menu-bar status items live at window layer 25 — the same layer the island
/// sits on — so the island silently covers other apps' icons. Probing their
/// leftmost edge lets the compact layout stay centered and shrink instead.
enum MenuBarStatusItemProbe {
    private static let statusItemLayer = 25
    /// Widest plausible single status item; anything larger is a full-width
    /// menu-bar backdrop rather than an icon.
    private static let maxItemWidth: CGFloat = 400
    private static let maxItemHeight: CGFloat = 40
    private static let minInterval: TimeInterval = 1.0

    private nonisolated(unsafe) static var cache: [CGDirectDisplayID: (edge: CGFloat?, at: Date)] = [:]

    /// Leftmost edge of foreign status items on `screen`, in AppKit screen
    /// coordinates. `nil` when the screen currently shows no status items.
    static func leftEdge(on screen: NSScreen) -> CGFloat? {
        let displayID = screen.displayID
        let now = Date()
        if let cached = cache[displayID], now.timeIntervalSince(cached.at) < minInterval {
            return cached.edge
        }
        let edge = probeLeftEdge(on: screen)
        cache[displayID] = (edge, now)
        return edge
    }

    static func invalidate() {
        cache.removeAll()
    }

    private static func probeLeftEdge(on screen: NSScreen) -> CGFloat? {
        guard
            let infos = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]],
            let primaryTop = NSScreen.screens.first?.frame.maxY
        else {
            return nil
        }

        // CoreGraphics uses a top-left origin anchored at the primary display.
        let bandTop = primaryTop - screen.frame.maxY
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        var leftMost: CGFloat?

        for info in infos {
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == statusItemLayer,
                let pid = info[kCGWindowOwnerPID as String] as? Int,
                pid != ownPID,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else {
                continue
            }
            let originX = bounds["X"] ?? 0
            let originY = bounds["Y"] ?? 0
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            guard width > 0, width <= maxItemWidth, height > 0, height <= maxItemHeight else { continue }
            guard abs(originY - bandTop) <= 2 else { continue }
            let midX = originX + width / 2
            guard midX >= screen.frame.minX, midX <= screen.frame.maxX else { continue }
            leftMost = min(leftMost ?? .greatestFiniteMagnitude, originX)
        }

        return leftMost
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }
}

@MainActor
enum AppController {
    static func quitFromUserAction() {
        stopKeepAliveForCurrentSession()
        NSApp.terminate(nil)
    }

    private static func stopKeepAliveForCurrentSession() {
#if LUMA_APP_STORE
        return
#else
        let label = "com.lumabar.app.keepalive"
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "bootout",
            "gui/\(getuid())",
            plist.path
        ]
        try? process.run()
        process.waitUntilExit()
    #endif
    }
}
