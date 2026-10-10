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

#if LUMA_APP_STORE
/// Reads the current NetEase song from the playback database the user grants once.
/// The store build cannot call the private Now Playing interface.
enum NetEasePlaybackStore {
    private final class Anchor: @unchecked Sendable {
        struct Sample {
            let position: TimeInterval
            /// False when the estimate cannot be trusted to name the line being sung.
            let isReliable: Bool
        }

        private var key = ""
        private var position: TimeInterval = 0
        private var date = Date()
        private var wasPlaying = false
        private let lock = NSLock()

        /// The database has no playhead, only the wall-clock moment each song started. Anchor on
        /// that and advance with the wall clock while audio runs. A fresh `startedAt` means the
        /// song was restarted — including a replay of the same song — so the anchor resets too.
        func sample(
            songID: String,
            startedAt: Date?,
            duration: TimeInterval,
            isPlaying: Bool
        ) -> Sample {
            lock.lock()
            defer { lock.unlock() }

            let now = Date()
            let incomingKey = "\(songID)|\(startedAt?.timeIntervalSince1970.rounded() ?? -1)"
            if incomingKey != key {
                key = incomingKey
                date = now
                wasPlaying = isPlaying
                guard let startedAt else {
                    position = 0
                    return Sample(position: 0, isReliable: false)
                }
                position = max(0, now.timeIntervalSince(startedAt))
            } else {
                if wasPlaying {
                    position += now.timeIntervalSince(date)
                }
                date = now
                wasPlaying = isPlaying
            }

            position = max(0, position)
            guard startedAt != nil else {
                return Sample(position: position, isReliable: false)
            }
            // Past the end of the track this row is stale: NetEase has moved on and not written
            // the new history entry yet, so the estimate says nothing about what is playing.
            if duration > 1, position > duration {
                return Sample(position: duration, isReliable: false)
            }
            return Sample(position: position, isReliable: true)
        }

        /// The history row only records when the song started. After a user seek, keep advancing
        /// from that point instead of snapping back to the original start time.
        func rebase(to position: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            self.position = max(0, position)
            date = Date()
            wasPlaying = true
        }
    }

    private static let anchor = Anchor()
    private static let identityLock = NSLock()
    nonisolated(unsafe) private static var songIDValue = ""
    nonisolated(unsafe) private static var coverURLValue: URL?

    static var currentSongID: String? {
        identityLock.lock()
        defer { identityLock.unlock() }
        return songIDValue.isEmpty ? nil : songIDValue
    }

    static var currentCoverURL: URL? {
        identityLock.lock()
        defer { identityLock.unlock() }
        return coverURLValue
    }

    static func rebaseEstimate(to position: TimeInterval) {
        anchor.rebase(to: position)
    }


