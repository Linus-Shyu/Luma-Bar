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

struct TimedLyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    let text: String
}

struct LyricParseResult {
    let text: String
    let timedLines: [TimedLyricLine]
}

enum TrackPlaybackSource: Hashable {
    case direct
    case netEase
    case netEaseSong(id: String)
    case appleMusic

    var isNetEaseBacked: Bool {
        switch self {
        case .netEase, .netEaseSong:
            return true
        case .direct, .appleMusic:
            return false
        }
    }
}

enum IslandMusicLibrarySource: String, CaseIterable, Identifiable {
    case local
    case appleMusic
    case netEase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return LumaBarL10n.libraryLocal
        case .appleMusic: return LumaBarL10n.libraryAppleMusic
        case .netEase: return LumaBarL10n.libraryNetEase
        }
    }
}

struct NetEaseNowPlaying: Equatable {
    let title: String
    let artist: String
    let album: String
    var artworkData: Data?
    var position: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool
    /// False when `position` is an estimate rather than a reported playhead. NetEase exposes no
    /// playhead to the store build, so lyrics must not highlight a line that is probably wrong.
    var positionIsReliable: Bool = true
    /// Song id and cover from the same read. A later read must not lend its cover to this title.
    var songID: String = ""
    var coverURL: URL? = nil

    func with(position: TimeInterval) -> NetEaseNowPlaying {
        var copy = self
        copy.position = position
        return copy
    }

    func with(isPlaying: Bool) -> NetEaseNowPlaying {
        var copy = self
        copy.isPlaying = isPlaying
        return copy
    }

    func with(duration: TimeInterval) -> NetEaseNowPlaying {
        var copy = self
        copy.duration = duration
        return copy
    }

    func withArtworkData(_ data: Data) -> NetEaseNowPlaying {
        var copy = self
        copy.artworkData = data
        return copy
    }
}

#if !LUMA_APP_STORE
struct NetEaseJXANowPlayingPayload: Decodable, Sendable {
    let bundleId: String?
    let displayName: String?
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let playbackRate: Double?
    let timestamp: Double?
}
#endif


struct NetEasePlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let coverURL: URL?
    let coverData: Data?
    let trackCount: Int
    let playtime: Int64

    var countText: String {
        trackCount > 0 ? "\(trackCount) songs" : "Playlist"
    }

    func withCoverData(_ data: Data) -> NetEasePlaylist {
        NetEasePlaylist(
            id: id,
            name: name,
            coverURL: coverURL,
            coverData: data,
            trackCount: trackCount,
            playtime: playtime
        )
    }
}

enum NetEaseRemoteCommand: Int32 {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
    case seekToPlaybackPosition = 24
}

#if !LUMA_APP_STORE
/// Presses NetEase's own Controls menu through the public Accessibility API.
/// Play, Pause, Next, and Previous are real menu items. There is no seek item.
///
/// Direct build only: under App Sandbox every cross-application Accessibility call fails with
/// `kAXErrorCannotComplete` (-25204), even though `AXIsProcessTrusted()` still reports true, so none of this
/// can work in the store build.
enum NetEaseMenuControl {
    enum Command {
        case play
        case pause
        case toggle
        case next
        case previous
    }

    private static let playTitles: Set<String> = ["Play", "播放"]
    private static let pauseTitles: Set<String> = ["Pause", "暂停"]
    private static let nextTitles: Set<String> = ["Next", "下一个"]
    private static let previousTitles: Set<String> = ["Previous", "上一个"]
    private static let menuTitles: Set<String> = ["Controls", "控制"]

    @discardableResult
    static func perform(_ command: Command) -> Bool {
        let work = { performOnThisThread(command) }
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    private static func performOnThisThread(_ command: Command) -> Bool {
        let trusted = accessibilityIsTrusted()
        NSLog("LumaBar NetEase control trusted=\(trusted) command=\(String(describing: command))")
        guard trusted else { return false }
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: netEaseMusicBundleIdentifier
        )
        guard let pid = apps.first(where: { !$0.isTerminated })?.processIdentifier else {
            return false
        }
        let application = AXUIElementCreateApplication(pid)
        guard let menuBar = copyElement(application, kAXMenuBarAttribute) else {
            NSLog("LumaBar NetEase control missing menu bar")
            return false
        }
        guard let menuItem = controlMenuItem(in: menuBar, matching: command) else {
            NSLog("LumaBar NetEase control missing menu item")
            return false
        }
        let title = copyString(menuItem, kAXTitleAttribute)
        switch command {
        case .play:
            // Menu title is the transport state. CoreAudio keeps reporting audible
            // for about a second after pause, and treating that as "already playing"
            // swallows a real Play press.
            if pauseTitles.contains(title) {
                return true
            }
        case .pause:
            if playTitles.contains(title) {
                return true
            }
        case .toggle:
            break
        case .next, .previous:
            // Next / Previous reach no target while NetEase is in the background: the press
            // reports success and the song never changes. Opening the menu does not help
            // either, so these two go through `skip`, which activates NetEase for one frame.
            return pressItemInOpenMenu(application: application, command: command)
        }
        let result = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
        NSLog("LumaBar NetEase control press \(result.rawValue) title=\(title)")
        return result == .success
    }

