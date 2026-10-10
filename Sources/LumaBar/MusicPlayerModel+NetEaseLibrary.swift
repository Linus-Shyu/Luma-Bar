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

extension MusicPlayerModel {
    func netEaseLyricShell(_ nowPlaying: NetEaseNowPlaying) -> LocalTrack {
        let songID = nowPlaying.songID.isEmpty ? "current" : nowPlaying.songID
        let url = URL(string: "netease-song://track/\(songID)") ?? URL(fileURLWithPath: "/")
        return LocalTrack(
            id: url,
            url: url,
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album,
            artworkData: nil,
            lyrics: "",
            timedLyrics: [],
            playbackSource: .netEaseSong(id: songID)
        )
    }

    /// Cover and lyrics belong to the resolved track only when it is the song on screen.
    func resolvedNetEasePresentationMatches(_ nowPlaying: NetEaseNowPlaying) -> Bool {
        guard let resolvedNetEaseTrack else { return false }
        let resolvedTitle = Self.netEaseTrackIdentity(
            title: resolvedNetEaseTrack.title,
            artist: resolvedNetEaseTrack.artist,
            album: resolvedNetEaseTrack.album
        )
        let playingTitle = Self.netEaseTrackIdentity(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album
        )
        guard resolvedTitle == playingTitle else { return false }
        if !nowPlaying.songID.isEmpty,
           case .netEaseSong(let songID) = resolvedNetEaseTrack.playbackSource
        {
            return songID == nowPlaying.songID
        }
        return true
    }

    func isCurrentDisplayTrack(_ track: LocalTrack) -> Bool {
        if isDisplayingNetEaseNowPlaying {
            let playingID = netEaseNowPlaying?.songID
            if let playingID, !playingID.isEmpty,
               Self.netEaseSongID(for: track) == playingID
            {
                return true
            }
            if let lyricsID = displayedLyricsTrack.flatMap(Self.netEaseSongID(for:)),
               Self.netEaseSongID(for: track) == lyricsID
            {
                return true
            }
            return false
        }
        if let displayedLyricsTrack, track == displayedLyricsTrack {
            return true
        }
        return track == currentTrack
    }

    /// User-facing source switch — claims exclusive control ownership for that channel.
    /// Does not send play/pause to any player; only locks routing + display.
    func setMusicLibrarySource(_ source: IslandMusicLibrarySource) {
        claimMusicSourceExclusivity(source, reason: "user-pill")

        switch source {
        case .netEase:
            #if LUMA_APP_STORE
            NetEaseBridge.shared.resetLibraryAccessPrompt()
            NetEaseBridge.shared.prepareLibraryAccess()
            #endif
            refreshNetEasePlaylists()
            refreshNetEaseNowPlaying(force: true)
        case .appleMusic:
            AppleMusicService.shared.refresh { [weak self] in
                self?.applyAppleMusicNowPlaying(AppleMusicService.shared.currentTrack)
            }
        case .local:
            // Detach from any NetEase playlist browse state so next/prev stay on local files.
            selectedNetEasePlaylistID = nil
            selectedNetEasePlaylistTracks = []
            let localCount = Self.localPlayableTracks(from: tracks).count
            if localCount == 0 {
                currentIndex = 0
            } else if currentIndex >= localCount {
                currentIndex = 0
            }
        }
    }

    /// Lock `activeMusicSource` + library channel so dormant players cannot steal controls.
    func claimMusicSourceExclusivity(
        _ source: IslandMusicLibrarySource,
        reason: String
    ) {
        _ = reason
        musicLibrarySource = source
        activeMusicSource = source
        musicSourceUserLocked = true
        // Keep pin forever while locked — auto-follow must not yank the tab.
        musicLibrarySourceUserPinUntil = .distantFuture

        switch source {
        case .local:
            isUsingAppleMusic = false
            isUsingNetEase = false
        case .appleMusic:
            isUsingAppleMusic = true
            isUsingNetEase = false
        case .netEase:
            isUsingNetEase = true
            isUsingAppleMusic = false
        }
    }

    /// Whether background Now Playing / app-frontmost sync may mutate ownership for `source`.
    func allowsPassiveOwnership(for source: IslandMusicLibrarySource) -> Bool {
        if musicSourceUserLocked {
            return musicLibrarySource == source && activeMusicSource == source
        }
        return musicLibrarySource == source
    }

    /// Keep the library tab aligned with whoever is actually playing — never against a user lock.
    func syncMusicLibrarySourceToActivePlayback(force: Bool = false) {
        // Pill clicks set musicSourceUserLocked. Never yank the tab away — even force
        // sync from a play path must stay on the channel the user chose.
        if musicSourceUserLocked {
            return
        }
        guard force || Date() >= musicLibrarySourceUserPinUntil else { return }

        let target: IslandMusicLibrarySource?
        if isUsingAppleMusic, appleMusicNowPlaying != nil {
            target = .appleMusic
        } else if isUsingNetEase, netEaseNowPlaying != nil {
            target = .netEase
        } else if audioPlayer?.isPlaying == true {
            target = .local
        } else {
            target = nil
        }

        guard let target else { return }
        activeMusicSource = target
        if force {
            claimMusicSourceExclusivity(target, reason: "playback-force")
            if target == .netEase {
                refreshNetEasePlaylists()
            }
            return
        }
        guard musicLibrarySource != target else { return }
        musicLibrarySource = target
        if target == .netEase {
            refreshNetEasePlaylists()
        }
    }

    func scanLocalMusic() {
        isScanning = true
        scanMessage = LumaBarL10n.scanScanningAll

#if LUMA_APP_STORE
        if SecurityScopedBookmarks.retainedURL(for: .musicLibrary) == nil, !didAskForMusicLibrary {
            didAskForMusicLibrary = true
            _ = SecurityScopedBookmarks.promptAndStore(for: .musicLibrary)
        }
        guard let musicRoot = SecurityScopedBookmarks.retainedURL(for: .musicLibrary) else {
            tracks = []
            netEasePlaylists = []
            currentIndex = 0
            isScanning = false
            scanMessage = LumaBarL10n.scanGrantFolder
            return
        }
        var roots = [musicRoot]
        if let storage = SecurityScopedBookmarks.retainedURL(for: .netEaseStorage),
           !roots.contains(where: { storage.path.hasPrefix($0.path) })
        {
            roots.append(storage)
        }
        Task { [weak self] in
            let discovered = await Task.detached(priority: .userInitiated) {
                await Self.discoverTracks(in: roots)
            }.value
            let playlists = Self.discoverNetEasePlaylists(
                home: FileManager.default.homeDirectoryForCurrentUser
            )

            guard let self else { return }
            self.tracks = discovered
            self.netEasePlaylists = playlists
            self.currentIndex = 0
            self.isScanning = false
            self.scanMessage = discovered.isEmpty ? LumaBarL10n.scanNone : LumaBarL10n.scanFound(discovered.count)
            self.refreshMissingNetEasePlaylistCovers()
            self.prepareCurrentTrack()
        }
#else
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = Self.defaultMusicRoots(home: home)

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let discovered = await Self.discoverTracks(in: roots)
                let playlists = Self.discoverNetEasePlaylists(home: home)
                return (discovered, playlists)
            }.value

            guard let self else { return }
            self.tracks = result.0
            self.netEasePlaylists = result.1
            self.currentIndex = 0
            self.isScanning = false
            self.scanMessage = result.0.isEmpty ? LumaBarL10n.scanNone : LumaBarL10n.scanFound(result.0.count)
            self.refreshMissingNetEasePlaylistCovers()
            self.prepareCurrentTrack()
        }