    static func current(defaultArtist: String) -> NetEaseNowPlaying? {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: netEaseMusicBundleIdentifier
        ).contains { !$0.isTerminated }
        guard running else { return nil }
        guard let root = SecurityScopedBookmarks.retainedURL(for: .netEaseStorage),
              let databaseURL = databaseURL(in: root)
        else {
            return nil
        }
        return read(databaseURL, defaultArtist: defaultArtist)
    }

    private static func databaseURL(in granted: URL) -> URL? {
        let candidates = [
            granted.appendingPathComponent("sqlite_storage.sqlite3"),
            granted.appendingPathComponent("storage/sqlite_storage.sqlite3"),
            granted.appendingPathComponent("Documents/storage/sqlite_storage.sqlite3")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func read(_ url: URL, defaultArtist: String) -> NetEaseNowPlaying? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT CAST(
                   COALESCE(
                       NULLIF(json_extract(ht.jsonStr, '$.onlineTrackId'), ''),
                       NULLIF(json_extract(ht.jsonStr, '$.onlineTrack.id'), ''),
                       ht.id
                   ) AS TEXT
               ),
               IFNULL(json_extract(ht.jsonStr, '$.name'), ''),
               IFNULL(json_extract(ht.jsonStr, '$.album.name'), ''),
               IFNULL(json_extract(ht.jsonStr, '$.duration'), 0),
               IFNULL((
                   SELECT group_concat(json_extract(j.value, '$.name'), ' / ')
                   FROM json_each(IFNULL(json_extract(ht.jsonStr, '$.artists'), '[]')) AS j
               ), ''),
               IFNULL(json_extract(ht.jsonStr, '$.album.picUrl'), ''),
               IFNULL(json_extract(ht.jsonStr, '$.playtime'), 0)
        FROM historyTracks ht
        WHERE IFNULL(json_extract(ht.jsonStr, '$.playtime'), 0) > 0
        ORDER BY json_extract(ht.jsonStr, '$.playtime') DESC
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        func text(_ index: Int32) -> String {
            guard let raw = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: raw)
        }

        let songID = text(0)
        let title = text(1).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !songID.isEmpty, !title.isEmpty else { return nil }

        let artist = text(4).trimmingCharacters(in: .whitespacesAndNewlines)
        var duration = sqlite3_column_double(statement, 3)
        if duration > 1_000 {
            duration /= 1_000
        }
        let playing = NetEaseAudioActivity.isAudible
        let playtimeMs = sqlite3_column_double(statement, 6)
        // `playtime` is the wall-clock moment this song started — the only anchor available.
        let startedAt = playtimeMs > 1_000_000_000_000
            ? Date(timeIntervalSince1970: playtimeMs / 1000)
            : nil
        let sample = anchor.sample(
            songID: songID,
            startedAt: startedAt,
            duration: duration,
            isPlaying: playing
        )
        let cover = URL(string: text(5).trimmingCharacters(in: .whitespacesAndNewlines))
        identityLock.lock()
        songIDValue = songID
        coverURLValue = cover
        identityLock.unlock()

        return NetEaseNowPlaying(
            title: title,
            artist: artist.isEmpty ? defaultArtist : artist,
            album: text(2),
            artworkData: nil,
            position: sample.position,
            duration: max(0, duration),
            isPlaying: playing,
            positionIsReliable: sample.isReliable,
            songID: songID,
            coverURL: cover
        )
    }
}

final class NetEaseBridge: @unchecked Sendable {
    static let shared = NetEaseBridge()
    nonisolated(unsafe) private static var didAskForLibraryAccess = false
    nonisolated(unsafe) private static var didAskForMusicFolder = false

    /// Ask once for the folders a sandboxed build needs: storage (SQLite now-playing /
    /// playlists) and the music folder (ordinary downloads we can decode ourselves).
    /// Selecting the NetEase source asks again after a cancel.
    @MainActor
    func prepareLibraryAccess() {
        if !SecurityScopedBookmarks.hasBookmark(for: .netEaseStorage), !Self.didAskForLibraryAccess {
            Self.didAskForLibraryAccess = true
            _ = SecurityScopedBookmarks.promptAndStore(for: .netEaseStorage)
        }
        if !SecurityScopedBookmarks.hasBookmark(for: .musicLibrary), !Self.didAskForMusicFolder {
            Self.didAskForMusicFolder = true
            _ = SecurityScopedBookmarks.promptAndStore(for: .musicLibrary)
        }
    }

    @MainActor
    func resetLibraryAccessPrompt() {
        Self.didAskForLibraryAccess = false
        Self.didAskForMusicFolder = false
    }

    func fetchNowPlaying(completion: @escaping @Sendable (NetEaseNowPlaying?) -> Void) {
        fetchNowPlaying(
            allowedBundleIDs: [netEaseMusicBundleIdentifier],
            defaultArtist: "NetEase Cloud Music",
            completion: completion
        )
    }

