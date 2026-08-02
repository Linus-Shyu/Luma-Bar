import AppKit
import Foundation

private let appleMusicBundleIdentifier = "com.apple.Music"
private let appleMusicPlayerInfoNotification = Notification.Name("com.apple.Music.playerInfo")

/// Explicit Music.app transport state — Play/Pause UI binds to this, not local click toggles.
enum AppleMusicPlayerState: Equatable, Sendable {
    case playing
    case paused
    case stopped
}

/// Controls and mirrors Apple Music (Music.app) for the island widget.
@MainActor
final class AppleMusicService: MusicServiceProtocol {
    static let shared = AppleMusicService()

    private(set) var currentTrack: MusicNowPlayingInfo?
    /// Live binding of Music.app `player state` — source of truth for the Play/Pause icon.
    private(set) var playerState: AppleMusicPlayerState = .stopped
    private var onChange: (@MainActor () -> Void)?
    private var playerInfoObserver: NSObjectProtocol?
    private var isRefreshing = false
    private var lastRefreshDate = Date.distantPast
    private var pendingSeekExpiresAt = Date.distantPast
    private var artworkEnrichmentToken = UUID()
    private var artworkInflightKey = ""
    private var artworkResolvedKey = ""
    /// Timestamp-interpolated playhead — UI reads this instead of raw poll positions.
    private var progressClock = PlaybackProgressClock()
    /// Last non-zero position for the current track — survives pause notifications that report 0.
    private var lastValidPlaybackTime: TimeInterval = 0
    private var lastValidTrackKey = ""

    var isPlaying: Bool { playerState == .playing }
    var playbackTime: TimeInterval {
        let interpolated = progressClock.calculatedCurrentTime()
        if interpolated > 0.05 { return interpolated }
        if !progressClock.isPlaying, lastValidPlaybackTime > 0.05 {
            return lastValidPlaybackTime
        }
        return interpolated
    }
    var duration: TimeInterval { currentTrack?.duration ?? progressClock.duration }

    private init() {}

    func startMonitoring(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard playerInfoObserver == nil else { return }

        playerInfoObserver = DistributedNotificationCenter.default().addObserver(
            forName: appleMusicPlayerInfoNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let parsed = Self.nowPlaying(fromPlayerInfo: notification.userInfo)
            Task { @MainActor in
                self?.handleParsedPlayerInfo(parsed)
            }
        }

        refresh(completion: nil)
    }

    func stopMonitoring() {
        if let playerInfoObserver {
            DistributedNotificationCenter.default().removeObserver(playerInfoObserver)
            self.playerInfoObserver = nil
        }
        onChange = nil
    }

    func play() {
        if var track = currentTrack {
            if progressClock.cachedPosition <= 0.05, lastValidPlaybackTime > 0.05 {
                progressClock.seek(to: lastValidPlaybackTime)
            }
            progressClock.resumePlayback()
            track.isPlaying = true
            track.position = progressClock.calculatedCurrentTime()
            currentTrack = track
            playerState = .playing
            notifyChange()
        } else {
            progressClock.resumePlayback()
            playerState = .playing
        }
        runMusicCommand("play", refreshAfter: true)
    }