    /// True when the Controls menu says Pause. Nil when the menu cannot be read.
    static func menuSaysPlaying() -> Bool? {
        let read = { menuSaysPlayingOnThisThread() }
        if Thread.isMainThread {
            return read()
        }
        return DispatchQueue.main.sync(execute: read)
    }

    private static func menuSaysPlayingOnThisThread() -> Bool? {
        guard accessibilityIsTrusted() else { return nil }
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: netEaseMusicBundleIdentifier
        )
        guard let pid = apps.first(where: { !$0.isTerminated })?.processIdentifier else {
            return nil
        }
        let application = AXUIElementCreateApplication(pid)
        guard let menuBar = copyElement(application, kAXMenuBarAttribute),
              let menuItem = controlMenuItem(in: menuBar, matching: .toggle)
        else {
            return nil
        }
        let title = copyString(menuItem, kAXTitleAttribute)
        if pauseTitles.contains(title) { return true }
        if playTitles.contains(title) { return false }
        return nil
    }

    /// Skip a track. The Controls menu only delivers Next / Previous to a target while NetEase
    /// is the active app, so activate it for one frame and hand focus straight back.
    @discardableResult
    static func skip(_ command: Command) -> Bool {
        let work = { skipOnMainThread(command) }
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    private static func skipOnMainThread(_ command: Command) -> Bool {
        guard command == .next || command == .previous else { return false }
        guard accessibilityIsTrusted(), let netEase = runningNetEase() else { return false }

        let previous = NSWorkspace.shared.frontmostApplication
        let wasHidden = netEase.isHidden
        netEase.activate()

        // The item is wired up once the activation lands — a frame is enough in practice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let pressed = pressControlItem(command, in: netEase)
            NSLog("LumaBar NetEase skip \(String(describing: command)) pressed=\(pressed)")
            returnFocus(to: previous, netEase: netEase, reHide: wasHidden)
        }
        return true
    }

    private static func pressControlItem(_ command: Command, in app: NSRunningApplication) -> Bool {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = copyElement(application, kAXMenuBarAttribute),
              let item = controlMenuItem(in: menuBar, matching: command)
        else {
            return false
        }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// NetEase raises itself again a few hundred ms after being activated, so hand focus back
    /// on a short bounded watchdog instead of a single call. It settles within ~0.7s.
    private static func returnFocus(
        to previous: NSRunningApplication?,
        netEase: NSRunningApplication,
        reHide: Bool
    ) {
        handBackFocus(to: previous, netEase: netEase, reHide: reHide)
        watchFocus(previous: previous, netEase: netEase, reHide: reHide, attemptsLeft: 14)
    }

    private static func handBackFocus(
        to previous: NSRunningApplication?,
        netEase: NSRunningApplication,
        reHide: Bool
    ) {
        if reHide, !netEase.isHidden {
            netEase.hide()
        }
        previous?.activate()
    }

    private static func watchFocus(
        previous: NSRunningApplication?,
        netEase: NSRunningApplication,
        reHide: Bool,
        attemptsLeft: Int
    ) {
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if netEase.isActive {
                handBackFocus(to: previous, netEase: netEase, reHide: reHide)
            }
            watchFocus(
                previous: previous,
                netEase: netEase,
                reHide: reHide,
                attemptsLeft: attemptsLeft - 1
            )
        }
    }

    private static func runningNetEase() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: netEaseMusicBundleIdentifier
        ).first { !$0.isTerminated }
    }

    private static func pressItemInOpenMenu(application: AXUIElement, command: Command) -> Bool {
        guard let menuBar = copyElement(application, kAXMenuBarAttribute),
              let barItem = copyChildren(menuBar).first(where: {
                  menuTitles.contains(copyString($0, kAXTitleAttribute))
              })
        else {
            return false
        }
        guard AXUIElementPerformAction(barItem, kAXPressAction as CFString) == .success else {
            return false
        }
        let openedAt = Date()
        while Date().timeIntervalSince(openedAt) < 0.22 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.04))
        }
        guard let freshBar = copyElement(application, kAXMenuBarAttribute),
              let item = controlMenuItem(in: freshBar, matching: command)
        else {
            return false
        }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private static nonisolated(unsafe) var didPromptForAccessibility = false

    /// `AXIsProcessTrusted` stays false until the prompt-style check refreshes it,
    /// even after the user has already allowed this copy. That check's result is the one to use.
    private static func accessibilityIsTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        let quiet = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        if AXIsProcessTrustedWithOptions(quiet) { return true }
        guard !didPromptForAccessibility else { return false }
        didPromptForAccessibility = true
        let prompting = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompting) { return true }
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            if Thread.isMainThread {
                NSWorkspace.shared.open(url)
            } else {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        return false
    }

    private static func controlMenuItem(in menuBar: AXUIElement, matching command: Command) -> AXUIElement? {
        let wanted: Set<String>
        switch command {
        case .play, .pause, .toggle:
            wanted = playTitles.union(pauseTitles)
        case .next:
            wanted = nextTitles
        case .previous:
            wanted = previousTitles
        }
        for barItem in copyChildren(menuBar) where menuTitles.contains(copyString(barItem, kAXTitleAttribute)) {
            for menu in copyChildren(barItem) {
                for item in copyChildren(menu) where wanted.contains(copyString(item, kAXTitleAttribute)) {
                    return item
                }
            }
        }
        return nil
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }
}
#endif