    func fetchNowPlaying(
        allowedBundleIDs: Set<String>,
        defaultArtist: String,
        completion: @escaping @Sendable (NetEaseNowPlaying?) -> Void
    ) {
        _ = allowedBundleIDs
        guard SecurityScopedBookmarks.hasBookmark(for: .netEaseStorage) else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let nowPlaying = NetEasePlaybackStore.current(defaultArtist: defaultArtist)
            DispatchQueue.main.async {
                completion(nowPlaying)
            }
        }
    }

    @discardableResult
    func send(_ command: NetEaseRemoteCommand) -> Bool {
        if command == .seekToPlaybackPosition { return false }
        return NetEaseScripting.transport(command)
    }

    /// Pause only NetEase Cloud Music — never broadcast a global media key.
    @discardableResult
    func pauseNetEaseOnly() -> Bool {
        NetEaseScripting.transport(.pause)
    }

    /// Play only NetEase Cloud Music — never broadcast a global media key.
    @discardableResult
    func playNetEaseOnly() -> Bool {
        NetEaseScripting.transport(.play)
    }

    @discardableResult
    func seek(to position: TimeInterval) -> Bool {
        NetEaseScripting.seek(to: position)
    }

    @MainActor
    func openApplication(activates: Bool) {
        NetEaseScripting.openApplication(activates: activates)
    }

    @MainActor
    func openTrack(_ url: URL) {
        NetEaseScripting.openTrack(url)
    }

    @MainActor
    func openPlaylist(id: String) {
        NetEaseScripting.openPlaylist(id: id)
    }

    @MainActor
    func openSong(id: String) {
        NetEaseScripting.openSong(id: id)
    }
}
#else
typealias MediaRemoteDictionaryBlock = @convention(block) (CFDictionary?) -> Void
typealias MediaRemotePIDBlock = @convention(block) (Int32) -> Void
typealias MediaRemoteGetInfoFunction = @convention(c) (DispatchQueue, AnyObject) -> Void
typealias MediaRemoteGetPIDFunction = @convention(c) (DispatchQueue, AnyObject) -> Void
typealias MediaRemoteSendCommandFunction = @convention(c) (Int32, CFDictionary?) -> Bool
typealias MediaRemoteModernCommandCompletion = @convention(block) (AnyObject?) -> Void
typealias MediaRemoteModernSendCommandFunction = @convention(c) (
    AnyObject,
    Selector,
    UInt32,
    AnyObject?,
    DispatchQueue,
    AnyObject
) -> Void

final class NetEaseNowPlayingCompletionBox: @unchecked Sendable {
    let callback: (NetEaseNowPlaying?) -> Void

    init(_ callback: @escaping (NetEaseNowPlaying?) -> Void) {
        self.callback = callback
    }
}

final class NetEaseBridge: @unchecked Sendable {
    private static let bundleIdentifier = netEaseMusicBundleIdentifier

    static let shared = NetEaseBridge()

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let getNowPlayingInfo: MediaRemoteGetInfoFunction?
    private let getNowPlayingPID: MediaRemoteGetPIDFunction?
    private let sendRemoteCommand: MediaRemoteSendCommandFunction?
    private let fallbackQueue = DispatchQueue(label: "com.lumabar.app.media-fallback", qos: .userInitiated)
    private let fallbackLock = NSLock()
    private var isFallbackFetchInFlight = false

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        let handle = dlopen(path, RTLD_NOW)
        frameworkHandle = handle
        // Ensure Objective-C classes like MRNowPlayingRequest are registered.
        _ = Bundle(path: "/System/Library/PrivateFrameworks/MediaRemote.framework")?.load()