    func pause() {
        progressClock.lockForPause()
        let locked = progressClock.calculatedCurrentTime()
        if locked > 0.05 {
            lastValidPlaybackTime = locked
        }
        if var track = currentTrack {
            if locked > 0.05 {
                lastValidTrackKey = Self.trackLookupKey(
                    title: track.title,
                    artist: track.artist,
                    album: track.album
                )
            } else if lastValidPlaybackTime > 0.05 {
                progressClock.seek(to: lastValidPlaybackTime)
            }
            track.isPlaying = false
            track.position = progressClock.calculatedCurrentTime()
            currentTrack = track
            notifyChange()
        }
        playerState = .paused
        // Do not refresh immediately after pause — Music.app often reports position 0 while paused.
        runMusicCommand("pause", refreshAfter: false)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Update mirrored Now Playing state without sending another Music.app command.
    /// Prefer `refresh` after transport commands so UI binds to verified player state.
    func applyOptimisticIsPlaying(_ playing: Bool) {
        bindPlayerState(playing ? .playing : .paused)
    }

    /// Force Play/Pause + progress clock to match Music.app's reported state.
    func bindPlayerState(_ state: AppleMusicPlayerState) {
        playerState = state
        let playing = state == .playing
        if playing {
            progressClock.resumePlayback()
        } else {
            progressClock.lockForPause()
        }
        if var track = currentTrack {
            track.isPlaying = playing
            track.position = progressClock.calculatedCurrentTime()
            currentTrack = track
            notifyChange()
        }
    }

    func next() {
        lastValidPlaybackTime = 0
        lastValidTrackKey = ""
        progressClock.reset()
        artworkInflightKey = ""
        artworkResolvedKey = ""
        runMusicCommand("next track", refreshAfter: true)
    }

    func previous() {
        lastValidPlaybackTime = 0
        lastValidTrackKey = ""
        progressClock.reset()
        artworkInflightKey = ""
        artworkResolvedKey = ""
        runMusicCommand("previous track", refreshAfter: true)
    }

    /// Optimistic UI update on the main actor; AppleScript runs off-thread.
    /// Call this only on seek commit (mouse-up), never while dragging.
    func seek(to position: TimeInterval) {
        seek(to: position, resumePlayback: nil)
    }

    /// - Parameter resumePlayback: When true, Music.app is forced to `play` after the position
    ///   update — setting `player position` often pauses playback.
    func seek(to position: TimeInterval, resumePlayback: Bool?) {
        let seconds = max(0, position)
        let shouldResume = resumePlayback ?? isPlaying
        progressClock.seek(to: seconds)
        if shouldResume {
            progressClock.resumePlayback()
        }
        if var track = currentTrack {
            track.position = seconds
            if shouldResume {
                track.isPlaying = true
            }
            currentTrack = track
            lastValidPlaybackTime = seconds
            lastValidTrackKey = Self.trackLookupKey(
                title: track.title,
                artist: track.artist,
                album: track.album
            )
            notifyChange()
        } else {
            lastValidPlaybackTime = seconds
        }
        pendingSeekExpiresAt = Date().addingTimeInterval(1.6)

        // Music.app frequently pauses when player position is assigned — resume in the same script.
        let resumeLine = shouldResume ? "\n            play" : ""
        let script = """
        tell application "Music"
          try
            set player position to \(String(format: "%.2f", seconds))\(resumeLine)
          end try
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = Self.runAppleScriptReturningString(script)
            DispatchQueue.main.async {
                guard let self else { return }
                if shouldResume {
                    // Belt-and-suspenders: another play if Music still reports paused.
                    if self.isPlaying != true {
                        self.play()
                    } else {
                        self.scheduleRefresh(after: 0.25)
                    }
                }
            }
        }
    }

    func openApplication(activates: Bool = true) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appleMusicBundleIdentifier) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }

    func refresh(completion: (@MainActor () -> Void)?) {
        let now = Date()
        guard !isRefreshing else {
            completion?()
            return
        }
        guard now.timeIntervalSince(lastRefreshDate) >= 0.2 else {
            completion?()
            return
        }
        lastRefreshDate = now
        isRefreshing = true

#if LUMA_APP_STORE
        refreshViaAppleScript { [weak self] info in
            self?.apply(info)
            self?.isRefreshing = false
            completion?()
        }
#else
        NetEaseBridge.shared.fetchNowPlaying(
            allowedBundleIDs: [appleMusicBundleIdentifier],
            defaultArtist: "Apple Music"
        ) { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                if let snapshot {
                    let mapped = MusicNowPlayingInfo(
                        title: snapshot.title,
                        artist: snapshot.artist,
                        album: snapshot.album,
                        artworkData: Self.validImageData(snapshot.artworkData),
                        position: snapshot.position,
                        duration: Self.normalizedDurationSeconds(snapshot.duration),
                        isPlaying: snapshot.isPlaying
                    )
                    self.apply(mapped)
                    self.isRefreshing = false
                    completion?()
                    return
                }

                self.refreshViaAppleScript { info in
                    self.apply(info)
                    self.isRefreshing = false
                    completion?()
                }
            }
        }
#endif
    }

    /// Publish the live timestamp-interpolated playhead for UI ticks (no system poll).
    /// Always rebinds `isPlaying` from the last verified Music.app `playerState`.
    @discardableResult
    func publishInterpolatedPosition(at date: Date = Date()) -> MusicNowPlayingInfo? {
        guard var track = currentTrack else { return nil }
        // Tick binding: icon + clock follow verified Music.app state, not a stale local flag.
        let playing = playerState == .playing
        let playingChanged = track.isPlaying != playing
        if playingChanged {
            track.isPlaying = playing
            if playing {
                progressClock.resumePlayback()
            } else {
                progressClock.lockForPause()
            }
        }
        let next = progressClock.calculatedCurrentTime(at: date)
        guard abs(next - track.position) > 0.008 || playingChanged else { return track }
        track.position = next
        track.isPlaying = playing
        currentTrack = track
        if next > 0.05 {
            lastValidPlaybackTime = next
            lastValidTrackKey = Self.trackLookupKey(
                title: track.title,
                artist: track.artist,
                album: track.album
            )
        }
        return track
    }

    /// Legacy tick entry point — now delegates to the timestamp clock.
    func advancePosition(by elapsed: TimeInterval) {
        _ = elapsed
        _ = publishInterpolatedPosition()
    }

    /// Fetches LRC / plain lyrics from lrclib for the given track metadata.
    nonisolated static func fetchLyrics(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async -> String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let durationSeconds = normalizedDurationSeconds(duration)
        guard !trimmedTitle.isEmpty else { return nil }

        print("[AppleMusic] Lyrics lookup: \(trimmedArtist) - \(trimmedTitle) (album=\(trimmedAlbum), duration=\(durationSeconds))")

        // 1) Loose get: artist + title only.
        if let lyrics = await fetchLyricsGet(
            title: trimmedTitle,
            artist: trimmedArtist.isEmpty ? "Unknown" : trimmedArtist,
            album: nil,
            duration: nil
        ) {
            print("[AppleMusic] Lyrics loaded from lrclib /api/get (title+artist)")
            return lyrics
        }

        // 2) Strict get with album + duration when available.
        if let lyrics = await fetchLyricsGet(
            title: trimmedTitle,
            artist: trimmedArtist.isEmpty ? "Unknown" : trimmedArtist,
            album: trimmedAlbum.isEmpty ? nil : trimmedAlbum,
            duration: durationSeconds > 1 ? durationSeconds : nil
        ) {
            print("[AppleMusic] Lyrics loaded from lrclib /api/get (full signature)")
            return lyrics
        }

        // 3) Search fallback.
        if let lyrics = await fetchLyricsSearch(title: trimmedTitle, artist: trimmedArtist) {
            print("[AppleMusic] Lyrics loaded from lrclib /api/search")
            return lyrics
        }

        print("[AppleMusic] Lyrics not found for \(trimmedArtist) - \(trimmedTitle)")
        return nil
    }

    // MARK: - Private

    private func scheduleRefresh(after delay: TimeInterval = 0.25) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refresh(completion: nil)
        }
    }

    private func handleParsedPlayerInfo(_ info: MusicNowPlayingInfo?) {
        if let info {
            if info.artworkData == nil, let existing = currentTrack?.artworkData,
               Self.sameTrack(info, currentTrack)
            {
                apply(info.withArtworkData(existing))
            } else {
                apply(info)
            }
            if info.isPlaying {
                scheduleRefresh(after: 0.2)
            }
        } else if var track = currentTrack {
            progressClock.lockForPause()
            track.isPlaying = false
            if track.position <= 0.05, lastValidPlaybackTime > 0.05 {
                progressClock.seek(to: lastValidPlaybackTime)
            }
            track.position = progressClock.calculatedCurrentTime()
            currentTrack = track
            notifyChange()
        }
    }

    private func apply(_ info: MusicNowPlayingInfo?) {
        var next = info
        if var incoming = next {
            let trackKey = Self.trackLookupKey(
                title: incoming.title,
                artist: incoming.artist,
                album: incoming.album
            )
            let sameAsCurrent = Self.sameTrack(incoming, currentTrack)
            let sameAsCached = trackKey == lastValidTrackKey && !lastValidTrackKey.isEmpty

            if Date() < pendingSeekExpiresAt, let current = currentTrack, sameAsCurrent {
                incoming.position = current.position
            } else if Date() >= pendingSeekExpiresAt {
                pendingSeekExpiresAt = .distantPast
            }

            if !incoming.isPlaying,
               incoming.position <= 0.05,
               (sameAsCurrent || sameAsCached),
               lastValidPlaybackTime > 0.05
            {
                incoming.position = lastValidPlaybackTime
            } else if !incoming.isPlaying,
                      incoming.position <= 0.05,
                      let current = currentTrack,
                      sameAsCurrent,
                      current.position > 0.05
            {
                incoming.position = current.position
                lastValidPlaybackTime = current.position
                lastValidTrackKey = trackKey
            } else if incoming.position > 0.05 {
                lastValidPlaybackTime = incoming.position
                lastValidTrackKey = trackKey
            } else if !sameAsCurrent && !sameAsCached {
                lastValidPlaybackTime = max(0, incoming.position)
                lastValidTrackKey = trackKey
            }

            if let data = incoming.artworkData, Self.validImageData(data) == nil {
                print("[AppleMusic] Ignoring undecodable local artwork (\(data.count) bytes)")
                incoming.artworkData = nil
            }

            if incoming.artworkData == nil,
               let existing = currentTrack?.artworkData,
               sameAsCurrent,
               Self.validImageData(existing) != nil
            {
                incoming.artworkData = existing
            }

            if !sameAsCurrent {
                artworkInflightKey = ""
                artworkResolvedKey = ""
            }

            incoming.duration = Self.normalizedDurationSeconds(incoming.duration)

            // Bind playerState directly from Music.app's reported isPlaying.
            playerState = incoming.isPlaying ? .playing : .paused

            let settlingSeek = Date() < pendingSeekExpiresAt && sameAsCurrent
            if settlingSeek {
                // Hold seek anchor; ignore noisy system samples until Music.app catches up.
                incoming.position = progressClock.calculatedCurrentTime()
            } else {
                progressClock.calibrate(
                    systemPosition: incoming.position,
                    duration: incoming.duration,
                    isPlaying: incoming.isPlaying,
                    trackIdentity: trackKey,
                    force: !sameAsCurrent
                )
                incoming.position = progressClock.calculatedCurrentTime()
            }
            if incoming.position > 0.05 {
                lastValidPlaybackTime = incoming.position
                lastValidTrackKey = trackKey
            }
            next = incoming
        } else {
            progressClock.reset()
            playerState = .stopped
        }

        let previous = currentTrack
        currentTrack = next
        if previous != next {
            notifyChange()
        }
        if let next {
            enrichArtworkIfNeeded(for: next)
        }
    }

    private func notifyChange() {
        onChange?()
    }

    private func runMusicCommand(_ command: String, refreshAfter: Bool = true) {
        let script = """
        tell application "Music"
          try
            \(command)
          end try
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = Self.runAppleScriptReturningString(script)
            guard refreshAfter else { return }
            DispatchQueue.main.async {
                self?.scheduleRefresh(after: 0.3)
            }
        }
    }