/// NetEase controls that stay inside the public `orpheus://` URL scheme and Accessibility.
/// Both builds use this. The direct build may still prefer MediaRemote first.
enum NetEaseScripting {
#if !LUMA_APP_STORE
    /// NetEase ships no scripting dictionary, so this never succeeds. It stays out of the store
    /// build entirely: that binary sends no Apple event to NetEase at all.
    @discardableResult
    static func run(_ command: String) -> Bool {
        let timed = """
        using terms from application "NetEaseMusic"
          tell application id "\(netEaseMusicBundleIdentifier)"
            with timeout of 1 seconds
              try
                if it is running then
                  launch
                  \(command)
                  return "ok"
                end if
              end try
            end timeout
          end tell
        end using terms
        """
        if ExclusiveAudioFocus.runAppleScript(timed) {
            return true
        }
        let fallback = """
        tell application id "\(netEaseMusicBundleIdentifier)"
          with timeout of 1 seconds
            try
              if it is running then
                launch
                \(command)
                return "ok"
              end if
            end try
          end timeout
        end tell
        """
        return ExclusiveAudioFocus.runAppleScript(fallback)
    }
#endif

    @discardableResult
    static func openCommand(_ message: [String: String]) -> Bool {
        guard let url = commandURL(message: message) else { return false }
        openURLSilently(url)
        return true
    }