#endif
    }

    func refreshNetEasePlaylists() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        DispatchQueue.global(qos: .utility).async {
            let playlists = Self.discoverNetEasePlaylists(home: home)
            DispatchQueue.main.async {
                self.netEasePlaylists = playlists
                self.refreshMissingNetEasePlaylistCovers()
                // Also reload the open playlist so newly favorited songs appear.
                if let selected = self.selectedNetEasePlaylist {
                    self.loadNetEasePlaylistTracks(selected)
                }
            }
        }
    }

    nonisolated static func defaultMusicRoots(home: URL) -> [URL] {
        let music = home.appendingPathComponent("Music")
        let container = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("com.netease.163music")
            .appendingPathComponent("Data")
        let candidates = [
            music,
            music.appendingPathComponent("网易云音乐"),
            music.appendingPathComponent("NetEase Cloud Music"),
            music.appendingPathComponent("NeteaseMusic"),
            container.appendingPathComponent("Documents"),
            container.appendingPathComponent("Library").appendingPathComponent("Application Support"),
            container.appendingPathComponent("Library").appendingPathComponent("Caches")
        ]

        var roots: [URL] = []
        var seenPaths = Set<String>()
        let fileManager = FileManager.default

        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path) else { continue }
            if roots.contains(where: { standardized.path.hasPrefix($0.standardizedFileURL.path + "/") }) {
                continue
            }
            if seenPaths.insert(standardized.path).inserted {
                roots.append(standardized)
            }
        }

        return roots.isEmpty ? [music] : roots
    }

    nonisolated static func discoverTracks(in roots: [URL]) async -> [LocalTrack] {
        let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ncm"]
        let lyricExtensions: Set<String> = ["lrc"]
        let fileManager = FileManager.default
        var urls: [URL] = []
        var audioPaths = Set<String>()
        var lyricURLsByKey: [String: URL] = [:]
        let protectedMusicLibraryRoots = roots.map {
            $0.appendingPathComponent("Music").standardizedFileURL.path
        }

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                let standardizedPath = url.standardizedFileURL.path
                if protectedMusicLibraryRoots.contains(where: { standardizedPath == $0 || standardizedPath.hasPrefix($0 + "/") }) {
                    enumerator.skipDescendants()
                    continue
                }

                guard
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey]),
                    values.isRegularFile == true,
                    values.isHidden != true
                else { continue }

                let fileExtension = url.pathExtension.lowercased()

                if supportedExtensions.contains(fileExtension) {
                    let path = url.standardizedFileURL.path
                    if audioPaths.insert(path).inserted {
                        urls.append(url)
                    }
                } else if lyricExtensions.contains(fileExtension) {
                    lyricURLsByKey[normalizedLookupKey(url.deletingPathExtension().lastPathComponent)] = url
                }
            }
        }

        let trackURLs = urls
            .sorted { lhs, rhs in
                let lhsScore = score(url: lhs)
                let rhsScore = score(url: rhs)
                if lhsScore == rhsScore {
                    return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
                }
                return lhsScore > rhsScore
            }
            .prefix(300)

        var tracks: [LocalTrack] = []
        tracks.reserveCapacity(trackURLs.count)
        for url in trackURLs {
            tracks.append(await makeTrack(url: url, lyricURLsByKey: lyricURLsByKey))
        }
        return tracks
    }

    nonisolated static func discoverNetEasePlaylists(home: URL) -> [NetEasePlaylist] {
        guard let database = NetEaseDatabaseSession.open(home: home) else { return [] }
        let databaseURL = database.url

        let sql = """
        SELECT
            CAST(hp.id AS TEXT) AS id,
            COALESCE(NULLIF(json_extract(hp.jsonStr, '$.name'), ''), 'NetEase Playlist') AS name,
            json_extract(hp.jsonStr, '$.coverImgUrl') AS coverImgUrl,
            COALESCE(
                json_extract(hp.jsonStr, '$.trackCount'),
                json_array_length(json_extract(pt.jsonStr, '$.trackIds')),
                0
            ) AS trackCount,
            COALESCE(hp.playtime, json_extract(hp.jsonStr, '$.playtime'), 0) AS playtime
        FROM historyPlaylists hp
        LEFT JOIN playlistTrackIds pt ON pt.id = hp.id
        WHERE hp.id NOT LIKE '%:%'
        ORDER BY playtime DESC
        LIMIT 18;
        """

        guard let data = sqliteJSON(databaseURL: databaseURL, sql: sql),
              let rows = try? JSONDecoder().decode([NetEasePlaylistRow].self, from: data)
        else {
            return []
        }

        return rows.compactMap { row in
            guard !row.id.isEmpty, !row.name.isEmpty else { return nil }
            let coverURL = row.coverImgUrl
                .flatMap(URL.init(string:))
                .flatMap(normalizedNetEaseCoverURL)
            return NetEasePlaylist(
                id: row.id,
                name: row.name,
                coverURL: coverURL,
                coverData: cachedNetEasePlaylistCoverData(id: row.id),
                trackCount: row.trackCount ?? 0,
                playtime: row.playtime ?? 0
            )
        }
    }

    nonisolated static func discoverNetEasePlaylistTracks(
        home: URL,
        playlistID: String,
        fallbackArtworkData: Data?
    ) -> [LocalTrack] {
        // Prefer live API so newly liked / added songs appear before NetEase flushes SQLite.
        let onlineTracks = fetchNetEasePlaylistTracks(
            playlistID: playlistID,
            fallbackArtworkData: fallbackArtworkData
        )
        if !onlineTracks.isEmpty {
            return overlayLocalPlayableFiles(on: onlineTracks, home: home)
        }

        guard let database = NetEaseDatabaseSession.open(home: home) else { return [] }
        let databaseURL = database.url

        let playlistIDLiteral = sqliteStringLiteral(playlistID)
        let sql = """
        WITH playlist_tracks AS (
            SELECT
                CAST(json_extract(value, '$.id') AS TEXT) AS id,
                CAST(key AS INTEGER) AS position
            FROM playlistTrackIds, json_each(json_extract(jsonStr, '$.trackIds'))
            WHERE playlistTrackIds.id = \(playlistIDLiteral)
        )
        SELECT
            CAST(
                COALESCE(
                    NULLIF(json_extract(ht.jsonStr, '$.onlineTrackId'), ''),
                    NULLIF(json_extract(ht.jsonStr, '$.onlineTrack.id'), ''),
                    NULLIF(json_extract(dt.jsonStr, '$.onlineTrackId'), ''),
                    NULLIF(json_extract(dt.jsonStr, '$.onlineTrack.id'), ''),
                    pt.id
                ) AS TEXT
            ) AS id,
            COALESCE(
                NULLIF(json_extract(ht.jsonStr, '$.name'), ''),
                NULLIF(json_extract(dt.jsonStr, '$.name'), ''),
                NULLIF(ot.trackName, ''),
                NULLIF(lt.title, ''),
                'Song ' || pt.id
            ) AS title,
            COALESCE(
                (
                    SELECT group_concat(json_extract(value, '$.name'), '/')
                    FROM json_each(json_extract(ht.jsonStr, '$.artists'))
                ),
                (
                    SELECT group_concat(json_extract(value, '$.name'), '/')
                    FROM json_each(json_extract(ht.jsonStr, '$.ar'))
                ),
                (
                    SELECT group_concat(json_extract(value, '$.name'), '/')
                    FROM json_each(json_extract(dt.jsonStr, '$.artists'))
                ),
                (
                    SELECT group_concat(json_extract(value, '$.name'), '/')
                    FROM json_each(json_extract(dt.jsonStr, '$.ar'))
                ),
                NULLIF(ot.artistName, ''),
                NULLIF(lt.artist, ''),
                'NetEase Cloud Music'
            ) AS artist,
            COALESCE(
                NULLIF(json_extract(ht.jsonStr, '$.album.name'), ''),
                NULLIF(json_extract(ht.jsonStr, '$.al.name'), ''),
                NULLIF(json_extract(dt.jsonStr, '$.album.name'), ''),
                NULLIF(json_extract(dt.jsonStr, '$.al.name'), ''),
                NULLIF(ot.albumName, ''),
                NULLIF(lt.album, ''),
                ''
            ) AS album,
            COALESCE(
                NULLIF(json_extract(ht.jsonStr, '$.album.picUrl'), ''),
                NULLIF(json_extract(ht.jsonStr, '$.album.cover'), ''),
                NULLIF(json_extract(ht.jsonStr, '$.al.picUrl'), ''),
                NULLIF(json_extract(dt.jsonStr, '$.album.picUrl'), ''),
                NULLIF(json_extract(dt.jsonStr, '$.album.cover'), ''),
                NULLIF(json_extract(dt.jsonStr, '$.al.picUrl'), ''),
                ''
            ) AS coverImgUrl,
            COALESCE(
                NULLIF(ot.newRelativePath, ''),
                NULLIF(lt.file, ''),
                ''
            ) AS localFilePath
        FROM playlist_tracks pt
        LEFT JOIN historyTracks ht ON ht.id = pt.id
        LEFT JOIN dbTrack dt ON dt.id = pt.id
        LEFT JOIN offlineTrack ot
            ON ot.id = 'track-' || pt.id
            OR CAST(json_extract(ot.jsonStr, '$.detail.id') AS TEXT) = pt.id
        LEFT JOIN track lt ON lt.tid = pt.id
        ORDER BY pt.position ASC
        LIMIT 180;
        """

        guard let data = sqliteJSON(databaseURL: databaseURL, sql: sql),
              let rows = try? JSONDecoder().decode([NetEasePlaylistTrackRow].self, from: data)
        else {
            return []
        }

        return rows.compactMap { row in
            guard !row.id.isEmpty else { return nil }
            let title = normalizedNonEmpty(row.title) ?? "Song \(row.id)"
            let artist = normalizedNonEmpty(row.artist) ?? "NetEase Cloud Music"
            let album = normalizedNonEmpty(row.album) ?? ""
            let coverURL = row.coverImgUrl
                .flatMap(URL.init(string:))
                .flatMap(normalizedNetEaseCoverURL)
            if let coverURL {
                rememberNetEaseTrackCoverURL(coverURL, id: row.id)
            }
            let localURL = resolvedNetEaseLocalTrackURL(path: row.localFilePath, home: home)
            let songIDURL = URL(string: "netease-song://track/\(row.id)")
            let url = localURL ?? songIDURL ?? URL(fileURLWithPath: "/")
            // Play the file ourselves whenever we can decode it, so seek and the playhead stay exact.
            // Online rows keep the numeric song id and are started with the public play command.
            let playbackSource: TrackPlaybackSource
            if let localURL, Self.isSelfDecodableAudio(localURL) {
                playbackSource = .direct
            } else if row.id.allSatisfy(\.isNumber) {
                playbackSource = .netEaseSong(id: row.id)
            } else {
                playbackSource = .netEase
            }

            // Rows handed to NetEase get their lyrics fetched later, keyed on the song id. Rows we
            // decode ourselves never go through that path, so read the `.lrc` NetEase writes beside
            // the download — and because we own the playhead, its timing is exact, not estimated.
            let sidecarLyrics = playbackSource == .direct
                ? localURL.flatMap(sidecarLyricResult(forAudioAt:))
                : nil

            return LocalTrack(
                id: songIDURL ?? url,
                url: url,
                title: title,
                artist: artist,
                album: album,
                artworkData: cachedNetEaseTrackArtworkData(id: row.id)
                    ?? coverURL.flatMap { cachedNetEaseTrackArtworkData(url: $0) }
                    ?? fallbackArtworkData,
                lyrics: sidecarLyrics?.text ?? "",
                timedLyrics: sidecarLyrics?.timedLines ?? [],
                playbackSource: playbackSource
            )
        }
    }

    /// Formats our own engine can decode. NetEase's `.ncm` downloads are an encrypted container and
    /// `.tmp` files are partial, so neither counts — those rows stay with NetEase.
    nonisolated static let selfDecodableAudioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac"
    ]

    nonisolated static func isSelfDecodableAudio(_ url: URL) -> Bool {
        selfDecodableAudioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Folders we may read for NetEase downloads. Store builds only search user-granted bookmarks.
    nonisolated static func netEaseLocalFileSearchRoots(home: URL) -> [URL] {
        var roots: [URL] = []
        func appendExisting(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path) else { return }
            if !roots.contains(where: { $0.path == standardized.path }) {
                roots.append(standardized)
            }
        }

#if LUMA_APP_STORE
        _ = home
        if let music = SecurityScopedBookmarks.retainedURL(for: .musicLibrary) {
            appendExisting(music)
            appendExisting(music.appendingPathComponent("网易云音乐"))
            appendExisting(music.appendingPathComponent("NetEase Cloud Music"))
            appendExisting(music.appendingPathComponent("NeteaseMusic"))
        }
        if let storage = SecurityScopedBookmarks.retainedURL(for: .netEaseStorage) {
            appendExisting(storage)
        }
#else
        let music = home.appendingPathComponent("Music")
        appendExisting(music.appendingPathComponent("网易云音乐"))
        appendExisting(music.appendingPathComponent("NetEase Cloud Music"))
        appendExisting(music.appendingPathComponent("NeteaseMusic"))
        appendExisting(music)
#endif
        return roots
    }

    nonisolated static func resolvedNetEaseLocalTrackURL(path: String?, home: URL) -> URL? {
        guard let rawPath = normalizedNonEmpty(path) else { return nil }
        let roots = netEaseLocalFileSearchRoots(home: home)
        var candidates: [URL] = []

        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            if !candidates.contains(where: { $0.path == standardized.path }) {
                candidates.append(standardized)
            }
        }

        if rawPath.hasPrefix("/") {
            add(URL(fileURLWithPath: rawPath))
            let relative = String(rawPath.drop { $0 == "/" })
            for root in roots {
                add(root.appendingPathComponent(relative))
            }
        } else {
            for root in roots {
                add(root.appendingPathComponent(rawPath))
            }
        }

        if rawPath.hasSuffix(".tmp") {
            let withoutTmp = String(rawPath.dropLast(4))
            if withoutTmp.hasPrefix("/") {
                add(URL(fileURLWithPath: withoutTmp))
                let relative = String(withoutTmp.drop { $0 == "/" })
                for root in roots {
                    add(root.appendingPathComponent(relative))
                }
            } else {
                for root in roots {
                    add(root.appendingPathComponent(withoutTmp))
                }
            }
        }

        let filename = URL(fileURLWithPath: rawPath).lastPathComponent
        if !filename.isEmpty {
            for root in roots {
                add(root.appendingPathComponent(filename))
            }
        }

        return candidates.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    /// Prefer a self-decodable download (mp3 / m4a / flac) so the store build can seek
    /// without a NetEase seek command. `.ncm` stays with the client.
    nonisolated static func overlayLocalPlayableFiles(
        on tracks: [LocalTrack],
        home: URL
    ) -> [LocalTrack] {
        let songIDs = tracks.compactMap(netEaseSongID(for:))
        let index = netEaseOfflinePlayableIndex(home: home, songIDs: songIDs)
        guard !index.isEmpty else { return tracks }
        return tracks.map { track in
            guard let songID = netEaseSongID(for: track),
                  let localURL = index[songID],
                  isSelfDecodableAudio(localURL)
            else {
                return track
            }
            let sidecar = sidecarLyricResult(forAudioAt: localURL)
            return LocalTrack(
                id: track.id,
                url: localURL,
                title: track.title,
                artist: track.artist,
                album: track.album,
                artworkData: track.artworkData,
                lyrics: sidecar?.text ?? track.lyrics,
                timedLyrics: sidecar?.timedLines ?? track.timedLyrics,
                playbackSource: .direct
            )
        }
    }

    nonisolated static func netEaseOfflinePlayableIndex(
        home: URL,
        songIDs: [String]
    ) -> [String: URL] {
        let uniqueIDs = Array(Set(songIDs.filter { !$0.isEmpty })).prefix(180)
        guard !uniqueIDs.isEmpty,
              let database = NetEaseDatabaseSession.open(home: home)
        else {
            return [:]
        }
        let literals = uniqueIDs.map(sqliteStringLiteral).joined(separator: ",")
        let sql = """
        SELECT CAST(REPLACE(id, 'track-', '') AS TEXT) AS id,
               COALESCE(NULLIF(newRelativePath, ''), '') AS localFilePath
        FROM offlineTrack
        WHERE CAST(REPLACE(id, 'track-', '') AS TEXT) IN (\(literals))
           OR CAST(json_extract(jsonStr, '$.detail.id') AS TEXT) IN (\(literals))
        UNION ALL
        SELECT CAST(tid AS TEXT) AS id,
               COALESCE(NULLIF(file, ''), '') AS localFilePath
        FROM track
        WHERE CAST(tid AS TEXT) IN (\(literals));
        """
        guard let data = sqliteJSON(databaseURL: database.url, sql: sql),
              let rows = try? JSONDecoder().decode([NetEaseLocalFileRow].self, from: data)
        else {
            return [:]
        }
        var index: [String: URL] = [:]
        for row in rows {
            let songID = row.id.replacingOccurrences(of: "track-", with: "")
            guard !songID.isEmpty,
                  index[songID] == nil,
                  let localURL = resolvedNetEaseLocalTrackURL(path: row.localFilePath, home: home),
                  isSelfDecodableAudio(localURL)
            else {
                continue
            }
            index[songID] = localURL
        }
        return index
    }

    nonisolated static func fetchNetEasePlaylistTracks(
        playlistID: String,
        fallbackArtworkData: Data?
    ) -> [LocalTrack] {
        guard
            var components = URLComponents(string: "https://music.163.com/api/v6/playlist/detail")
        else {
            return []
        }

        components.queryItems = [
            URLQueryItem(name: "id", value: playlistID),
            URLQueryItem(name: "n", value: "1000"),
            URLQueryItem(name: "s", value: "8")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        // Private playlists (e.g. 我喜欢的音乐) need the logged-in cookie jar.
        if let session = NetEaseFavoriteController.loadSessionCookies() {
            request.setValue(session.headerValue, forHTTPHeaderField: "Cookie")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let responseDataBox = NetEaseResponseDataBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let httpResponse = response as? HTTPURLResponse,
               (200..<300).contains(httpResponse.statusCode)
            {
                responseDataBox.store(data)
            }
            semaphore.signal()
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + 8.5) == .success,
              let responseData = responseDataBox.load(),
              let response = try? JSONDecoder().decode(NetEaseOnlinePlaylistResponse.self, from: responseData)
        else {
            task.cancel()
            return []
        }

        return response.tracks
            .prefix(180)
            .compactMap { track in
                guard !track.id.isEmpty else { return nil }
                let title = normalizedNonEmpty(track.name) ?? "Song \(track.id)"
                let artist = (track.artists ?? track.ar ?? [])
                    .compactMap { normalizedNonEmpty($0.name) }
                    .joined(separator: "/")
                let album = track.album ?? track.al
                let coverURL = (album?.picUrl ?? album?.cover)
                    .flatMap(URL.init(string:))
                    .flatMap(normalizedNetEaseCoverURL)
                if let coverURL {
                    rememberNetEaseTrackCoverURL(coverURL, id: track.id)
                }
                let url = URL(string: "netease-song://track/\(track.id)") ?? URL(fileURLWithPath: "/")

                return LocalTrack(
                    id: url,
                    url: url,
                    title: title,
                    artist: artist.isEmpty ? "NetEase Cloud Music" : artist,
                    album: normalizedNonEmpty(album?.name) ?? "",
                    // Prefer cache; leave playlist cover as last resort so refresh can replace it.
                    artworkData: cachedNetEaseTrackArtworkData(id: track.id)
                        ?? coverURL.flatMap { cachedNetEaseTrackArtworkData(url: $0) }
                        ?? fallbackArtworkData,
                    lyrics: "",
                    timedLyrics: [],
                    playbackSource: .netEaseSong(id: track.id)
                )
            }
    }

    nonisolated static func resolveNetEaseTrackMetadata(
        home: URL,
        title: String,
        artist: String,
        album: String
    ) -> NetEaseTrackMetadata? {
        guard let database = NetEaseDatabaseSession.open(home: home) else { return nil }
        let databaseURL = database.url

        let sql = """
        SELECT
            CAST(
                COALESCE(
                    NULLIF(json_extract(jsonStr, '$.onlineTrackId'), ''),
                    NULLIF(json_extract(jsonStr, '$.onlineTrack.id'), ''),
                    id
                ) AS TEXT
            ) AS id,
            json_extract(jsonStr, '$.name') AS title,
            COALESCE(
                (
                    SELECT group_concat(json_extract(value, '$.name'), '/')
                    FROM json_each(json_extract(jsonStr, '$.artists'))
                ),
                (
                    SELECT group_concat(json_extract(value, '$.name'), '/')
                    FROM json_each(json_extract(jsonStr, '$.ar'))
                ),
                ''
            ) AS artist,
            COALESCE(
                NULLIF(json_extract(jsonStr, '$.album.name'), ''),
                NULLIF(json_extract(jsonStr, '$.al.name'), ''),
                ''
            ) AS album,
            COALESCE(
                NULLIF(json_extract(jsonStr, '$.album.picUrl'), ''),
                NULLIF(json_extract(jsonStr, '$.album.cover'), ''),
                NULLIF(json_extract(jsonStr, '$.al.picUrl'), ''),
                ''
            ) AS coverImgUrl
        FROM historyTracks
        ORDER BY playtime DESC
        LIMIT 240;
        """

        guard let data = sqliteJSON(databaseURL: databaseURL, sql: sql),
              let rows = try? JSONDecoder().decode([NetEaseResolvedTrackRow].self, from: data)
        else {
            return nil
        }

        let requestedTitle = normalizedLookupKey(title)
        let requestedArtist = normalizedLookupKey(artist)
        let requestedAlbum = normalizedLookupKey(album)
        guard !requestedTitle.isEmpty else { return nil }

        let bestMatch = rows.compactMap { row -> (row: NetEaseResolvedTrackRow, score: Int)? in
            guard let candidateTitle = normalizedNonEmpty(row.title) else { return nil }
            let candidateTitleKey = normalizedLookupKey(candidateTitle)

            var score: Int
            if candidateTitleKey == requestedTitle {
                score = 140
            } else if candidateTitleKey.contains(requestedTitle) || requestedTitle.contains(candidateTitleKey) {
                score = 75
            } else {
                return nil
            }

            let candidateArtistKey = normalizedLookupKey(row.artist ?? "")
            if !requestedArtist.isEmpty, !candidateArtistKey.isEmpty {
                if candidateArtistKey == requestedArtist {
                    score += 45
                } else if candidateArtistKey.contains(requestedArtist) || requestedArtist.contains(candidateArtistKey) {
                    score += 25
                }
            }

            let candidateAlbumKey = normalizedLookupKey(row.album ?? "")
            if !requestedAlbum.isEmpty, candidateAlbumKey == requestedAlbum {
                score += 25
            }

            return (row, score)
        }
        .max { lhs, rhs in lhs.score < rhs.score }?
        .row

        guard let bestMatch, !bestMatch.id.isEmpty else { return nil }
        let coverURL = bestMatch.coverImgUrl
            .flatMap(URL.init(string:))
            .flatMap(normalizedNetEaseCoverURL)

        return NetEaseTrackMetadata(
            id: bestMatch.id,
            title: normalizedNonEmpty(bestMatch.title) ?? title,
            artist: normalizedNonEmpty(bestMatch.artist) ?? artist,
            album: normalizedNonEmpty(bestMatch.album) ?? album,
            coverURL: coverURL
        )
    }

    nonisolated static func sqliteStringLiteral(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "''"))'"
    }

    nonisolated static func normalizedNonEmpty(_ string: String?) -> String? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    nonisolated static func cachedNetEaseTrackArtworkData(url: URL) -> Data? {
        URLCache.shared.cachedResponse(for: URLRequest(url: url))?.data
    }

    nonisolated static func cachedNetEaseTrackArtworkData(id: String) -> Data? {
        guard let url = netEaseTrackArtworkCacheURL(id: id),
              let data = try? Data(contentsOf: url),
              !data.isEmpty
        else {
            return nil
        }

        return data
    }

    /// Cover URLs learned from playlist/song APIs — unplayed tracks often have no local SQLite art.
    nonisolated static func rememberNetEaseTrackCoverURL(_ url: URL, id: String) {
        NetEaseTrackCoverURLCache.shared.store(url, for: id)
    }

    nonisolated static func knownNetEaseTrackCoverURL(id: String) -> URL? {
        NetEaseTrackCoverURLCache.shared.url(for: id)
    }

    nonisolated static func storeNetEaseTrackArtworkData(_ data: Data, id: String) {
        guard let url = netEaseTrackArtworkCacheURL(id: id, createDirectory: true) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func netEaseTrackArtworkCacheURL(
        id: String,
        createDirectory: Bool = false
    ) -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let directory = applicationSupport
            .appendingPathComponent("luma bar", isDirectory: true)
            .appendingPathComponent("NetEaseTrackArtwork", isDirectory: true)

        if createDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let safeID = id.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        return directory.appendingPathComponent(safeID).appendingPathExtension("jpg")
    }

    nonisolated static func cachedNetEaseLyricsData(id: String) -> Data? {
        guard let url = netEaseLyricsCacheURL(id: id),
              let data = try? Data(contentsOf: url),
              !data.isEmpty
        else {
            return nil
        }
        return data
    }

    nonisolated static func storeNetEaseLyricsData(_ data: Data, id: String) {
        guard let url = netEaseLyricsCacheURL(id: id, createDirectory: true) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func netEaseLyricsCacheURL(
        id: String,
        createDirectory: Bool = false
    ) -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let directory = applicationSupport
            .appendingPathComponent("luma bar", isDirectory: true)
            .appendingPathComponent("NetEaseLyrics", isDirectory: true)

        if createDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let safeID = id.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        return directory.appendingPathComponent(safeID).appendingPathExtension("json")
    }

    func refreshResolvedNetEaseDetails(for nowPlaying: NetEaseNowPlaying) {
        let identity = Self.netEaseTrackIdentity(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album
        )
        guard !identity.isEmpty else { return }

        if identity != currentNetEaseTrackIdentity {
            currentNetEaseTrackIdentity = identity
            netEaseDetailsRequestToken = UUID()
            isResolvingNetEaseDetails = false
            netEaseLyricsTask?.cancel()
            netEaseArtworkTask?.cancel()
            resolvedNetEaseTrack = nil
            pendingNetEaseSeek = nil
            lastNetEaseLyricsRetryDate = .distantPast
        } else if let artworkData = nowPlaying.artworkData,
                  resolvedNetEaseTrack?.artworkData == nil,
                  let songID = resolvedNetEaseSongID
        {
            updateResolvedNetEaseTrack(
                songID: songID,
                requestToken: netEaseDetailsRequestToken,
                artworkData: artworkData
            )
        }

#if LUMA_APP_STORE
        let songID = nowPlaying.songID.isEmpty
            ? (NetEasePlaybackStore.currentSongID ?? "")
            : nowPlaying.songID
        if !songID.isEmpty, resolvedNetEaseSongID != songID {
            let token = netEaseDetailsRequestToken
            let url = URL(string: "netease-song://track/\(songID)") ?? URL(fileURLWithPath: "/")
            let coverURL = nowPlaying.songID.isEmpty ? NetEasePlaybackStore.currentCoverURL : nowPlaying.coverURL
            resolvedNetEaseTrack = LocalTrack(
                id: url,
                url: url,
                title: nowPlaying.title,
                artist: nowPlaying.artist,
                album: nowPlaying.album,
                artworkData: nil,
                lyrics: "",
                timedLyrics: [],
                playbackSource: .netEaseSong(id: songID)
            )
            loadNetEaseLyrics(
                songID: songID,
                requestToken: token,
                title: nowPlaying.title,
                artist: nowPlaying.artist
            )
            loadNetEaseArtwork(
                songID: songID,
                coverURL: coverURL,
                requestToken: token
            )
            return
        }
#endif

        // Lyrics fetch can fail once and leave an empty resolved track forever — retry.
        if let resolved = resolvedNetEaseTrack,
           !resolved.hasLyrics,
           let songID = Self.netEaseSongID(for: resolved),
           Date().timeIntervalSince(lastNetEaseLyricsRetryDate) >= 2.5
        {
            lastNetEaseLyricsRetryDate = Date()
            loadNetEaseLyrics(
                songID: songID,
                requestToken: netEaseDetailsRequestToken,
                title: nowPlaying.title,
                artist: nowPlaying.artist
            )
        }

        if resolvedNetEaseTrack == nil,
           seedResolvedNetEaseTrackFromKnownTracks(
                nowPlaying: nowPlaying,
                identity: identity,
                requestToken: netEaseDetailsRequestToken
           )
        {
            return
        }

        guard resolvedNetEaseTrack == nil, !isResolvingNetEaseDetails else { return }
        isResolvingNetEaseDetails = true

        resolveNetEaseDetails(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album,
            mediaRemoteArtwork: nowPlaying.artworkData,
            identity: identity,
            requestToken: netEaseDetailsRequestToken,
            attempt: 0
        )
    }

    @discardableResult
    func seedResolvedNetEaseTrackFromKnownTracks(
        nowPlaying: NetEaseNowPlaying,
        identity: String,
        requestToken: UUID
    ) -> Bool {
        guard let track = matchingKnownNetEaseTrack(for: nowPlaying),
              let songID = Self.netEaseSongID(for: track)
        else {
            return false
        }

        seedResolvedNetEaseTrack(
            track,
            songID: songID,
            identity: identity,
            requestToken: requestToken
        )
        return true
    }

    func matchingKnownNetEaseTrack(for nowPlaying: NetEaseNowPlaying) -> LocalTrack? {
        let requestedTitle = Self.normalizedLookupKey(nowPlaying.title)
        let requestedArtist = Self.normalizedLookupKey(nowPlaying.artist)
        let requestedAlbum = Self.normalizedLookupKey(nowPlaying.album)
        guard !requestedTitle.isEmpty else { return nil }

        let candidates = selectedNetEasePlaylistTracks + tracks
        return candidates.compactMap { track -> (track: LocalTrack, score: Int)? in
            guard Self.netEaseSongID(for: track) != nil || track.playbackSource.isNetEaseBacked else {
                return nil
            }

            let titleKey = Self.normalizedLookupKey(track.title)
            var score: Int
            if titleKey == requestedTitle {
                score = 120
            } else if titleKey.contains(requestedTitle) || requestedTitle.contains(titleKey) {
                score = 70
            } else {
                return nil
            }

            let artistKey = Self.normalizedLookupKey(track.artist)
            if !requestedArtist.isEmpty, !artistKey.isEmpty {
                if artistKey == requestedArtist {
                    score += 34
                } else if artistKey.contains(requestedArtist) || requestedArtist.contains(artistKey) {
                    score += 18
                }
            }

            let albumKey = Self.normalizedLookupKey(track.album)
            if !requestedAlbum.isEmpty, albumKey == requestedAlbum {
                score += 12
            }

            return (track, score)
        }
        .max { lhs, rhs in lhs.score < rhs.score }?
        .track
    }

    func seedResolvedNetEaseTrack(
        _ track: LocalTrack,
        songID: String,
        identity: String,
        requestToken: UUID? = nil
    ) {
        guard !songID.isEmpty else { return }

        let token = requestToken ?? UUID()
        currentNetEaseTrackIdentity = identity
        netEaseDetailsRequestToken = token
        isResolvingNetEaseDetails = false
        netEaseLyricsTask?.cancel()
        netEaseArtworkTask?.cancel()

        let songURL = URL(string: "netease-song://track/\(songID)") ?? track.url
        resolvedNetEaseTrack = LocalTrack(
            id: songURL,
            url: track.url,
            title: track.title,
            artist: track.artist,
            album: track.album,
            artworkData: track.artworkData,
            lyrics: track.lyrics,
            timedLyrics: track.timedLyrics,
            playbackSource: .netEaseSong(id: songID)
        )

        loadNetEaseLyrics(
            songID: songID,
            requestToken: token,
            title: track.title,
            artist: track.artist
        )
        loadNetEaseArtwork(songID: songID, coverURL: nil, requestToken: token)
    }

    func resolveNetEaseDetails(
        title: String,
        artist: String,
        album: String,
        mediaRemoteArtwork: Data?,
        identity: String,
        requestToken: UUID,
        attempt: Int
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser

        DispatchQueue.global(qos: .userInitiated).async {
            let metadata = Self.resolveNetEaseTrackMetadata(
                home: home,
                title: title,
                artist: artist,
                album: album
            )

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.netEaseDetailsRequestToken == requestToken,
                      self.currentNetEaseTrackIdentity == identity
                else {
                    return
                }

                guard let metadata else {
                    if attempt < 2 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                            guard let self,
                                  self.netEaseDetailsRequestToken == requestToken,
                                  self.currentNetEaseTrackIdentity == identity
                            else {
                                return
                            }

                            self.resolveNetEaseDetails(
                                title: title,
                                artist: artist,
                                album: album,
                                mediaRemoteArtwork: mediaRemoteArtwork,
                                identity: identity,
                                requestToken: requestToken,
                                attempt: attempt + 1
                            )
                        }
                    } else {
                        self.resolveNetEaseDetailsOnline(
                            title: title,
                            artist: artist,
                            album: album,
                            mediaRemoteArtwork: mediaRemoteArtwork,
                            identity: identity,
                            requestToken: requestToken
                        )
                    }
                    return
                }

                self.isResolvingNetEaseDetails = false
                let artworkData = Self.cachedNetEaseTrackArtworkData(id: metadata.id)
                    ?? mediaRemoteArtwork
                let url = URL(string: "netease-song://track/\(metadata.id)")
                    ?? URL(fileURLWithPath: "/")

                self.resolvedNetEaseTrack = LocalTrack(
                    id: url,
                    url: url,
                    title: metadata.title,
                    artist: metadata.artist,
                    album: metadata.album,
                    artworkData: artworkData,
                    lyrics: "",
                    timedLyrics: [],
                    playbackSource: .netEaseSong(id: metadata.id)
                )

                self.loadNetEaseLyrics(
                    songID: metadata.id,
                    requestToken: requestToken,
                    title: metadata.title,
                    artist: metadata.artist
                )
                self.loadNetEaseArtwork(
                    metadata: metadata,
                    requestToken: requestToken
                )
            }
        }
    }

    func resolveNetEaseDetailsOnline(
        title: String,
        artist: String,
        album: String,
        mediaRemoteArtwork: Data?,
        identity: String,
        requestToken: UUID
    ) {
        Task { [weak self] in
            do {
                let match = try await NetEaseAgentSearchClient.bestSong(title: title, artist: artist)
                guard let self,
                      self.netEaseDetailsRequestToken == requestToken,
                      self.currentNetEaseTrackIdentity == identity
                else {
                    return
                }
                guard let match else {
                    self.isResolvingNetEaseDetails = false
                    if self.resolvedNetEaseTrack == nil {
                        let url = URL(string: "netease-song://unresolved") ?? URL(fileURLWithPath: "/")
                        self.resolvedNetEaseTrack = LocalTrack(
                            id: url,
                            url: url,
                            title: title,
                            artist: artist,
                            album: album,
                            artworkData: mediaRemoteArtwork,
                            lyrics: "",
                            timedLyrics: [],
                            playbackSource: .netEaseSong(id: "unresolved")
                        )
                    }
                    return
                }

                self.isResolvingNetEaseDetails = false
                let artworkData = Self.cachedNetEaseTrackArtworkData(id: match.id)
                    ?? mediaRemoteArtwork
                let url = URL(string: "netease-song://track/\(match.id)")
                    ?? URL(fileURLWithPath: "/")
                self.resolvedNetEaseTrack = LocalTrack(
                    id: url,
                    url: url,
                    title: match.title,
                    artist: match.artist.isEmpty ? artist : match.artist,
                    album: album,
                    artworkData: artworkData,
                    lyrics: "",
                    timedLyrics: [],
                    playbackSource: .netEaseSong(id: match.id)
                )
                self.loadNetEaseLyrics(
                    songID: match.id,
                    requestToken: requestToken,
                    title: match.title,
                    artist: match.artist.isEmpty ? artist : match.artist
                )
                self.loadNetEaseArtwork(
                    songID: match.id,
                    coverURL: nil,
                    requestToken: requestToken
                )
            } catch {
                guard let self,
                      self.netEaseDetailsRequestToken == requestToken,
                      self.currentNetEaseTrackIdentity == identity
                else {
                    return
                }
                self.isResolvingNetEaseDetails = false
            }
        }
    }

    func loadNetEaseLyrics(
        songID: String,
        requestToken: UUID,
        title: String = "",
        artist: String = ""
    ) {
        let trimmedID = songID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }

        if trimmedID.allSatisfy(\.isNumber),
           let cachedData = Self.cachedNetEaseLyricsData(id: trimmedID)
        {
            if let lyricResult = Self.parseNetEaseLyricsResponse(cachedData) {
                updateResolvedNetEaseTrack(
                    songID: trimmedID,
                    requestToken: requestToken,
                    lyricResult: lyricResult
                )
            }
            return
        }

        if trimmedID.allSatisfy(\.isNumber) {
            fetchNetEaseLyricsBySongID(
                songID: trimmedID,
                requestToken: requestToken,
                title: title,
                artist: artist,
                allowSearchFallback: true
            )
            return
        }

        // Non-numeric IDs (rare): fall back to title/artist search.
        fetchNetEaseLyricsBySearch(
            title: title,
            artist: artist,
            requestToken: requestToken,
            expectedSongID: trimmedID
        )
    }

    func fetchNetEaseLyricsBySongID(
        songID: String,
        requestToken: UUID,
        title: String,
        artist: String,
        allowSearchFallback: Bool
    ) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.163.com"
        components.path = "/api/song/lyric"
        components.queryItems = [
            URLQueryItem(name: "id", value: songID),
            URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "kv", value: "-1"),
            URLQueryItem(name: "tv", value: "-1")
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        netEaseLyricsTask?.cancel()
        netEaseLyricsTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let lyricResult = data.flatMap(Self.parseNetEaseLyricsResponse)
            if let data, lyricResult != nil || Self.isDefinitiveNetEaseLyricResponse(data) {
                Self.storeNetEaseLyricsData(data, id: songID)
            }
            if let lyricResult {
                DispatchQueue.main.async { [weak self] in
                    self?.updateResolvedNetEaseTrack(
                        songID: songID,
                        requestToken: requestToken,
                        lyricResult: lyricResult
                    )
                }
                return
            }

            if let data, Self.isDefinitiveNetEaseLyricResponse(data) {
                return
            }

            guard allowSearchFallback else { return }
            DispatchQueue.main.async { [weak self] in
                self?.fetchNetEaseLyricsBySearch(
                    title: title,
                    artist: artist,
                    requestToken: requestToken,
                    expectedSongID: songID
                )
            }
        }
        netEaseLyricsTask?.resume()
    }

    func fetchNetEaseLyricsBySearch(
        title: String,
        artist: String,
        requestToken: UUID,
        expectedSongID: String
    ) {
        let queryTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queryTitle.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            let match = try? await NetEaseAgentSearchClient.bestSong(
                title: queryTitle,
                artist: queryArtist
            )
            guard self.netEaseDetailsRequestToken == requestToken else { return }
            guard let match, match.id.allSatisfy(\.isNumber) else { return }
            // A same title can be a different recording. Using that id puts another song's words
            // under the title on screen.
            guard match.id == expectedSongID else { return }

            self.fetchNetEaseLyricsBySongID(
                songID: expectedSongID,
                requestToken: requestToken,
                title: queryTitle,
                artist: queryArtist,
                allowSearchFallback: false
            )
        }
    }

    func loadNetEaseArtwork(metadata: NetEaseTrackMetadata, requestToken: UUID) {
        loadNetEaseArtwork(
            songID: metadata.id,
            coverURL: metadata.coverURL,
            requestToken: requestToken
        )
    }

    func loadNetEaseArtwork(songID: String, coverURL: URL?, requestToken: UUID) {
        if let coverURL {
            let knownURL = Self.knownNetEaseTrackCoverURL(id: songID)
            if knownURL == coverURL,
               let cachedData = Self.cachedNetEaseTrackArtworkData(id: songID)
            {
                updateResolvedNetEaseTrack(
                    songID: songID,
                    requestToken: requestToken,
                    artworkData: cachedData
                )
                return
            }
            Self.rememberNetEaseTrackCoverURL(coverURL, id: songID)
            downloadNetEaseArtwork(songID: songID, coverURL: coverURL, requestToken: requestToken)
            return
        }

        if let cachedData = Self.cachedNetEaseTrackArtworkData(id: songID) {
            updateResolvedNetEaseTrack(
                songID: songID,
                requestToken: requestToken,
                artworkData: cachedData
            )
            return
        }

        loadNetEaseArtworkFromSongDetail(songID: songID, requestToken: requestToken)
    }

    func loadNetEaseArtworkFromSongDetail(songID: String, requestToken: UUID) {
        guard songID.allSatisfy(\.isNumber) else { return }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.163.com"
        components.path = "/api/song/detail/"
        components.queryItems = [
            URLQueryItem(name: "id", value: songID),
            URLQueryItem(name: "ids", value: "[\(songID)]")
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        netEaseArtworkTask?.cancel()
        netEaseArtworkTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard
                let data,
                let coverURL = Self.netEaseSongDetailCoverURLs(from: data)[songID]
            else {
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.netEaseDetailsRequestToken == requestToken,
                      self.resolvedNetEaseSongID == songID
                else {
                    return
                }

                self.downloadNetEaseArtwork(
                    songID: songID,
                    coverURL: coverURL,
                    requestToken: requestToken
                )
            }
        }
        netEaseArtworkTask?.resume()
    }

    func downloadNetEaseArtwork(songID: String, coverURL: URL, requestToken: UUID) {
        var request = URLRequest(url: coverURL)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        netEaseArtworkTask?.cancel()
        netEaseArtworkTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let imageData = Self.acceptedPlaylistCoverData(data, response: response) else { return }
            Self.storeNetEaseTrackArtworkData(imageData, id: songID)

            DispatchQueue.main.async { [weak self] in
                self?.updateResolvedNetEaseTrack(
                    songID: songID,
                    requestToken: requestToken,
                    artworkData: imageData
                )
            }
        }
        netEaseArtworkTask?.resume()
    }

    nonisolated static func netEaseSongDetailCoverURLs(from data: Data) -> [String: URL] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let songs = root["songs"] as? [[String: Any]]
        else {
            return [:]
        }

        var coverURLs: [String: URL] = [:]

        for song in songs {
            let songID: String?
            if let stringID = song["id"] as? String {
                songID = stringID
            } else if let intID = song["id"] as? Int64 {
                songID = String(intID)
            } else if let intID = song["id"] as? Int {
                songID = String(intID)
            } else {
                songID = nil
            }

            guard let songID, !songID.isEmpty else { continue }
            let album = (song["album"] as? [String: Any]) ?? (song["al"] as? [String: Any])
            let rawURL = (album?["picUrl"] as? String)
                ?? (album?["cover"] as? String)
                ?? (album?["pic"] as? String)
            if let coverURL = rawURL.flatMap(URL.init(string:)).flatMap(normalizedNetEaseCoverURL) {
                coverURLs[songID] = coverURL
                rememberNetEaseTrackCoverURL(coverURL, id: songID)
            }
        }

        return coverURLs
    }

    /// `dt` on `/api/v3/song/detail` is milliseconds.
    nonisolated static func netEaseSongDetailDurations(from data: Data) -> [String: TimeInterval] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let songs = root["songs"] as? [[String: Any]]
        else {
            return [:]
        }

        var durations: [String: TimeInterval] = [:]
        for song in songs {
            let songID: String?
            if let stringID = song["id"] as? String {
                songID = stringID
            } else if let intID = song["id"] as? Int64 {
                songID = String(intID)
            } else if let intID = song["id"] as? Int {
                songID = String(intID)
            } else {
                songID = nil
            }
            guard let songID, !songID.isEmpty else { continue }
            let raw: Double?
            if let number = song["dt"] as? NSNumber {
                raw = number.doubleValue
            } else if let value = song["dt"] as? Double {
                raw = value
            } else if let value = song["dt"] as? Int {
                raw = Double(value)
            } else {
                raw = nil
            }
            guard let raw, raw > 1 else { continue }
            durations[songID] = raw > 1_000 ? raw / 1_000 : raw
        }
        return durations
    }

    /// Fill duration while history/MediaRemote still lag a play-by-id, so the seek bar enables.
    func prefetchNetEaseSongDuration(songID: String) {
        guard !songID.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.163.com"
        components.path = "/api/v3/song/detail"
        components.queryItems = [
            URLQueryItem(name: "c", value: "[{\"id\":\(songID)}]")
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        if let session = NetEaseFavoriteController.loadSessionCookies() {
            request.setValue(session.headerValue, forHTTPHeaderField: "Cookie")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let duration = Self.netEaseSongDetailDurations(from: data)[songID],
                  duration > 1
            else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.pinnedNetEaseSongID == songID || self.netEaseNowPlaying?.songID == songID,
                      let existing = self.netEaseNowPlaying,
                      existing.duration <= 1
                else {
                    return
                }
                let updated = existing.with(duration: duration)
                self.netEaseNowPlaying = updated
                self.netEaseProgressClock.calibrate(
                    systemPosition: updated.position,
                    duration: duration,
                    isPlaying: updated.isPlaying,
                    trackIdentity: self.pinnedNetEaseIdentity.isEmpty
                        ? Self.netEaseTrackIdentity(
                            title: updated.title,
                            artist: updated.artist,
                            album: updated.album
                        )
                        : self.pinnedNetEaseIdentity,
                    force: true
                )
            }
        }.resume()
    }

    nonisolated static func netEaseSongID(for track: LocalTrack) -> String? {
        switch track.playbackSource {
        case .netEaseSong(let songID):
            return songID
        case .direct, .netEase, .appleMusic:
            guard track.id.scheme == "netease-song" else { return nil }
            let songID = track.id.lastPathComponent
            return songID.isEmpty ? nil : songID
        }
    }

    func updateResolvedNetEaseTrack(
        songID: String,
        requestToken: UUID,
        artworkData: Data? = nil,
        lyricResult: LyricParseResult? = nil
    ) {
        guard netEaseDetailsRequestToken == requestToken,
              let track = resolvedNetEaseTrack,
              case .netEaseSong(let currentSongID) = track.playbackSource,
              currentSongID == songID
        else {
            return
        }

        resolvedNetEaseTrack = LocalTrack(
            id: track.id,
            url: track.url,
            title: track.title,
            artist: track.artist,
            album: track.album,
            artworkData: artworkData ?? track.artworkData,
            lyrics: lyricResult?.text ?? track.lyrics,
            timedLyrics: lyricResult?.timedLines ?? track.timedLyrics,
            playbackSource: track.playbackSource
        )
    }

    func refreshMissingNetEasePlaylistTrackArtwork(
        playlistID: String,
        fallbackArtworkData: Data?
    ) {
        let trackSnapshot = Array(selectedNetEasePlaylistTracks.prefix(180))
        var cachedUpdates: [(songID: String, data: Data)] = []
        var knownURLDownloads: [(songID: String, coverURL: URL)] = []
        var candidates: [String] = []

        for track in trackSnapshot {
            guard let songID = Self.netEaseSongID(for: track),
                  songID.allSatisfy(\.isNumber)
            else {
                continue
            }

            if let cachedData = Self.cachedNetEaseTrackArtworkData(id: songID) {
                cachedUpdates.append((songID, cachedData))
                continue
            }

            if let artworkData = track.artworkData,
               fallbackArtworkData == nil || artworkData != fallbackArtworkData
            {
                continue
            }

            guard pendingNetEasePlaylistTrackArtworkIDs.insert(songID).inserted else { continue }

            // Playlist/detail APIs already gave us picUrl for most tracks — use it first.
            if let knownURL = Self.knownNetEaseTrackCoverURL(id: songID) {
                knownURLDownloads.append((songID, knownURL))
            } else {
                candidates.append(songID)
            }
        }

        cachedUpdates.forEach { update in
            updateNetEasePlaylistTrackArtwork(
                songID: update.songID,
                playlistID: playlistID,
                data: update.data
            )
        }

        for item in knownURLDownloads {
            downloadNetEasePlaylistTrackArtwork(
                songID: item.songID,
                playlistID: playlistID,
                coverURL: item.coverURL
            )
        }

        guard !candidates.isEmpty else { return }

        for chunk in candidates.chunked(into: 40) {
            requestNetEasePlaylistTrackArtworkURLs(
                songIDs: Array(chunk),
                playlistID: playlistID
            )
        }
    }

    func requestNetEasePlaylistTrackArtworkURLs(songIDs: [String], playlistID: String) {
        guard !songIDs.isEmpty else { return }

        // Prefer v3 song/detail — the legacy /api/song/detail/ often returns empty for cold tracks.
        let payload = songIDs.map { #"{"id":\#($0)}"# }.joined(separator: ",")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.163.com"
        components.path = "/api/v3/song/detail"
        components.queryItems = [
            URLQueryItem(name: "c", value: "[\(payload)]")
        ]
        guard let url = components.url else {
            songIDs.forEach { pendingNetEasePlaylistTrackArtworkIDs.remove($0) }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        if let session = NetEaseFavoriteController.loadSessionCookies() {
            request.setValue(session.headerValue, forHTTPHeaderField: "Cookie")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let coverURLs = data.map(Self.netEaseSongDetailCoverURLs(from:)) ?? [:]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.selectedNetEasePlaylistID == playlistID else {
                    songIDs.forEach { self.pendingNetEasePlaylistTrackArtworkIDs.remove($0) }
                    return
                }

                for songID in songIDs {
                    guard let coverURL = coverURLs[songID] else {
                        self.pendingNetEasePlaylistTrackArtworkIDs.remove(songID)
                        continue
                    }
                    Self.rememberNetEaseTrackCoverURL(coverURL, id: songID)

                    self.downloadNetEasePlaylistTrackArtwork(
                        songID: songID,
                        playlistID: playlistID,
                        coverURL: coverURL
                    )
                }
            }
        }.resume()
    }

    func downloadNetEasePlaylistTrackArtwork(songID: String, playlistID: String, coverURL: URL) {
        var request = URLRequest(url: coverURL)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let imageData = Self.acceptedPlaylistCoverData(data, response: response)
            if let imageData {
                Self.storeNetEaseTrackArtworkData(imageData, id: songID)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingNetEasePlaylistTrackArtworkIDs.remove(songID)
                guard self.selectedNetEasePlaylistID == playlistID, let imageData else { return }
                self.updateNetEasePlaylistTrackArtwork(
                    songID: songID,
                    playlistID: playlistID,
                    data: imageData
                )
            }
        }.resume()
    }

    func updateNetEasePlaylistTrackArtwork(songID: String, playlistID: String, data: Data) {
        guard selectedNetEasePlaylistID == playlistID else { return }

        for index in selectedNetEasePlaylistTracks.indices {
            guard Self.netEaseSongID(for: selectedNetEasePlaylistTracks[index]) == songID else { continue }
            let track = selectedNetEasePlaylistTracks[index]
            selectedNetEasePlaylistTracks[index] = LocalTrack(
                id: track.id,
                url: track.url,
                title: track.title,
                artist: track.artist,
                album: track.album,
                artworkData: data,
                lyrics: track.lyrics,
                timedLyrics: track.timedLyrics,
                playbackSource: track.playbackSource
            )
        }
    }

    /// A 200 response that includes an `lrc` object is the song's real lyric document, even when
    /// that document is only songwriter credits. Don't search again or the panel spins forever.
    nonisolated static func isDefinitiveNetEaseLyricResponse(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let code = (root["code"] as? Int) ?? (root["code"] as? NSNumber)?.intValue
        return code == 200 && root["lrc"] != nil
    }

    nonisolated static func parseNetEaseLyricsResponse(_ data: Data) -> LyricParseResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func lyricPayload(_ key: String) -> String? {
            guard let payload = root[key] as? [String: Any],
                  let lyric = payload["lyric"] as? String,
                  !lyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return lyric
        }

        let original = (lyricPayload("lrc") ?? lyricPayload("yrc") ?? lyricPayload("klyric"))
            .flatMap(parseLyrics)
        let translated = lyricPayload("tlyric").flatMap(parseLyrics)

        guard let original else { return translated }
        guard let translated,
              !original.timedLines.isEmpty,
              !translated.timedLines.isEmpty
        else {
            return original
        }

        let mergedLines = original.timedLines.enumerated().map { item in
            let originalLine = item.element
            let translation = translated.timedLines.min {
                abs($0.time - originalLine.time) < abs($1.time - originalLine.time)
            }
            let translatedText: String?
            if let translation, abs(translation.time - originalLine.time) <= 0.35,
               translation.text != originalLine.text
            {
                translatedText = translation.text
            } else {
                translatedText = nil
            }

            return TimedLyricLine(
                id: item.offset,
                time: originalLine.time,
                text: translatedText.map { "\(originalLine.text)\n\($0)" } ?? originalLine.text
            )
        }

        return LyricParseResult(
            text: mergedLines.map(\.text).joined(separator: "\n"),
            timedLines: mergedLines
        )
    }

    nonisolated static func netEaseTrackIdentity(
        title: String,
        artist: String,
        album: String = ""
    ) -> String {
        // MediaRemote often flickers album/artist (e.g. real artist ↔ "NetEase Cloud Music"),
        // which used to reset lyric resolution forever. Title is the stable signal.
        _ = album
        _ = artist
        return normalizedLookupKey(title)
    }

    func refreshMissingNetEasePlaylistCovers() {
        for playlist in netEasePlaylists.prefix(18) {
            guard playlist.coverData == nil, let coverURL = playlist.coverURL else { continue }
            guard pendingNetEasePlaylistCoverIDs.insert(playlist.id).inserted else { continue }

            var request = URLRequest(url: coverURL)
            request.timeoutInterval = 8
            request.cachePolicy = .returnCacheDataElseLoad
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )

            URLSession.shared.dataTask(with: request) { [playlistID = playlist.id] data, response, _ in
                let imageData = Self.acceptedPlaylistCoverData(data, response: response)
                if let imageData {
                    Self.storeNetEasePlaylistCoverData(imageData, id: playlistID)
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingNetEasePlaylistCoverIDs.remove(playlistID)
                    guard let imageData else { return }
                    self.updateNetEasePlaylistCover(id: playlistID, data: imageData)
                }
            }.resume()
        }
    }

    func updateNetEasePlaylistCover(id: String, data: Data) {
        guard let index = netEasePlaylists.firstIndex(where: { $0.id == id }) else { return }
        netEasePlaylists[index] = netEasePlaylists[index].withCoverData(data)

        if selectedNetEasePlaylistID == id, let netEaseNowPlaying, netEaseNowPlaying.artworkData == nil {
            self.netEaseNowPlaying = netEaseNowPlaying.withArtworkData(data)
        }
    }

    nonisolated static func normalizedNetEaseCoverURL(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }

        return components.url ?? url
    }

    nonisolated static func cachedNetEasePlaylistCoverData(id: String) -> Data? {
        guard let url = netEasePlaylistCoverCacheURL(id: id),
              let data = try? Data(contentsOf: url),
              !data.isEmpty
        else {
            return nil
        }

        return data
    }

    nonisolated static func storeNetEasePlaylistCoverData(_ data: Data, id: String) {
        guard let url = netEasePlaylistCoverCacheURL(id: id, createDirectory: true) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func acceptedPlaylistCoverData(_ data: Data?, response: URLResponse?) -> Data? {
        guard let data, data.count > 128 else { return nil }
        if let httpResponse = response as? HTTPURLResponse {
            guard (200..<300).contains(httpResponse.statusCode) else { return nil }
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard contentType.isEmpty || contentType.contains("image") else { return nil }
        }
        return data
    }

    nonisolated static func netEasePlaylistCoverCacheURL(id: String, createDirectory: Bool = false) -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let directory = applicationSupport
            .appendingPathComponent("luma bar", isDirectory: true)
            .appendingPathComponent("NetEasePlaylistCovers", isDirectory: true)

        if createDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let safeID = id.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        return directory.appendingPathComponent(safeID).appendingPathExtension("jpg")
    }

    nonisolated static func sqliteJSON(databaseURL: URL, sql: String) -> Data? {
#if LUMA_APP_STORE
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rows: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let columnCount = sqlite3_column_count(statement)
            for index in 0..<columnCount {
                guard let namePointer = sqlite3_column_name(statement, index) else { continue }
                let name = String(cString: namePointer)
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = NSNumber(value: sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row[name] = NSNumber(value: sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, index) {
                        row[name] = String(cString: text)
                    } else {
                        row[name] = NSNull()
                    }
                default:
                    row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return try? JSONSerialization.data(withJSONObject: rows)
#else
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", databaseURL.path, sql]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    #endif
}

    nonisolated static func score(url: URL) -> Int {
        let path = url.path.lowercased()
        var score = 0
        if path.contains("/music/music/media") { score += 50 }
        if path.contains("/网易云音乐/") || path.contains("netease") || path.contains("163music") { score += 45 }
        if path.contains("/downloads/") { score += 20 }
        if path.contains("/rekordbox/sampler/") { score -= 80 }
        if path.contains("/preset ") || path.contains("/preset/") { score -= 35 }
        if path.contains("demo track") { score -= 10 }
        if url.pathExtension.lowercased() == "ncm" { score += 18 }
        if ["mp3", "m4a", "aac", "flac"].contains(url.pathExtension.lowercased()) { score += 10 }
        return score
    }

    nonisolated static func makeTrack(
        url: URL,
        lyricURLsByKey: [String: URL]
    ) async -> LocalTrack {
        let items = await metadataItems(for: url)
        let netEaseMetadata = url.pathExtension.lowercased() == "ncm"
            ? netEaseNCMMetadata(for: url)
            : nil
        let metadataTitle = await firstString(
            in: items,
            commonKey: .commonKeyTitle,
            identifiers: [
                .commonIdentifierTitle,
                .iTunesMetadataSongName
            ]
        )
        let title = netEaseMetadata?["musicName"] as? String
            ?? metadataTitle
            ?? url.deletingPathExtension().lastPathComponent
        let albumURL = url.deletingLastPathComponent()
        let artistURL = albumURL.deletingLastPathComponent()
        let fallbackAlbum = albumURL.lastPathComponent
            .replacingOccurrences(of: ".localized", with: "")
        let fallbackArtist = artistURL.lastPathComponent
            .replacingOccurrences(of: ".localized", with: "")
        let metadataAlbum = await firstString(
            in: items,
            commonKey: .commonKeyAlbumName,
            identifiers: [
                .commonIdentifierAlbumName,
                .iTunesMetadataAlbum,
                .id3MetadataAlbumTitle
            ]
        )
        let album = netEaseMetadata?["album"] as? String
            ?? metadataAlbum
            ?? fallbackAlbum
        let metadataArtist = await firstString(
            in: items,
            commonKey: .commonKeyArtist,
            identifiers: [
                .commonIdentifierArtist,
                .iTunesMetadataArtist,
                .id3MetadataLeadPerformer
            ]
        )
        let artist = netEaseArtist(in: netEaseMetadata)
            ?? metadataArtist
            ?? fallbackArtist
        let embeddedLyrics = await firstString(
            in: items,
            identifiers: [
                .iTunesMetadataLyrics,
                .id3MetadataUnsynchronizedLyric
            ]
        )
        let embeddedLyricResult = embeddedLyrics.flatMap(parseLyrics)
        let sidecarLyrics = firstSidecarLyrics(
            for: url,
            title: title,
            artist: artist,
            lyricURLsByKey: lyricURLsByKey
        )
        let lyricResult: LyricParseResult?

        if let sidecarLyrics, !sidecarLyrics.timedLines.isEmpty {
            lyricResult = sidecarLyrics
        } else if let embeddedLyricResult, !embeddedLyricResult.timedLines.isEmpty {
            lyricResult = embeddedLyricResult
        } else {
            lyricResult = sidecarLyrics ?? embeddedLyricResult
        }

        let lyrics = lyricResult?.text ?? embeddedLyrics ?? ""
        let timedLyrics = lyricResult?.timedLines ?? []
        let artworkData: Data?
        if let trackID = netEaseTrackID(in: netEaseMetadata) {
            artworkData = sidecarArtworkData(for: url) ?? netEaseArtworkData(for: url, trackID: trackID)
        } else {
            artworkData = await resolvedArtworkData(for: url, metadataItems: items)
        }

        return LocalTrack(
            id: url,
            url: url,
            title: title,
            artist: artist,
            album: album,
            artworkData: artworkData,
            lyrics: lyrics,
            timedLyrics: timedLyrics,
            playbackSource: url.pathExtension.lowercased() == "ncm" ? .netEase : .direct
        )
    }

    nonisolated static func metadataItems(for url: URL) async -> [AVMetadataItem] {
        let asset = AVURLAsset(url: url)
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        let metadata = (try? await asset.load(.metadata)) ?? []
        return commonMetadata + metadata
    }

    nonisolated static func firstString(
        in items: [AVMetadataItem],
        commonKey: AVMetadataKey? = nil,
        identifiers: [AVMetadataIdentifier] = []
    ) async -> String? {
        for item in items {
            let hasCommonKey = commonKey != nil && item.commonKey == commonKey
            let hasIdentifier = item.identifier.map { identifiers.contains($0) } ?? false
            guard hasCommonKey || hasIdentifier else { continue }
            do {
                guard let value = try await item.load(.stringValue)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty
                else {
                    continue
                }
                return value
            } catch {
                continue
            }
        }

        return nil
    }

    nonisolated static func firstArtworkData(in items: [AVMetadataItem]) async -> Data? {
        for item in items {
            let isArtwork = item.commonKey == .commonKeyArtwork || item.identifier == .commonIdentifierArtwork
            guard isArtwork else { continue }

            do {
                if let data = try await item.load(.dataValue), !data.isEmpty {
                    return data
                }
            } catch {
                continue
            }

            do {
                if let value = try await item.load(.value),
                   let data = value as? Data,
                   !data.isEmpty
                {
                    return data
                }
            } catch {
                continue
            }
        }

        return nil
    }

    nonisolated static func resolvedArtworkData(
        for url: URL,
        metadataItems: [AVMetadataItem]
    ) async -> Data? {
        if let metadataArtwork = await firstArtworkData(in: metadataItems) {
            return metadataArtwork
        }
        if let sidecarArtwork = sidecarArtworkData(for: url) {
            return sidecarArtwork
        }
        return await netEaseArtworkData(for: url, metadataItems: metadataItems)
    }

    nonisolated static func sidecarArtworkData(for url: URL) -> Data? {
        let directory = url.deletingLastPathComponent()
        let baseURL = url.deletingPathExtension()
        let candidates = [
            baseURL.appendingPathExtension("jpg"),
            baseURL.appendingPathExtension("jpeg"),
            baseURL.appendingPathExtension("png"),
            directory.appendingPathComponent("cover.jpg"),
            directory.appendingPathComponent("folder.jpg"),
            directory.appendingPathComponent("album.jpg")
        ]

        for candidate in candidates {
            if let data = try? Data(contentsOf: candidate), !data.isEmpty {
                return data
            }
        }

        return nil
    }

    nonisolated static func netEaseArtworkData(
        for url: URL,
        metadataItems: [AVMetadataItem]
    ) async -> Data? {
        guard let trackID = await netEaseTrackID(in: metadataItems) else { return nil }
        return netEaseArtworkData(for: url, trackID: trackID)
    }

    nonisolated static func netEaseArtworkData(for url: URL, trackID: String) -> Data? {
        let metadataDirectory = url.deletingLastPathComponent().appendingPathComponent("meta")
        let exactCover = metadataDirectory.appendingPathComponent("track-\(trackID).jpg")
        if let data = try? Data(contentsOf: exactCover), !data.isEmpty {
            return data
        }

        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let prefix = "track-\(trackID)"
        for candidate in candidates where candidate.lastPathComponent.hasPrefix(prefix) {
            if let data = try? Data(contentsOf: candidate), !data.isEmpty {
                return data
            }
        }

        return nil
    }

    nonisolated static func netEaseTrackID(in items: [AVMetadataItem]) async -> String? {
        let marker = "163 key(Don't modify):"
        for item in items {
            do {
                guard
                    let comment = try await item.load(.stringValue),
                    let markerRange = comment.range(of: marker),
                    let payload = decryptNetEaseMetadata(encoded: String(comment[markerRange.upperBound...]))
                else {
                    continue
                }
                return netEaseTrackID(in: payload)
            } catch {
                continue
            }
        }

        return nil
    }

    nonisolated static func netEaseTrackID(in payload: [String: Any]?) -> String? {
        if let trackID = payload?["musicId"] as? String {
            return trackID
        }
        if let trackID = payload?["musicId"] as? NSNumber {
            return trackID.stringValue
        }
        return nil
    }

    nonisolated static func netEaseArtist(in payload: [String: Any]?) -> String? {
        guard let artists = payload?["artist"] as? [[Any]] else { return nil }
        let names = artists.compactMap { $0.first as? String }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: "/")
    }

    nonisolated static func netEaseNCMMetadata(for url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 18 else {
            return nil
        }

        let magic = String(data: data.prefix(8), encoding: .ascii)
        guard magic == "CTENFDAM" else { return nil }

        var offset = 10
        guard let keyLength = littleEndianUInt32(in: data, at: offset) else { return nil }
        offset += 4 + Int(keyLength)
        guard let metadataLength = littleEndianUInt32(in: data, at: offset) else { return nil }
        offset += 4

        let metadataEnd = offset + Int(metadataLength)
        guard metadataEnd <= data.count else { return nil }
        let encodedCommentData = Data(data[offset..<metadataEnd].map { $0 ^ 0x63 })
        guard
            let encodedComment = String(data: encodedCommentData, encoding: .utf8),
            let markerRange = encodedComment.range(of: "163 key(Don't modify):")
        else {
            return nil
        }

        return decryptNetEaseMetadata(encoded: String(encodedComment[markerRange.upperBound...]))
    }

    nonisolated static func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    nonisolated static func decryptNetEaseMetadata(encoded: String) -> [String: Any]? {
        guard let encryptedData = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let decryptedData = decryptNetEaseAES(encryptedData)
        else {
            return nil
        }
        let jsonData = decryptedData.starts(with: Data("music:".utf8))
            ? decryptedData.dropFirst(6)
            : decryptedData[...]
        return try? JSONSerialization.jsonObject(with: Data(jsonData)) as? [String: Any]
    }

    /// AES-128-ECB used by NetEase local `.ncm` metadata. Runs in-process so the sandbox
    /// does not need to spawn `openssl`.
    nonisolated static func decryptNetEaseAES(_ data: Data) -> Data? {
        let key = Data([
            0x23, 0x31, 0x34, 0x6c, 0x6a, 0x6b, 0x5f, 0x21,
            0x5c, 0x5d, 0x26, 0x30, 0x55, 0x3c, 0x27, 0x28
        ])
        let outputCapacity = data.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyBytes.baseAddress,
                        kCCKeySizeAES128,
                        nil,
                        inputBytes.baseAddress,
                        data.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &written
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }

    nonisolated static func firstSidecarLyrics(
        for url: URL,
        title: String,
        artist: String,
        lyricURLsByKey: [String: URL]
    ) -> LyricParseResult? {
        var candidates = [
            normalizedLookupKey(url.deletingPathExtension().lastPathComponent),
            normalizedLookupKey("\(artist) - \(title)")
        ]
        let titleKey = normalizedLookupKey(title)

        if titleKey.count > 4 {
            candidates.append(titleKey)
        }

        for candidate in candidates where !candidate.isEmpty {
            if let lyricsURL = lyricURLsByKey[candidate],
               let lyrics = readLyrics(from: lyricsURL)
            {
                return lyrics
            }
        }

        if titleKey.count > 4 {
            let suffixMatches = lyricURLsByKey.filter { key, _ in key.hasSuffix(titleKey) }
            if suffixMatches.count == 1,
               let lyricsURL = suffixMatches.first?.value,
               let lyrics = readLyrics(from: lyricsURL)
            {
                return lyrics
            }
        }

        return nil
    }

    /// `.lrc` NetEase writes next to a downloaded audio file.
    nonisolated static func sidecarLyricResult(forAudioAt url: URL) -> LyricParseResult? {
        let lyricURL = url.deletingPathExtension().appendingPathExtension("lrc")
        guard FileManager.default.fileExists(atPath: lyricURL.path) else { return nil }
        return readLyrics(from: lyricURL)
    }

    nonisolated static func readLyrics(from url: URL) -> LyricParseResult? {
        let raw = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .utf16))
            ?? (try? String(contentsOf: url, encoding: .unicode))
        guard let raw else { return nil }

        return parseLyrics(from: raw)
    }

    nonisolated static func parseLyrics(from raw: String) -> LyricParseResult? {
        var plainLines: [String] = []
        var timedRows: [(time: TimeInterval, text: String, order: Int)] = []

        for line in raw.components(separatedBy: .newlines) {
            guard let parsedLine = parseLyricLine(line) else { continue }
            let order = plainLines.count
            plainLines.append(parsedLine.text)

            for time in parsedLine.times {
                timedRows.append((time, parsedLine.text, order))
            }
        }

        let text = plainLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timedLines = timedRows
            .sorted { lhs, rhs in
                if lhs.time == rhs.time {
                    return lhs.order < rhs.order
                }
                return lhs.time < rhs.time
            }
            .enumerated()
            .map { item in
                TimedLyricLine(id: item.offset, time: item.element.time, text: item.element.text)
            }

        guard !text.isEmpty || !timedLines.isEmpty else { return nil }
        return LyricParseResult(text: text, timedLines: timedLines)
    }

    nonisolated static func parseLyricLine(_ line: String) -> (times: [TimeInterval], text: String)? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return nil }

        if let netEaseLyric = netEaseLyricPayload(from: trimmedLine) {
            guard let text = cleanLyricText(netEaseLyric.text) else { return nil }
            return (netEaseLyric.time.map { [$0] } ?? [], text)
        }

        guard let text = cleanLyricText(trimmedLine) else { return nil }
        return (lyricTimes(in: trimmedLine), text)
    }

    nonisolated static func cleanLyricText(_ text: String) -> String? {
        let withoutTimeTags = text.replacingOccurrences(
            of: #"\[[0-9]{1,3}:[0-9]{2}(?:[.:][0-9]{1,3})?(?:-[0-9]+)?\]"#,
            with: "",
            options: .regularExpression
        )
        let withoutInfoTags = withoutTimeTags.replacingOccurrences(
            of: #"\[(ti|ar|al|au|by|offset|re|ve|length|id|hash|sign|kana|language):[^\]]*\]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let withoutEnhancedTiming = withoutInfoTags
            .replacingOccurrences(
                of: #"<[0-9]{1,3}:[0-9]{2}(?:[.:][0-9]{1,3})?>"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"<[0-9]+,[0-9]+,[0-9]+>"#,
                with: "",
                options: .regularExpression
            )
        let cleaned = withoutEnhancedTiming
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }
        if isCreditOnlyLyricLine(cleaned) {
            return nil
        }

        return cleaned
    }

    nonisolated static func lyricTimes(in line: String) -> [TimeInterval] {
        let pattern = #"\[([0-9]{1,3}):([0-9]{2})(?:[.:]([0-9]{1,3}))?(?:-[0-9]+)?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)

        return regex.matches(in: line, range: nsRange).compactMap { match in
            guard
                let minutesRange = Range(match.range(at: 1), in: line),
                let secondsRange = Range(match.range(at: 2), in: line),
                let minutes = Double(String(line[minutesRange])),
                let seconds = Double(String(line[secondsRange]))
            else {
                return nil
            }

            var fraction = 0.0
            let fractionRange = match.range(at: 3)
            if fractionRange.location != NSNotFound,
               let swiftRange = Range(fractionRange, in: line)
            {
                let rawFraction = String(line[swiftRange])
                if let value = Double(rawFraction) {
                    fraction = value / pow(10, Double(rawFraction.count))
                }
            }

            return minutes * 60 + seconds + fraction
        }
    }

    nonisolated static func netEaseLyricPayload(from line: String) -> (time: TimeInterval?, text: String)? {
        guard line.first == "{",
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chunks = object["c"] as? [[String: Any]]
        else {
            return nil
        }

        let time = (object["t"] as? NSNumber).map { $0.doubleValue / 1000 }
        let text = chunks
            .compactMap { $0["tx"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? nil : (time, text)
    }

    nonisolated static func isCreditOnlyLyricLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        let prefixes = [
            "作词:",
            "作词：",
            "作曲:",
            "作曲：",
            "编曲:",
            "编曲：",
            "制作人:",
            "制作人：",
            "监制:",
            "监制：",
            "词:",
            "词：",
            "曲:",
            "曲：",
            "composer:",
            "composer：",
            "composers:",
            "composers：",
            "writer:",
            "writer：",
            "writers:",
            "writers：",
            "producer:",
            "producer：",
            "producers:",
            "producers：",
            "co-producer:",
            "co-producer：",
            "co-producers:",
            "co-producers：",
            "sample:",
            "sample：",
            "samples:",
            "samples："
        ]

        return prefixes.contains { lowercased.hasPrefix($0) }
    }

    nonisolated static func normalizedLookupKey(_ string: String) -> String {
        let folded = string.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        return String(
            folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        )
    }
}