    private func refreshViaAppleScript(completion: @escaping @MainActor (MusicNowPlayingInfo?) -> Void) {
        let script = """
        tell application "Music"
          try
            if player state is stopped then return "stopped|||0|0|0"
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDuration to duration of current track
            set trackPosition to player position
            set trackPlaying to (player state is playing)
            return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackDuration & "|||" & trackPosition & "|||" & trackPlaying
          on error
            return "stopped|||0|0|0"
          end try
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let output = Self.runAppleScriptReturningString(script)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let info = Self.parseAppleScriptNowPlaying(output)
            DispatchQueue.main.async {
                completion(info)
            }
        }
    }

    private func enrichArtworkIfNeeded(for info: MusicNowPlayingInfo) {
        let lookupKey = Self.trackLookupKey(title: info.title, artist: info.artist, album: info.album)

        if let existing = info.artworkData, Self.validImageData(existing) != nil {
            artworkResolvedKey = lookupKey
            return
        }

        guard lookupKey != artworkResolvedKey else { return }
        guard lookupKey != artworkInflightKey else { return }

        let token = UUID()
        artworkEnrichmentToken = token
        artworkInflightKey = lookupKey
        let title = info.title
        let artist = info.artist

        print("[AppleMusic] Artwork enrichment start: \(artist) - \(title)")

        Task { [weak self] in
            let scriptData = await Task.detached(priority: .userInitiated) {
                Self.fetchArtworkDataViaAppleScript()
            }.value

            if let scriptData, let valid = Self.validImageData(scriptData) {
                print("[AppleMusic] Artwork loaded from AppleScript (\(valid.count) bytes)")
                await self?.applyArtworkData(valid, token: token, title: title, artist: artist, source: "AppleScript")
                return
            }
            if scriptData != nil {
                print("[AppleMusic] AppleScript artwork present but not a valid image — falling back to iTunes")
            } else {
                print("[AppleMusic] AppleScript artwork empty — falling back to iTunes")
            }

            if let remote = await Self.fetchArtworkViaiTunesSearch(title: title, artist: artist),
               let valid = Self.validImageData(remote)
            {
                await self?.applyArtworkData(valid, token: token, title: title, artist: artist, source: "iTunes")
                return
            }

            print("[AppleMusic] Artwork enrichment failed for \(artist) - \(title)")
            await MainActor.run {
                guard let self, token == self.artworkEnrichmentToken else { return }
                if self.artworkInflightKey == lookupKey {
                    self.artworkInflightKey = ""
                }
            }
        }
    }

    private func applyArtworkData(
        _ data: Data,
        token: UUID,
        title: String,
        artist: String,
        source: String
    ) {
        guard token == artworkEnrichmentToken else { return }
        guard var track = currentTrack else { return }
        guard Self.normalized(track.title) == Self.normalized(title),
              Self.normalized(track.artist) == Self.normalized(artist) || artist.isEmpty
        else {
            return
        }
        track.artworkData = data
        currentTrack = track
        let key = Self.trackLookupKey(title: track.title, artist: track.artist, album: track.album)
        artworkResolvedKey = key
        artworkInflightKey = ""
        print("[AppleMusic] Artwork applied from \(source) (\(data.count) bytes)")
        notifyChange()
    }

    nonisolated private static func validImageData(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        guard NSImage(data: data) != nil else { return nil }
        return data
    }

    nonisolated private static func normalizedDurationSeconds(_ duration: TimeInterval) -> TimeInterval {
        if duration > 10_000 { return duration / 1000.0 }
        return max(0, duration)
    }

    nonisolated private static func fetchArtworkDataViaAppleScript() -> Data? {
        let fileName = "lumabar-am-art-\(UUID().uuidString).img"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let posixPath = tempURL.path

        let script = """
        tell application "Music"
          try
            if player state is stopped then return ""
            if (count of artworks of current track) is 0 then return ""
            set artData to raw data of artwork 1 of current track
            set outFile to POSIX file "\(posixPath)"
            set fileRef to open for access outFile with write permission
            set eof of fileRef to 0
            write artData to fileRef
            close access fileRef
            return "\(posixPath)"
          on error
            try
              close access (POSIX file "\(posixPath)")
            end try
            return ""
          end try
        end tell
        """

        guard let returned = runAppleScriptReturningString(script)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !returned.isEmpty
        else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }
        let url = URL(fileURLWithPath: returned)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    nonisolated private static func fetchArtworkViaiTunesSearch(
        title: String,
        artist: String
    ) async -> Data? {
        let term = [artist, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !term.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else { return nil }

        print("[AppleMusic] iTunes search: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("LumaBar/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let results = json["results"] as? [[String: Any]],
                let first = results.first,
                let artworkURLString = first["artworkUrl100"] as? String
            else {
                print("[AppleMusic] iTunes search returned no artwork (HTTP \(status))")
                return nil
            }

            let hiRes = artworkURLString
                .replacingOccurrences(of: "100x100bb", with: "600x600bb")
                .replacingOccurrences(of: "100x100", with: "600x600")
            guard let artworkURL = URL(string: hiRes) else { return nil }
            print("[AppleMusic] Artwork loaded from iTunes: \(hiRes)")

            let (imageData, _) = try await URLSession.shared.data(from: artworkURL)
            return imageData
        } catch {
            print("[AppleMusic] iTunes artwork error: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func fetchLyricsGet(
        title: String,
        artist: String,
        album: String?,
        duration: TimeInterval?
    ) async -> String? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/get"
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration, duration > 1 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("LumaBar/1.0 (https://github.com/lumabar)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 404 { return nil }
            guard status >= 200, status < 300 else {
                print("[AppleMusic] lrclib /api/get HTTP \(status)")
                return nil
            }
            return lyricsString(from: data)
        } catch {
            print("[AppleMusic] lrclib /api/get error: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func fetchLyricsSearch(title: String, artist: String) async -> String? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/search"
        var items = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty {
            items.append(URLQueryItem(name: "artist_name", value: artist))
        }
        let q = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
        if !q.isEmpty {
            items.append(URLQueryItem(name: "q", value: q))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }

        print("[AppleMusic] lrclib search: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("LumaBar/1.0 (https://github.com/lumabar)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status >= 200, status < 300,
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = rows.first
            else {
                print("[AppleMusic] lrclib /api/search empty (HTTP \(status))")
                return nil
            }
            if let synced = first["syncedLyrics"] as? String,
               !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return synced
            }
            if let plain = first["plainLyrics"] as? String,
               !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return plain
            }
            return nil
        } catch {
            print("[AppleMusic] lrclib /api/search error: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func lyricsString(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let synced = json["syncedLyrics"] as? String,
           !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return synced
        }
        if let plain = json["plainLyrics"] as? String,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return plain
        }
        return nil
    }

    nonisolated private static func nowPlaying(fromPlayerInfo userInfo: [AnyHashable: Any]?) -> MusicNowPlayingInfo? {
        guard let userInfo else { return nil }

        func stringValue(_ key: String) -> String {
            if let value = userInfo[key] as? String {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let value = userInfo[key] as? NSNumber {
                return value.stringValue
            }
            return ""
        }

        let state = stringValue("Player State").lowercased()
        if state == "stopped" || state.isEmpty && stringValue("Name").isEmpty {
            return nil
        }

        let title = stringValue("Name")
        guard !title.isEmpty else { return nil }

        let totalTimeMs = (userInfo["Total Time"] as? NSNumber)?.doubleValue
            ?? Double(stringValue("Total Time")) ?? 0
        let duration = totalTimeMs > 1000 ? totalTimeMs / 1000.0 : totalTimeMs
        let position = (userInfo["Playback Position"] as? NSNumber)?.doubleValue
            ?? Double(stringValue("Playback Position"))
            ?? 0

        return MusicNowPlayingInfo(
            title: title,
            artist: stringValue("Artist").isEmpty ? "Apple Music" : stringValue("Artist"),
            album: stringValue("Album"),
            artworkData: nil,
            position: max(0, position),
            duration: max(0, duration),
            isPlaying: state == "playing"
        )
    }

    nonisolated private static func parseAppleScriptNowPlaying(_ raw: String) -> MusicNowPlayingInfo? {
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == "stopped" { return nil }

        let artist = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Double(parts[3]) ?? 0
        let position = Double(parts[4]) ?? 0
        let playingToken = parts[5].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isPlaying = playingToken == "true" || playingToken == "1"

        return MusicNowPlayingInfo(
            title: title,
            artist: artist.isEmpty ? "Apple Music" : artist,
            album: album,
            artworkData: nil,
            position: max(0, position),
            duration: normalizedDurationSeconds(duration),
            isPlaying: isPlaying
        )
    }

    nonisolated private static func runAppleScriptReturningString(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    nonisolated private static func sameTrack(_ lhs: MusicNowPlayingInfo?, _ rhs: MusicNowPlayingInfo?) -> Bool {
        guard let lhs, let rhs else { return false }
        return normalized(lhs.title) == normalized(rhs.title)
            && normalized(lhs.artist) == normalized(rhs.artist)
    }

    nonisolated private static func trackLookupKey(title: String, artist: String, album: String) -> String {
        [normalized(title), normalized(artist), normalized(album)].joined(separator: "|")
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