    static var isRunning: Bool {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: netEaseMusicBundleIdentifier
        ).contains { !$0.isTerminated }
    }

    /// Bumps whenever play or pause is requested, so a delayed retry cannot undo the later press.
    private static let transportLock = NSLock()
    nonisolated(unsafe) private static var transportGeneration = 0

    private static func nextTransportGeneration() -> Int {
        transportLock.lock()
        defer { transportLock.unlock() }
        transportGeneration += 1
        return transportGeneration
    }

    private static func transportGenerationMatches(_ generation: Int) -> Bool {
        transportLock.lock()
        defer { transportLock.unlock() }
        return transportGeneration == generation
    }

    /// Transport over the public `orpheus://` scheme. There is no track-skip command.
    /// These URLs need no entitlement and no Accessibility grant, and they never raise the window.
    ///
    /// Pausing sends both `pause` and `pausePlayer`. NetEase 3.1.12 honors only one of them:
    /// a song already playing in the NetEase window ignores `pausePlayer`, and a song started
    /// through `play` / `resume` ignores `pause`. Neither command resumes a paused player.
    @discardableResult
    static func deepLinkTransport(_ command: String) -> Bool {
        // Pausing an app that is not running would launch it. Play and resume may launch it.
        if command == "pausePlayer", !isRunning { return false }
        switch command {
        case "pausePlayer":
            let generation = nextTransportGeneration()
            let sent = deliverPauseCommands()
            // One URL is sometimes dropped. A second pair is a no-op once audio has already stopped.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                guard transportGenerationMatches(generation) else { return }
                guard isRunning, NetEaseAudioActivity.isAudible else { return }
                _ = deliverPauseCommands()
            }
            return sent
        case "resume":
            let generation = nextTransportGeneration()
            let sent = deliverResumeCommand()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) {
                guard transportGenerationMatches(generation) else { return }
                guard isRunning, !NetEaseAudioActivity.isAudible else { return }
                _ = deliverResumeCommand()
            }
            return sent
        default:
            return openCommand(["cmd": command])
        }
    }

    /// Written out in full. A release build can drop the short `{"cmd":"resume"}` literal, and
    /// then the second press of the pause button never reaches NetEase.
    private static func deliverResumeCommand() -> Bool {
        openPayloadURL("orpheus://eyJjbWQiOiJyZXN1bWUifQ==")
    }

    /// `pause` first: that is the verb the open NetEase window applies to a song it already started.
    /// The URLs are written out in full. A release build drops the 15-character `{"cmd":"pause"}`
    /// literal, so constructing it at runtime never reached the binary.
    private static func deliverPauseCommands() -> Bool {
        let pause = openPayloadURL("orpheus://eyJjbWQiOiJwYXVzZSJ9")
        let player = openPayloadURL("orpheus://eyJjbWQiOiJwYXVzZVBsYXllciJ9")
        return pause || player
    }

    private static func openPayloadURL(_ absolute: String) -> Bool {
        guard let url = URL(string: absolute) else { return false }
        openURLSilently(url)
        return true
    }

    /// Fixed text, not a dictionary. Release optimization was dropping the short command word,
    /// and NetEase also ignores the same JSON when its keys get reordered.
    private static func openPayload(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
              let url = URL(string: "orpheus://\(data.base64EncodedString())")
        else {
            return false
        }
        openURLSilently(url)
        return true
    }

    /// Start one song. NetEase 3.1.12 ignores `orpheus://song/<id>` and ignores this JSON when the
    /// keys are reordered, so the payload is a fixed string: `{"cmd":"play","type":"song","id"}`.
    /// The history row that confirms the switch lands a few seconds later.
    @discardableResult
    static func playSong(id: String) -> Bool {
        let songID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !songID.isEmpty, songID.allSatisfy(\.isNumber) else { return false }
        let payload = #"{"cmd":"play","type":"song","id":"\#(songID)"}"#
        guard let data = payload.data(using: .utf8),
              let url = URL(string: "orpheus://\(data.base64EncodedString())")
        else {
            return false
        }
        // A pause retry still pending from before this song would stop it a couple of seconds in.
        _ = nextTransportGeneration()
        openURLSilently(url)
        return true
    }

    static func commandURL(message: [String: String]) -> URL? {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message)
        else {
            return nil
        }
        return URL(string: "orpheus://\(data.base64EncodedString())")
    }

    @discardableResult
    static func openPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, let url = URL(string: "orpheus://\(trimmed)") else { return false }
        openURLSilently(url)
        return true
    }

    static func openURLSilently(_ url: URL) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { openURLOnMainThread(url) }
        } else {
            DispatchQueue.main.async { openURLOnMainThread(url) }
        }
    }

    @MainActor
    private static func openURLOnMainThread(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: netEaseMusicBundleIdentifier) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, _ in }
        } else {
            NSWorkspace.shared.open(url, configuration: configuration) { _, _ in }
        }
    }

    @MainActor
    static func openApplication(activates: Bool) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: netEaseMusicBundleIdentifier) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }

    @MainActor
    static func openTrack(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: netEaseMusicBundleIdentifier) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, _ in }
        } else {
            NSWorkspace.shared.open(url, configuration: configuration) { _, _ in }
        }
    }

    @MainActor
    static func openPlaylist(id: String) {
        if openPath("playlist/\(id)") { return }
        let playMessages: [[String: String]] = [
            ["cmd": "play", "type": "playlist", "id": id],
            ["type": "playlist", "id": id, "cmd": "play"]
        ]
        var opened = false
        for message in playMessages where openCommand(message) {
            opened = true
        }
        guard !opened else { return }
        guard let webURL = URL(string: "https://music.163.com/#/playlist?id=\(id)") else {
            openApplication(activates: false)
            return
        }
        openWebURL(webURL)
    }

    /// Ask NetEase to play one song without raising its window.
    @MainActor
    static func openSong(id: String) {
        if playSong(id: id) { return }
        openApplication(activates: true)
    }

    @MainActor
    private static func openWebURL(_ webURL: URL) {
        var components = URLComponents()
        components.scheme = "orpheus"
        components.host = "openurl"
        components.queryItems = [URLQueryItem(name: "url", value: webURL.absoluteString)]
        if let url = components.url {
            openURLSilently(url)
        } else {
            openURLSilently(webURL)
        }
    }

    @discardableResult
    static func transport(_ command: NetEaseRemoteCommand) -> Bool {
        switch command {
        case .pause:
            return ExclusiveAudioFocus.pauseNetEase()
        case .play:
            return ExclusiveAudioFocus.playNetEase()
        case .togglePlayPause:
#if LUMA_APP_STORE
            return ExclusiveAudioFocus.playPauseNetEase()
#else
            return ExclusiveAudioFocus.playPauseNetEase() || run("playpause")
#endif
        case .nextTrack:
#if LUMA_APP_STORE
            // NetEase has no next command. The caller plays the next song id from the list on screen.
            return false
#else
            // A background press reports success and skips nothing, so the direct build takes
            // the momentary-activation path. NetEase has no scripting dictionary either.
            return NetEaseMenuControl.skip(.next)
#endif
        case .previousTrack:
#if LUMA_APP_STORE
            return false
#else
            return NetEaseMenuControl.skip(.previous)
#endif
        case .seekToPlaybackPosition:
            return false
        }
    }

    @discardableResult
    static func seek(to position: TimeInterval) -> Bool {
#if LUMA_APP_STORE
        // NetEase publishes no seek command. Sending one would move the on-screen bar
        // while the song stays put.
        _ = position
        return false
#else
        let seconds = String(format: "%.2f", max(0, position))
        let whole = String(Int(max(0, position)))
        return run("set player position to \(seconds)")
            || openCommand(["cmd": "seek", "time": seconds])
            || openCommand(["cmd": "seek", "position": seconds])
            || openPath("seek/\(whole)")
#endif
    }
}