        if let handle, let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfo = unsafeBitCast(symbol, to: MediaRemoteGetInfoFunction.self)
        } else {
            getNowPlayingInfo = nil
        }

        if let handle, let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") {
            getNowPlayingPID = unsafeBitCast(symbol, to: MediaRemoteGetPIDFunction.self)
        } else {
            getNowPlayingPID = nil
        }

        if let handle, let symbol = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendRemoteCommand = unsafeBitCast(symbol, to: MediaRemoteSendCommandFunction.self)
        } else {
            sendRemoteCommand = nil
        }
    }

    func fetchNowPlaying(completion: @escaping (NetEaseNowPlaying?) -> Void) {
        fetchNowPlaying(
            allowedBundleIDs: [Self.bundleIdentifier],
            defaultArtist: "NetEase Cloud Music",
            completion: completion
        )
    }

    func fetchNowPlaying(
        allowedBundleIDs: Set<String>,
        defaultArtist: String,
        completion: @escaping (NetEaseNowPlaying?) -> Void
    ) {
        // Prefer in-process MediaRemote (includes artwork). JXA is metadata-only fallback.
        if let info = Self.modernNowPlayingInfo(allowedBundleIDs: allowedBundleIDs) {
            completion(Self.makeNowPlaying(from: info, defaultArtist: defaultArtist))
            return
        }

        if Self.requiresProcessFallback {
            fetchNowPlayingUsingJXA(
                allowedBundleIDs: allowedBundleIDs,
                defaultArtist: defaultArtist,
                completion: completion
            )
            return
        }

        guard let getNowPlayingPID, let getNowPlayingInfo else {
            completion(nil)
            return
        }

        let pidCallback: MediaRemotePIDBlock = { pid in
            guard
                pid > 0,
                let bundleID = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier,
                allowedBundleIDs.contains(bundleID)
            else {
                completion(nil)
                return
            }

            let infoCallback: MediaRemoteDictionaryBlock = { info in
                guard let dictionary = info as? [String: Any] else {
                    completion(nil)
                    return
                }
                completion(Self.makeNowPlaying(from: dictionary, defaultArtist: defaultArtist))
            }
            getNowPlayingInfo(.main, unsafeBitCast(infoCallback, to: AnyObject.self))
        }
        getNowPlayingPID(.main, unsafeBitCast(pidCallback, to: AnyObject.self))
    }

    private static var requiresProcessFallback: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion > 15
            || (version.majorVersion == 15 && version.minorVersion >= 4)
    }

    private func fetchNowPlayingUsingJXA(
        allowedBundleIDs: Set<String>,
        defaultArtist: String,
        completion: @escaping (NetEaseNowPlaying?) -> Void
    ) {
        fallbackLock.lock()
        guard !isFallbackFetchInFlight else {
            fallbackLock.unlock()
            return
        }
        isFallbackFetchInFlight = true
        fallbackLock.unlock()
        let completionBox = NetEaseNowPlayingCompletionBox(completion)

        fallbackQueue.async { [weak self] in
            let nowPlaying = Self.jxaNowPlayingInfo(
                allowedBundleIDs: allowedBundleIDs,
                defaultArtist: defaultArtist
            )

            guard let self else { return }
            self.fallbackLock.lock()
            self.isFallbackFetchInFlight = false
            self.fallbackLock.unlock()
            completionBox.callback(nowPlaying)
        }
    }

    private static func jxaNowPlayingInfo(
        allowedBundleIDs: Set<String>,
        defaultArtist: String
    ) -> NetEaseNowPlaying? {
        let source = #"""
        ObjC.import("Foundation");
        const bundle = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework");
        bundle.load;
        const request = $.NSClassFromString("MRNowPlayingRequest");
        const client = request.localNowPlayingPlayerPath.client;
        const info = request.localNowPlayingItem.nowPlayingInfo;
        function value(key) {
            const item = info.objectForKey(key);
            return item ? ObjC.unwrap(item) : null;
        }
        const date = info.objectForKey("kMRMediaRemoteNowPlayingInfoTimestamp");
        JSON.stringify({
            bundleId: client.bundleIdentifier ? ObjC.unwrap(client.bundleIdentifier) : null,
            displayName: client.displayName ? ObjC.unwrap(client.displayName) : null,
            title: value("kMRMediaRemoteNowPlayingInfoTitle"),
            artist: value("kMRMediaRemoteNowPlayingInfoArtist"),
            album: value("kMRMediaRemoteNowPlayingInfoAlbum"),
            duration: value("kMRMediaRemoteNowPlayingInfoDuration"),
            elapsedTime: value("kMRMediaRemoteNowPlayingInfoElapsedTime"),
            playbackRate: value("kMRMediaRemoteNowPlayingInfoPlaybackRate"),
            timestamp: date ? date.timeIntervalSince1970 : null
        });
        """#

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let payload = try? JSONDecoder().decode(NetEaseJXANowPlayingPayload.self, from: data),
                  let title = payload.title,
                  !title.isEmpty
            else {
                return nil
            }

            let bundleMatched = payload.bundleId.map { allowedBundleIDs.contains($0) } ?? false
            let display = payload.displayName?.lowercased() ?? ""
            let looksLikeNetEase =
                display.contains("netease")
                || display.contains("163")
                || display.contains("网易")
            let displayMatched =
                allowedBundleIDs.contains(netEaseMusicBundleIdentifier)
                && (looksLikeNetEase || display.contains("cloud music"))
            guard bundleMatched || displayMatched else { return nil }

            let duration = max(0, payload.duration ?? 0)
            let playbackRate = payload.playbackRate ?? 0
            let elapsedSinceUpdate = payload.timestamp.map {
                max(0, Date().timeIntervalSince1970 - $0)
            } ?? 0
            let rawPosition = max(0, payload.elapsedTime ?? 0)
            let position = min(
                duration > 0 ? duration : .greatestFiniteMagnitude,
                rawPosition + elapsedSinceUpdate * playbackRate
            )

            return NetEaseNowPlaying(
                title: title,
                artist: payload.artist ?? defaultArtist,
                album: payload.album ?? "",
                artworkData: nil,
                position: position,
                duration: duration,
                isPlaying: playbackRate > 0
            )
        } catch {
            return nil
        }
    }

    private static func modernNowPlayingInfo(allowedBundleIDs: Set<String>) -> [String: Any]? {
        guard let requestClass = NSClassFromString("MRNowPlayingRequest") as? NSObject.Type else {
            return nil
        }

        let playerPathSelector = NSSelectorFromString("localNowPlayingPlayerPath")
        guard requestClass.responds(to: playerPathSelector),
              let playerPath = requestClass.perform(playerPathSelector)?.takeUnretainedValue() as? NSObject,
              let client = objectValue(playerPath, selector: "client") as? NSObject
        else {
            return nil
        }

        let bundleID = objectValue(client, selector: "bundleIdentifier") as? String
        let parentBundleID = objectValue(client, selector: "parentApplicationBundleIdentifier") as? String
        let displayName = (objectValue(client, selector: "displayName") as? String)?.lowercased() ?? ""
        let looksLikeNetEase =
            displayName.contains("netease")
            || displayName.contains("163")
            || displayName.contains("网易")
        let bundleMatched =
            (bundleID.map { allowedBundleIDs.contains($0) } ?? false)
            || (parentBundleID.map { allowedBundleIDs.contains($0) } ?? false)
        let displayMatched =
            allowedBundleIDs.contains(netEaseMusicBundleIdentifier)
            && (looksLikeNetEase || displayName.contains("cloud music"))
        guard bundleMatched || displayMatched else {
            return nil
        }

        let itemSelector = NSSelectorFromString("localNowPlayingItem")
        guard requestClass.responds(to: itemSelector),
              let item = requestClass.perform(itemSelector)?.takeUnretainedValue() as? NSObject,
              let info = objectValue(item, selector: "nowPlayingInfo") as? [String: Any]
        else {
            return nil
        }

        return info
    }

    private static func objectValue(_ object: NSObject, selector: String) -> Any? {
        let selector = NSSelectorFromString(selector)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    @discardableResult
    func send(_ command: NetEaseRemoteCommand) -> Bool {
        // Never fall back to bare MRMediaRemoteSendCommand — that hits whichever
        // app currently owns system Now Playing (often Music.app), causing dual audio.
        switch command {
        case .pause:
            return pauseNetEaseOnly()
        case .play:
            return playNetEaseOnly()
        case .togglePlayPause:
            // AppleScript / Orpheus only — never MediaRemote toggle (broadcast risk).
            return runNetEaseAppleScript("playpause")
                || openOrpheusCommand(["cmd": "playpause"])
        case .nextTrack, .previousTrack, .seekToPlaybackPosition:
            return sendTargetedTransport(command)
        }
    }

    /// Pause only NetEase Cloud Music — never a global / Music.app media command.
    @discardableResult
    func pauseNetEaseOnly() -> Bool {
        // Prefer direct AppleScript pause (with timeout + playpause fallback) over MediaRemote —
        // playlist switches often leave MR Now Playing PID stale while NetEase keeps playing.
        if ExclusiveAudioFocus.pauseNetEase() {
            return true
        }
        if sendModernIfNetEase(command: .pause, options: nil) {
            return true
        }
        return openOrpheusCommand(["cmd": "pause"])
    }

    /// Play only NetEase Cloud Music — never a global media key broadcast.
    @discardableResult
    func playNetEaseOnly() -> Bool {
        if ExclusiveAudioFocus.playNetEase() {
            return true
        }
        if sendModernIfNetEase(command: .play, options: nil) {
            return true
        }
        return openOrpheusCommand(["cmd": "play"])
    }

    @discardableResult
    func seek(to position: TimeInterval) -> Bool {
        let dictionary = [
            "kMRMediaRemoteOptionPlaybackPosition": NSNumber(value: max(0, position))
        ] as NSDictionary
        let sentModern = sendModernIfNetEase(command: .seekToPlaybackPosition, options: dictionary)
        // MediaRemote often returns "sent" without moving the playhead. Also try NetEase's
        // public orpheus seek links, then a short AppleScript wait off the main thread.
        let seconds = String(format: "%.2f", max(0, position))
        let whole = String(Int(max(0, position)))
        if openOrpheusCommand(["cmd": "seek", "time": seconds])
            || openOrpheusCommand(["cmd": "seek", "position": seconds])
            || openOrpheusPath("seek/\(whole)")
        {
            return true
        }
        if runNetEaseAppleScript("set player position to \(seconds)") {
            return true
        }
        return sentModern
    }

    @discardableResult
    private func openOrpheusPath(_ path: String) -> Bool {
        guard let url = URL(string: "orpheus://\(path)") else { return false }
        openURLSilently(url)
        return true
    }

    private func sendTargetedTransport(_ command: NetEaseRemoteCommand) -> Bool {
        if sendModernIfNetEase(command: command, options: nil) {
            return true
        }
        switch command {
        case .nextTrack:
            return runNetEaseAppleScript("next track") || openOrpheusCommand(["cmd": "next"])
        case .previousTrack:
            return runNetEaseAppleScript("previous track") || openOrpheusCommand(["cmd": "prev"])
        case .togglePlayPause:
            return runNetEaseAppleScript("playpause")
                || openOrpheusCommand(["cmd": "playpause"])
        case .play:
            return playNetEaseOnly()
        case .pause:
            return pauseNetEaseOnly()
        case .seekToPlaybackPosition:
            return false
        }
    }

    /// MediaRemote only when the system Now Playing client is NetEase.
    private func sendModernIfNetEase(command: NetEaseRemoteCommand, options: NSDictionary?) -> Bool {
        guard let requestClass = NSClassFromString("MRNowPlayingRequest") as? NSObject.Type else {
            return false
        }

        let playerPathSelector = NSSelectorFromString("localNowPlayingPlayerPath")
        guard requestClass.responds(to: playerPathSelector),
              let playerPath = requestClass.perform(playerPathSelector)?.takeUnretainedValue() as? NSObject,
              let client = Self.objectValue(playerPath, selector: "client") as? NSObject
        else {
            return false
        }

        let bundleID = Self.objectValue(client, selector: "bundleIdentifier") as? String
        let parentBundleID = Self.objectValue(client, selector: "parentApplicationBundleIdentifier") as? String
        let displayName = (Self.objectValue(client, selector: "displayName") as? String)?.lowercased() ?? ""
        let isNetEase =
            bundleID == Self.bundleIdentifier
            || parentBundleID == Self.bundleIdentifier
            || displayName.contains("netease")
            || displayName.contains("163")
            || displayName.contains("网易")
        guard isNetEase else { return false }

        guard let allocated = requestClass.perform(NSSelectorFromString("alloc"))?.takeRetainedValue() as? NSObject,
              let request = allocated.perform(
                  NSSelectorFromString("initWithPlayerPath:"),
                  with: playerPath
              )?.takeUnretainedValue() as? NSObject
        else {
            return false
        }

        let selector = NSSelectorFromString("sendCommand:options:queue:completion:")
        guard request.responds(to: selector) else { return false }
        let sendCommand = unsafeBitCast(
            request.method(for: selector),
            to: MediaRemoteModernSendCommandFunction.self
        )
        let completion: MediaRemoteModernCommandCompletion = { [request] _ in
            _ = request
        }

        withExtendedLifetime(completion) {
            sendCommand(
                request,
                selector,
                UInt32(command.rawValue),
                options,
                .main,
                unsafeBitCast(completion, to: AnyObject.self)
            )
        }
        return true
    }

    @discardableResult
    private func runNetEaseAppleScript(_ command: String) -> Bool {
        // `launch` (not `activate`) keeps NetEase running without raising its windows.
        let timed = """
        using terms from application "NetEaseMusic"
          tell application id "\(Self.bundleIdentifier)"
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
        // Cap the wait so a wedged NetEase Apple Event cannot freeze the island.
        if ExclusiveAudioFocus.runAppleScript(timed, wallTimeout: 1.2) {
            return true
        }

        let fallback = """
        tell application id "\(Self.bundleIdentifier)"
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
        return ExclusiveAudioFocus.runAppleScript(fallback, wallTimeout: 1.2)
    }

    @discardableResult
    private func openOrpheusCommand(_ message: [String: String]) -> Bool {
        guard let url = Self.commandURL(message: message) else { return false }
        openURLSilently(url)
        return true
    }

    /// Open a NetEase URL / orpheus deep link without activating the app.
    private func openURLSilently(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: appURL,
                    configuration: configuration
                ) { _, _ in }
            }
        } else {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url, configuration: configuration) { _, _ in }
            }
        }
    }

    private func sendModern(command: NetEaseRemoteCommand, options: NSDictionary?) -> Bool {
        sendModernIfNetEase(command: command, options: options)
    }

    @MainActor
    func openApplication(activates: Bool) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }

    @MainActor
    func openTrack(_ url: URL) {
        // Background open only — never steal focus from Luma Bar / the frontmost app.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: configuration
            ) { _, _ in }
        } else {
            NSWorkspace.shared.open(url, configuration: configuration) { _, _ in }
        }
    }

    @MainActor
    func openPlaylist(id: String) {
        // Prefer a silent orpheus play-style command over openurl (openurl jumps the UI).
        let playMessages: [[String: String]] = [
            ["cmd": "play", "type": "playlist", "id": id],
            ["type": "playlist", "id": id, "cmd": "play"]
        ]
        var opened = false
        for message in playMessages {
            if let commandURL = Self.commandURL(message: message) {
                openURLSilently(commandURL)
                opened = true
            }
        }
        guard !opened else { return }

        guard let webURL = URL(string: "https://music.163.com/#/playlist?id=\(id)") else {
            openApplication(activates: false)
            return
        }
        openNetEaseWebURL(webURL)
    }

    /// Ask NetEase to play one song without raising its window.
    @MainActor
    func openSong(id: String) {
        if NetEaseScripting.playSong(id: id) { return }
        openApplication(activates: true)
    }

    private static func commandURL(message: [String: String]) -> URL? {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message)
        else {
            return nil
        }

        return URL(string: "orpheus://\(data.base64EncodedString())")
    }

    @MainActor
    private func openNetEaseWebURL(_ webURL: URL) {
        var components = URLComponents()
        components.scheme = "orpheus"
        components.host = "openurl"
        components.queryItems = [
            URLQueryItem(name: "url", value: webURL.absoluteString)
        ]

        if let url = components.url {
            openURLSilently(url)
        } else {
            openURLSilently(webURL)
        }
    }

    private static func makeNowPlaying(from info: [String: Any], defaultArtist: String = "NetEase Cloud Music") -> NetEaseNowPlaying? {
        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        guard !title.isEmpty else { return nil }

        let duration = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        let rawPosition = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let playbackRate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let timestamp = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date
        let elapsedSinceUpdate = timestamp.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        let position = min(duration > 0 ? duration : .greatestFiniteMagnitude, max(0, rawPosition + elapsedSinceUpdate * playbackRate))

        return NetEaseNowPlaying(
            title: title,
            artist: info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? defaultArtist,
            album: info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
            artworkData: info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
            position: position,
            duration: duration,
            isPlaying: playbackRate > 0
        )
    }
}
#endif