/// Keeps a security-scoped NetEase folder open for the lifetime of a SQLite read.
final class NetEaseDatabaseSession {
    let url: URL
    private let stopAccess: () -> Void

    private init(url: URL, stopAccess: @escaping () -> Void) {
        self.url = url
        self.stopAccess = stopAccess
    }

    deinit {
        stopAccess()
    }

    static func open(home: URL) -> NetEaseDatabaseSession? {
#if LUMA_APP_STORE
        _ = home
        // Keep the security scope for the process lifetime. Stopping it on session
        // deinit makes later playlist / now-playing reads fail in the sandbox.
        guard let root = SecurityScopedBookmarks.retainedURL(for: .netEaseStorage) else { return nil }
        let candidates = [
            root.appendingPathComponent("sqlite_storage.sqlite3"),
            root.appendingPathComponent("storage").appendingPathComponent("sqlite_storage.sqlite3"),
            root.appendingPathComponent("Documents").appendingPathComponent("storage").appendingPathComponent("sqlite_storage.sqlite3")
        ]
        guard let database = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }
        return NetEaseDatabaseSession(url: database) {}
#else
        let candidates = [
            home.appendingPathComponent("Library/Application Support/com.netease.163music/Documents/storage/sqlite_storage.sqlite3"),
            home.appendingPathComponent("Library/Containers/com.netease.163music/Data/Documents/storage/sqlite_storage.sqlite3")
        ]
        guard let database = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }
        return NetEaseDatabaseSession(url: database) {}
#endif
    }
}


/// Whether NetEase is currently putting audio out, read from the public CoreAudio process list.
/// NetEase publishes no play/pause flag, and a sandboxed app cannot read its Controls menu, so
/// this is the only playback state the store build can observe. It lags a pause by about a second.
enum NetEaseAudioActivity {
    static var isAudible: Bool {
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: netEaseMusicBundleIdentifier
        )
        guard let pid = apps.first(where: { !$0.isTerminated })?.processIdentifier else {
            return false
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return true
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return true
        }
        for id in ids {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var found: UInt32 = 0
            var propertySize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &propertySize, &found) == noErr,
                  found == UInt32(pid)
            else {
                continue
            }
            pidAddress.mSelector = kAudioProcessPropertyIsRunning
            var running: UInt32 = 0
            propertySize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &propertySize, &running) == noErr else {
                return true
            }
            return running == 1
        }
        return false
    }
}

