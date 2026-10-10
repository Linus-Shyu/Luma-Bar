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
    func openNetEaseCloudMusic() {
        preserveExpandedPanelForNetEaseActivation()
        // Keep NetEase in the background unless the user explicitly wants the client UI.
        NetEaseBridge.shared.openApplication(activates: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshNetEaseNowPlaying(force: true)
        }
    }

    func playNetEasePlaylist(_ playlist: NetEasePlaylist) {
        audioPlayer?.pause()
        audioPlayer = nil
        isPlaying = false
        claimMusicSourceExclusivity(.netEase, reason: "play-netease-playlist")
        browseNetEasePlaylist(playlist)
        netEaseNowPlaying = NetEaseNowPlaying(
            title: playlist.name,
            artist: "NetEase playlist",
            album: playlist.countText,
            artworkData: playlist.coverData,
            position: 0,
            duration: 0,
            isPlaying: false
        )
        scanMessage = "Opening \(playlist.name)"
        preserveExpandedPanelForNetEaseActivation()
        loadNetEasePlaylistTracks(playlist)
        NetEaseBridge.shared.openPlaylist(id: playlist.id)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.refreshNetEaseNowPlaying(force: true)
        }
    }

    func browseNetEasePlaylist(_ playlist: NetEasePlaylist) {
        guard netEasePlaylists.contains(where: { $0.id == playlist.id }) else { return }
        let sameSelection = selectedNetEasePlaylistID == playlist.id

        selectedNetEasePlaylistID = playlist.id
        if !sameSelection {
            selectedNetEasePlaylistTracks = []
            currentIndex = 0
        }
        // Always reload — NetEase SQLite can lag behind newly liked songs.
        scanMessage = "Loading \(playlist.name)"
        loadNetEasePlaylistTracks(playlist)
    }

    func browseAdjacentNetEasePlaylist(offset: Int) {
        guard !netEasePlaylists.isEmpty, offset != 0 else { return }

        let currentIndex = selectedNetEasePlaylistID.flatMap { selectedID in
            netEasePlaylists.firstIndex { $0.id == selectedID }
        }
        let startingIndex = currentIndex ?? (offset > 0 ? -1 : 0)
        let count = netEasePlaylists.count
        let nextIndex = ((startingIndex + offset) % count + count) % count
        browseNetEasePlaylist(netEasePlaylists[nextIndex])
    }

    func loadNetEasePlaylistTracks(_ playlist: NetEasePlaylist) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let playlistID = playlist.id
        let fallbackArtworkData = playlist.coverData

        DispatchQueue.global(qos: .userInitiated).async {
            let playlistTracks = Self.discoverNetEasePlaylistTracks(
                home: home,
                playlistID: playlistID,
                fallbackArtworkData: fallbackArtworkData
            )

            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedNetEasePlaylistID == playlistID else { return }
                self.selectedNetEasePlaylistTracks = playlistTracks
                self.scanMessage = playlistTracks.isEmpty
                    ? "No cached songs for \(playlist.name)"
                    : "\(playlistTracks.count) songs in \(playlist.name)"
                self.refreshMissingNetEasePlaylistTrackArtwork(
                    playlistID: playlistID,
                    fallbackArtworkData: fallbackArtworkData
                )
            }
        }
    }

    func playCurrentSelection() {
        guard let currentTrack else { return }

        // Local channel always advances through local files with AVAudioPlayer.
        if musicLibrarySource == .local {
            playDirectTrack(currentTrack)
            return
        }

        playNetEaseOwnedTrack(currentTrack)
    }

    func playDirectTrack(_ track: LocalTrack) {
        guard Self.isLocallyPlayableFile(track) else { return }
        claimMusicSourceExclusivity(.local, reason: "play-local-file")
        activateExclusivePlayback(source: .local)
        appleMusicNowPlaying = nil
        resolvedAppleMusicTrack = nil
        currentAppleMusicTrackIdentity = ""
        appleMusicLyricsFinishedIdentity = ""
        appleMusicLyricsTask?.cancel()
        pendingAppleMusicSeek = nil
        netEaseNowPlaying = nil
        resolvedNetEaseTrack = nil
        pendingNetEaseSeek = nil
        // Playing local must not keep a NetEase playlist as the next/prev queue.
        if musicLibrarySource == .local {
            selectedNetEasePlaylistID = nil
            selectedNetEasePlaylistTracks = []
        }
        prepareDirectTrack(track)
        isPlaying = audioPlayer?.play() ?? false
        if !isPlaying {
            scanMessage = "Cannot play \(track.title)"
        } else {
            syncMusicLibrarySourceToActivePlayback(force: true)
        }
    }

    /// True when the song playing belongs to the NetEase list on screen, so skips follow that list.
    func continueNetEaseListAfterSongEnded(
        previous: NetEaseNowPlaying,
        previousPosition: TimeInterval,
        incoming: NetEaseNowPlaying
    ) -> Bool {
        guard musicLibrarySource == .netEase,
              previous.isPlaying,
              previous.duration > 30,
              previous.duration - previousPosition <= 8
        else {
            return false
        }
        let queue = activePlaybackList
        guard queue.count > 1 else { return false }

        func songID(of nowPlaying: NetEaseNowPlaying) -> String? {
            if !nowPlaying.songID.isEmpty { return nowPlaying.songID }
            return matchingKnownNetEaseTrack(for: nowPlaying).flatMap(Self.netEaseSongID(for:))
        }
        guard let previousID = songID(of: previous),
              let previousIndex = queue.firstIndex(where: { Self.netEaseSongID(for: $0) == previousID })
        else {
            return false
        }
        let nextIndex = (previousIndex + 1) % queue.count
        let expected = queue[nextIndex]
        currentIndex = nextIndex
        if let expectedID = Self.netEaseSongID(for: expected), expectedID == songID(of: incoming) {
            return false
        }
        playNetEaseOwnedTrack(expected)
        return true
    }

    /// Skip inside the list on screen. Self-decodable downloads play in-app; everything else
    /// uses the public `orpheus://` play-by-id command. NetEase publishes no next/previous.
    func skipNetEaseTrack(offset: Int) -> Bool {
        let queue = activePlaybackList
        guard queue.count > 1 else { return false }
        let current = indexOfPlayingNetEaseTrack(in: queue)
            ?? (queue.indices.contains(currentIndex) ? currentIndex : 0)
        let next = ((current + offset) % queue.count + queue.count) % queue.count
        let track = queue[next]
        currentIndex = next
        playNetEaseOwnedTrack(track)
        return true
    }

    /// Stay on the NetEase channel: decode ordinary files ourselves, hand the rest to the client.
    func playNetEaseOwnedTrack(_ track: LocalTrack) {
        if Self.isLocallyPlayableFile(track) {
            playOwnedNetEaseDownload(track)
        } else {
            playNetEaseTrack(track)
        }
    }

    /// Play a user-granted mp3 / m4a / flac while keeping the NetEase playlist as the queue.
    /// Seek, pause, and lyrics timing are ours; the NetEase client is paused so two players
    /// do not run. Encrypted `.ncm` never reaches this path.
    func playOwnedNetEaseDownload(_ track: LocalTrack) {
        guard Self.isLocallyPlayableFile(track) else {
            playNetEaseTrack(track)
            return
        }

        exclusivePlayGeneration &+= 1
        let netEaseLikelyPlaying = netEaseNowPlaying?.isPlaying == true
            || NetEaseAudioActivity.isAudible
        claimMusicSourceExclusivity(.netEase, reason: "play-netease-download")
        appleMusicNowPlaying = nil
        resolvedAppleMusicTrack = nil
        currentAppleMusicTrackIdentity = ""
        appleMusicLyricsFinishedIdentity = ""
        appleMusicLyricsTask?.cancel()
        pendingAppleMusicSeek = nil
        pendingNetEaseSeek = nil
        markAppleMusicPausedInUI()
        prepareDirectTrack(track)
        audioPlayerHoldsNetEaseDownload = audioPlayer != nil
        isPlaying = audioPlayer?.play() ?? false

        let duration = audioPlayer?.duration ?? 0
        let position = audioPlayer?.currentTime ?? 0
        let songID = Self.netEaseSongID(for: track) ?? ""
        let identity = Self.netEaseTrackIdentity(
            title: track.title,
            artist: track.displayArtist,
            album: track.album
        )
        netEaseNowPlaying = NetEaseNowPlaying(
            title: track.title,
            artist: track.displayArtist,
            album: track.album,
            artworkData: track.artworkData,
            position: position,
            duration: duration,
            isPlaying: isPlaying,
            positionIsReliable: true,
            songID: songID
        )
        netEaseCommandedPlaying = isPlaying
        netEaseHoldPosition = false
        netEaseProgressClock.calibrate(
            systemPosition: position,
            duration: duration,
            isPlaying: isPlaying,
            trackIdentity: identity,
            force: true
        )
        pinnedNetEaseIdentity = identity
        pinnedNetEaseSongID = songID
        pinnedNetEaseUntil = Date().addingTimeInterval(120)
        if !songID.isEmpty {
            seedResolvedNetEaseTrack(track, songID: songID, identity: identity)
        } else {
            resolvedNetEaseTrack = track
        }
        preserveExpandedPanelForNetEaseActivation()
        scanMessage = isPlaying ? "Playing \(track.title)" : "Cannot play \(track.title)"

        DispatchQueue.global(qos: .userInitiated).async {
            ExclusiveAudioFocus.silenceRivals(
                of: .local,
                netEaseLikelyPlaying: netEaseLikelyPlaying
            )
        }
    }

    func indexOfPlayingNetEaseTrack(in queue: [LocalTrack]) -> Int? {
        func index(ofSongWithID songID: String) -> Int? {
            queue.firstIndex { Self.netEaseSongID(for: $0) == songID }
        }
        if let resolved = resolvedNetEaseTrack,
           let songID = Self.netEaseSongID(for: resolved),
           let index = index(ofSongWithID: songID) {
            return index
        }
        #if LUMA_APP_STORE
        if let songID = NetEasePlaybackStore.currentSongID,
           let index = index(ofSongWithID: songID) {
            return index
        }
        #endif
        if let nowPlaying = netEaseNowPlaying,
           let match = matchingKnownNetEaseTrack(for: nowPlaying),
           let songID = Self.netEaseSongID(for: match),
           let index = index(ofSongWithID: songID) {
            return index
        }
        return nil
    }

    func playNetEaseTrack(_ track: LocalTrack) {
        ensureSinglePlayerPlaying(target: .netEase) {
            self.audioPlayer = nil
            self.isPlaying = false
            self.position = 0
            self.duration = 0
            self.appleMusicNowPlaying = nil
            self.resolvedAppleMusicTrack = nil
            self.currentAppleMusicTrackIdentity = ""
            self.appleMusicLyricsFinishedIdentity = ""
            self.appleMusicLyricsTask?.cancel()
            self.pendingAppleMusicSeek = nil
            let playedSongID: String = {
                if case .netEaseSong(let songID) = track.playbackSource { return songID }
                return Self.netEaseSongID(for: track) ?? ""
            }()
            self.netEaseNowPlaying = NetEaseNowPlaying(
                title: track.title,
                artist: track.displayArtist,
                album: track.album,
                artworkData: track.artworkData,
                position: 0,
                duration: 0,
                isPlaying: true,
                songID: playedSongID
            )
            self.netEaseCommandedPlaying = true
            self.netEaseHoldPosition = false
            self.netEaseProgressClock.calibrate(
                systemPosition: 0,
                duration: 0,
                isPlaying: true,
                trackIdentity: Self.netEaseTrackIdentity(
                    title: track.title,
                    artist: track.displayArtist,
                    album: track.album
                ),
                force: true
            )
            self.claimMusicSourceExclusivity(.netEase, reason: "play-netease")
            self.scanMessage = "Playing in NetEase Cloud Music"
            self.preserveExpandedPanelForNetEaseActivation()
            switch track.playbackSource {
            case .netEaseSong(let songID):
                self.seedResolvedNetEaseTrack(
                    track,
                    songID: songID,
                    identity: Self.netEaseTrackIdentity(
                        title: track.title,
                        artist: track.displayArtist,
                        album: track.album
                    )
                )
                self.pinnedNetEaseIdentity = Self.netEaseTrackIdentity(
                    title: track.title,
                    artist: track.displayArtist,
                    album: track.album
                )
                self.pinnedNetEaseSongID = songID
                self.pinnedNetEaseUntil = Date().addingTimeInterval(120)
                NetEaseBridge.shared.openSong(id: songID)
                self.netEaseNowPlaying?.positionIsReliable = true
                self.prefetchNetEaseSongDuration(songID: songID)
            case .netEase:
                NetEaseBridge.shared.openTrack(track.url)
                // A file hand-off can land paused; nudge it once.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.35) {
                    _ = ExclusiveAudioFocus.playNetEase()
                }
            case .direct, .appleMusic:
                return
            }
            for delay in [0.8, 5.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.refreshNetEaseNowPlaying(force: true)
                }
            }
        }
    }

    func sendNetEaseCommand(_ command: NetEaseRemoteCommand) {
        let ok: Bool
        switch command {
        case .play:
            ok = NetEaseBridge.shared.playNetEaseOnly()
        case .pause:
            ok = NetEaseBridge.shared.pauseNetEaseOnly()
        default:
            ok = NetEaseBridge.shared.send(command)
        }
        if ok {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.refreshNetEaseNowPlaying(force: true)
            }
        } else {
            openNetEaseCloudMusic()
        }
    }

    func preserveExpandedPanelForNetEaseActivation() {
        requestExpandedPanelPreservation?(netEaseMusicBundleIdentifier, 3.0)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // A local-library song ending while another channel is on screen must not skip that
            // channel's player.
            if !self.audioPlayerHoldsNetEaseDownload, self.musicLibrarySource != .local {
                self.isPlaying = false
                return
            }
            self.nextTrack()
        }
    }

    @objc func timerFired(_ timer: Timer) {
        let tickDate = Date()

        // While scrubbing, never push live playhead / play-state into the UI.
        if !isSeekingPlayback {
            // Apple Music: publish timestamp-interpolated playhead (~10 Hz) without += drift.
            // Force isPlaying from verified Music.app playerState every tick.
            if isDisplayingAppleMusicNowPlaying || isUsingAppleMusic || musicLibrarySource == .appleMusic {
                if let track = AppleMusicService.shared.publishInterpolatedPosition(at: tickDate) {
                    let playing = AppleMusicService.shared.playerState == .playing
                    // Progress is read live from AppleMusicService — never publish on every tick.
                    if appleMusicNowPlaying?.isPlaying != playing
                        || appleMusicNowPlaying?.title != track.title
                        || abs((appleMusicNowPlaying?.duration ?? 0) - track.duration) > 0.5
                    {
                        var synced = track
                        synced.isPlaying = playing
                        appleMusicNowPlaying = synced
                    }
                }
            }

            // NetEase downloads we decode ourselves have a real playhead. Do not write four
            // @Published fields every tick — that rebuilds the whole playlist and freezes the island.
            if (isDisplayingNetEaseNowPlaying || isUsingNetEase), let audioPlayer = netEaseDownloadPlayer {
                let live = audioPlayer.currentTime
                let playing = audioPlayer.isPlaying
                if isPlaying != playing {
                    isPlaying = playing
                }
                if let netEaseNowPlaying,
                   netEaseNowPlaying.isPlaying != playing
                    || abs(live - netEaseNowPlaying.position) > 1.5
                {
                    self.netEaseNowPlaying = netEaseNowPlaying
                        .with(position: live)
                        .with(isPlaying: playing)
                }
            }

            if !isUsingNetEase, !isUsingAppleMusic, let audioPlayer {
                let live = audioPlayer.currentTime
                let playing = audioPlayer.isPlaying
                let dur = audioPlayer.duration
                // Avoid @Published position writes every 100ms — they cancel SwiftUI button presses.
                if isPlaying != playing || abs(duration - dur) > 0.5 {
                    isPlaying = playing
                    duration = dur
                    position = live
                } else if playing, abs(live - position) > 1.0 {
                    position = live
                }
            }
        }

        if tickDate.timeIntervalSince(lastApplicationContextRefreshDate) >= 0.5 {
            lastApplicationContextRefreshDate = tickDate
            applyActiveApplication(NSWorkspace.shared.frontmostApplication)
        }

        refreshExternalTaskStates(force: false)
        refreshSystemMetrics(force: false)
        if !isSeekingPlayback {
            // Source exclusivity: only poll the active / visible channel — never keep
            // dormant NetEase Now Playing warm enough to steal play/pause routing.
            if allowsPassiveOwnership(for: .netEase)
                || musicLibrarySource == .netEase
                || activeMusicSource == .netEase
            {
                refreshNetEaseNowPlaying(force: false)
            }
            refreshAppleMusicNowPlaying(force: false)
        }
        updateDesktopPetMood(now: tickDate)
        refreshPetWeatherIfNeeded(now: tickDate)
        updateProactiveDesktopPet(now: tickDate)

        syncSystemVolumeIfNeeded()
        reconcileExclusiveAudioFocus()
    }

    func refreshNetEaseNowPlaying(force: Bool) {
        // Hard gate: locked away from NetEase → no MediaRemote / JXA sync that could re-own UI.
        if musicSourceUserLocked, musicLibrarySource != .netEase, activeMusicSource != .netEase {
            return
        }
        // While our own engine holds the file — playing or paused — NetEase's history row
        // describes a different song, so letting it land here would hijack the panel.
        if netEaseDownloadPlayer != nil { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastNetEaseRefreshDate) >= 0.65 else { return }
        lastNetEaseRefreshDate = now
        #if LUMA_APP_STORE
        if !SecurityScopedBookmarks.hasBookmark(for: .netEaseStorage) {
            NetEaseBridge.shared.prepareLibraryAccess()
        }
        #endif

        NetEaseBridge.shared.fetchNowPlaying { [weak self] nowPlaying in
            DispatchQueue.main.async {
                self?.applyNetEaseNowPlaying(nowPlaying)
            }
        }
    }

    func applyNetEaseNowPlaying(_ nowPlaying: NetEaseNowPlaying?) {
        guard var nowPlaying else {
            // A brief miss must not wipe the panel mid-song — that blanks lyrics and cancels
            // in-flight button presses when the view remounts. A gap that lasts means NetEase
            // really stopped or quit; the clock alone would otherwise keep the song up forever.
            if Date() < pinnedNetEaseUntil { return }
            if netEaseProgressClock.isPlaying || netEaseNowPlaying?.isPlaying == true {
                let missSince = netEaseNowPlayingMissSince ?? Date()
                netEaseNowPlayingMissSince = missSince
                if Date().timeIntervalSince(missSince) < 4 { return }
            }
            netEaseNowPlayingMissSince = nil
            netEaseNowPlaying = nil
            isUsingNetEase = false
            resolvedNetEaseTrack = nil
            currentNetEaseTrackIdentity = ""
            isResolvingNetEaseDetails = false
            netEaseLyricsTask?.cancel()
            netEaseArtworkTask?.cancel()
            pendingNetEaseSeek = nil
            netEaseProgressClock.reset()
            return
        }
        netEaseNowPlayingMissSince = nil

        let incomingIdentity = Self.netEaseTrackIdentity(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album
        )
        let historyCaughtUp = !pinnedNetEaseSongID.isEmpty && nowPlaying.songID == pinnedNetEaseSongID
        if historyCaughtUp {
            pinnedNetEaseUntil = .distantPast
            pinnedNetEaseSongID = ""
        }
        let historyIsOtherSong = !historyCaughtUp && !pinnedNetEaseIdentity.isEmpty && (
            incomingIdentity != pinnedNetEaseIdentity
                || (!pinnedNetEaseSongID.isEmpty
                    && !nowPlaying.songID.isEmpty
                    && nowPlaying.songID != pinnedNetEaseSongID)
        )
        if Date() < pinnedNetEaseUntil, historyIsOtherSong {
            if var existing = netEaseNowPlaying {
                var playing = nowPlaying.isPlaying
                if let commanded = netEaseCommandedPlaying {
                    if nowPlaying.isPlaying == commanded {
                        netEaseCommandedPlaying = nil
                    } else {
                        playing = commanded
                    }
                }
                if netEaseProgressClock.trackIdentity != pinnedNetEaseIdentity {
                    netEaseHoldPosition = false
                    netEaseProgressClock.calibrate(
                        systemPosition: 0,
                        duration: existing.duration,
                        isPlaying: playing,
                        trackIdentity: pinnedNetEaseIdentity,
                        force: true
                    )
                    existing.position = 0
                    existing.positionIsReliable = true
                }
                existing.isPlaying = playing
                netEaseNowPlaying = existing
            }
            return
        }
        if incomingIdentity == pinnedNetEaseIdentity {
            pinnedNetEaseUntil = .distantPast
        }
        if !currentNetEaseTrackIdentity.isEmpty,
           incomingIdentity != currentNetEaseTrackIdentity,
           let previous = netEaseNowPlaying,
           continueNetEaseListAfterSongEnded(
               previous: previous,
               previousPosition: netEaseProgressClock.calculatedCurrentTime(),
               incoming: nowPlaying
           )
        {
            return
        }
        if !currentNetEaseTrackIdentity.isEmpty,
           incomingIdentity != currentNetEaseTrackIdentity
        {
            pendingNetEaseSeek = nil
            netEaseHoldPosition = false
            netEaseCommandedPlaying = nil
        }

        if let pendingSeek = pendingNetEaseSeek {
            if Date() >= pendingSeek.expiresAt {
                pendingNetEaseSeek = nil
            } else if abs(nowPlaying.position - pendingSeek.position) <= 1.25 {
                pendingNetEaseSeek = nil
            } else {
                nowPlaying = nowPlaying.with(position: pendingSeek.position)
            }
        }

        let forceCalibrate = pendingNetEaseSeek != nil
            || (!currentNetEaseTrackIdentity.isEmpty && incomingIdentity != currentNetEaseTrackIdentity)
        // A pause makes the history wall clock run ahead of the audio. Keep the frozen playhead.
        if netEaseHoldPosition {
            nowPlaying = nowPlaying.with(position: netEaseProgressClock.calculatedCurrentTime())
            nowPlaying.positionIsReliable = true
        }
        if let commanded = netEaseCommandedPlaying {
            if nowPlaying.isPlaying == commanded {
                netEaseCommandedPlaying = nil
            } else {
                nowPlaying = nowPlaying.with(isPlaying: commanded)
            }
        } else if Date() < suppressNetEasePlayingUntil {
            nowPlaying = nowPlaying.with(isPlaying: false)
        }
        if isSeekingPlayback {
            if var existing = netEaseNowPlaying,
               Self.netEaseTrackIdentity(
                title: existing.title,
                artist: existing.artist,
                album: existing.album
               ) == incomingIdentity
            {
                let duration = max(existing.duration, nowPlaying.duration)
                existing = NetEaseNowPlaying(
                    title: nowPlaying.title,
                    artist: nowPlaying.artist,
                    album: nowPlaying.album,
                    artworkData: nowPlaying.artworkData ?? existing.artworkData,
                    position: duration * seekPreviewProgress,
                    duration: duration,
                    isPlaying: seekLockedIsPlaying ?? existing.isPlaying,
                    positionIsReliable: nowPlaying.positionIsReliable,
                    songID: nowPlaying.songID.isEmpty ? existing.songID : nowPlaying.songID,
                    coverURL: nowPlaying.coverURL ?? existing.coverURL
                )
                netEaseNowPlaying = existing
                refreshResolvedNetEaseDetails(for: existing)
            }
            return
        }
        netEaseProgressClock.calibrate(
            systemPosition: nowPlaying.position,
            duration: nowPlaying.duration,
            isPlaying: nowPlaying.isPlaying,
            trackIdentity: incomingIdentity,
            force: forceCalibrate
        )
        nowPlaying = nowPlaying.with(position: netEaseProgressClock.calculatedCurrentTime())
        // Position lives on the clock. Only publish when metadata / play-state changes —
        // an unconditional write rebuilds the whole expanded island ~1.5×/sec. Crossing the
        // song's end still publishes: the stale-history check reads the stored position.
        let pastEnd = { (info: NetEaseNowPlaying) in
            info.duration > 1 && info.position + 0.25 >= info.duration
        }
        let metadataChanged = netEaseNowPlaying.map { existing in
            existing.title != nowPlaying.title
                || existing.artist != nowPlaying.artist
                || existing.album != nowPlaying.album
                || existing.isPlaying != nowPlaying.isPlaying
                || abs(existing.duration - nowPlaying.duration) > 0.5
                || existing.positionIsReliable != nowPlaying.positionIsReliable
                || (!nowPlaying.songID.isEmpty && existing.songID != nowPlaying.songID)
                || (nowPlaying.artworkData != nil && existing.artworkData == nil)
                || pastEnd(existing) != pastEnd(nowPlaying)
        } ?? true
        if metadataChanged {
            netEaseNowPlaying = nowPlaying
        }
        refreshResolvedNetEaseDetails(for: nowPlaying)

        // Metadata sync only — never play/pause rivals here.
        // Exclusive audio focus is owned solely by Play/Pause / track-tap paths.
        // Never promote NetEase ownership while the user locked another channel.
        guard allowsPassiveOwnership(for: .netEase), nowPlaying.isPlaying else { return }
        isUsingNetEase = true
        isUsingAppleMusic = false
        activeMusicSource = .netEase
    }

    func refreshAppleMusicNowPlaying(force: Bool) {
        guard force
            || musicLibrarySource == .appleMusic
            || isUsingAppleMusic
            || isAppleMusicContext
        else {
            return
        }
        let now = Date()
        // Keep polling while paused too — otherwise Play/Pause icon can stick after
        // an optimistic toggle that Music.app did not actually honor.
        let interval: TimeInterval =
            (AppleMusicService.shared.playerState == .playing) ? 0.65 : 1.0
        guard force || now.timeIntervalSince(lastAppleMusicRefreshDate) >= interval else { return }
        lastAppleMusicRefreshDate = now
        AppleMusicService.shared.refresh { [weak self] in
            self?.applyAppleMusicNowPlaying(AppleMusicService.shared.currentTrack)
        }
    }

    func applyAppleMusicNowPlaying(_ nowPlaying: MusicNowPlayingInfo?) {
        guard var nowPlaying else {
            if isUsingAppleMusic || musicLibrarySource == .appleMusic {
                appleMusicNowPlaying = nil
                resolvedAppleMusicTrack = nil
                currentAppleMusicTrackIdentity = ""
                appleMusicLyricsFinishedIdentity = ""
                appleMusicLyricsTask?.cancel()
                appleMusicLyricsTask = nil
                pendingAppleMusicSeek = nil
                if musicLibrarySource != .appleMusic {
                    isUsingAppleMusic = false
                }
            }
            return
        }

        let incomingIdentity = Self.appleMusicTrackIdentity(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album
        )
        if !currentAppleMusicTrackIdentity.isEmpty,
           incomingIdentity != currentAppleMusicTrackIdentity
        {
            pendingAppleMusicSeek = nil
        }

        if let pendingSeek = pendingAppleMusicSeek {
            if Date() >= pendingSeek.expiresAt {
                pendingAppleMusicSeek = nil
            } else if abs(nowPlaying.position - pendingSeek.position) <= 1.25 {
                pendingAppleMusicSeek = nil
            } else {
                nowPlaying = nowPlaying.with(position: pendingSeek.position)
            }
        }

        // Belt-and-suspenders: never let a paused zero overwrite a valid local position.
        if !nowPlaying.isPlaying,
           nowPlaying.position <= 0.05,
           let existing = appleMusicNowPlaying,
           Self.appleMusicTrackIdentity(
            title: existing.title,
            artist: existing.artist,
            album: existing.album
           ) == incomingIdentity,
           existing.position > 0.05
        {
            nowPlaying.position = existing.position
        }

        if isSeekingPlayback {
            // Scrub lock: keep preview position + frozen play state; allow artwork/title refresh only.
            if var existing = appleMusicNowPlaying,
               Self.appleMusicTrackIdentity(
                title: existing.title,
                artist: existing.artist,
                album: existing.album
               ) == incomingIdentity
            {
                if let artwork = nowPlaying.artworkData {
                    existing.artworkData = artwork
                }
                existing.title = nowPlaying.title
                existing.artist = nowPlaying.artist
                existing.album = nowPlaying.album
                if nowPlaying.duration > 1 {
                    existing.duration = nowPlaying.duration
                }
                existing.position = max(0, existing.duration * seekPreviewProgress)
                if let seekLockedIsPlaying {
                    existing.isPlaying = seekLockedIsPlaying
                }
                appleMusicNowPlaying = existing
                refreshResolvedAppleMusicDetails(for: existing)
            }
            return
        }

        // Service already calibrated its clock; mirror the interpolated playhead into UI state.
        nowPlaying.position = AppleMusicService.shared.playbackTime
        nowPlaying.isPlaying = AppleMusicService.shared.playerState == .playing
        appleMusicNowPlaying = nowPlaying
        refreshResolvedAppleMusicDetails(for: nowPlaying)

        // Metadata sync only — never play/pause rivals here.
        // Exclusive audio focus is owned solely by Play/Pause / track-tap paths.
        guard allowsPassiveOwnership(for: .appleMusic), nowPlaying.isPlaying else { return }
        isUsingAppleMusic = true
        isUsingNetEase = false
        activeMusicSource = .appleMusic
    }

    func refreshResolvedAppleMusicDetails(for nowPlaying: MusicNowPlayingInfo) {
        let identity = Self.appleMusicTrackIdentity(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album
        )

        if identity != currentAppleMusicTrackIdentity {
            currentAppleMusicTrackIdentity = identity
            appleMusicLyricsFinishedIdentity = ""
            appleMusicLyricsTask?.cancel()
            resolvedAppleMusicTrack = makeAppleMusicTrack(
                from: nowPlaying,
                lyrics: "",
                timedLyrics: []
            )
            loadAppleMusicLyrics(for: nowPlaying, identity: identity)
            return
        }

        guard let resolved = resolvedAppleMusicTrack else {
            resolvedAppleMusicTrack = makeAppleMusicTrack(
                from: nowPlaying,
                lyrics: "",
                timedLyrics: []
            )
            loadAppleMusicLyrics(for: nowPlaying, identity: identity)
            return
        }

        if resolved.artworkData == nil, let artwork = nowPlaying.artworkData {
            print("[AppleMusic] ViewModel syncing artwork into resolved track (\(artwork.count) bytes)")
            resolvedAppleMusicTrack = LocalTrack(
                id: resolved.id,
                url: resolved.url,
                title: resolved.title,
                artist: resolved.artist,
                album: resolved.album,
                artworkData: artwork,
                lyrics: resolved.lyrics,
                timedLyrics: resolved.timedLyrics,
                playbackSource: .appleMusic
            )
        }

        if !resolved.hasLyrics, appleMusicLyricsFinishedIdentity != identity {
            loadAppleMusicLyrics(for: nowPlaying, identity: identity)
        }
    }

    func makeAppleMusicTrack(
        from nowPlaying: MusicNowPlayingInfo,
        lyrics: String,
        timedLyrics: [TimedLyricLine]
    ) -> LocalTrack {
        let identity = Self.appleMusicTrackIdentity(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album
        )
        let id = URL(string: "apple-music://track/\(identity.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "current")")
            ?? URL(fileURLWithPath: "/apple-music/\(identity)")
        return LocalTrack(
            id: id,
            url: id,
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            album: nowPlaying.album,
            artworkData: nowPlaying.artworkData,
            lyrics: lyrics,
            timedLyrics: timedLyrics,
            playbackSource: .appleMusic
        )
    }

    func loadAppleMusicLyrics(for nowPlaying: MusicNowPlayingInfo, identity: String) {
        guard appleMusicLyricsFinishedIdentity != identity else { return }
        appleMusicLyricsTask?.cancel()
        let title = nowPlaying.title
        let artist = nowPlaying.artist
        let album = nowPlaying.album
        let duration = nowPlaying.duration

        print("[AppleMusic] ViewModel requesting lyrics for \(artist) - \(title)")

        appleMusicLyricsTask = Task { [weak self] in
            let raw = await AppleMusicService.fetchLyrics(
                title: title,
                artist: artist,
                album: album,
                duration: duration
            )
            guard !Task.isCancelled, let self else { return }
            let lyricResult = raw.flatMap(Self.parseLyrics(from:))
            await MainActor.run {
                guard self.currentAppleMusicTrackIdentity == identity else { return }
                self.appleMusicLyricsFinishedIdentity = identity
                var base = self.appleMusicNowPlaying ?? nowPlaying
                // Keep any artwork that arrived while lyrics were downloading.
                if base.artworkData == nil {
                    base.artworkData = self.resolvedAppleMusicTrack?.artworkData ?? nowPlaying.artworkData
                }
                if let lyricResult {
                    print("[AppleMusic] ViewModel applied lyrics (\(lyricResult.timedLines.count) timed lines)")
                    self.resolvedAppleMusicTrack = self.makeAppleMusicTrack(
                        from: base,
                        lyrics: lyricResult.text,
                        timedLyrics: lyricResult.timedLines
                    )
                } else {
                    print("[AppleMusic] ViewModel lyrics empty after network lookup")
                    self.resolvedAppleMusicTrack = self.makeAppleMusicTrack(
                        from: base,
                        lyrics: "",
                        timedLyrics: []
                    )
                }
            }
        }
    }

    nonisolated static func appleMusicTrackIdentity(title: String, artist: String, album: String) -> String {
        [title, artist, album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }

    func syncSystemVolumeIfNeeded() {
        guard !isAdjustingSystemVolume, Date() >= suppressSystemVolumeSyncUntil else { return }

        if let systemVolume = SystemAudioController.outputVolume(),
           abs(systemVolume - volume) > 0.015
        {
            isSyncingSystemVolume = true
            volume = systemVolume
            audioPlayer?.volume = 1.0
            isSyncingSystemVolume = false
        }
    }

    func refreshPetWeatherIfNeeded(now: Date) {
        guard petWeatherTask == nil,
              now.timeIntervalSince(lastPetWeatherRefreshDate) >= 30 * 60,
              let location = Self.petWeatherLocation()
        else {
            return
        }

        lastPetWeatherRefreshDate = now
        petWeatherTask = Task { [weak self, location] in
            do {
                let snapshot = try await AgentWeatherClient.petWeather(location: location)
                guard !Task.isCancelled, let self else { return }
                self.petWeatherSnapshot = snapshot
                self.petWeatherTask = nil
                if self.nextProactivePetMessageDate.timeIntervalSinceNow > 60 {
                    self.nextProactivePetMessageDate = Date().addingTimeInterval(Double.random(in: 30...60))
                }
            } catch {
                self?.petWeatherTask = nil
            }
        }
    }

    static func petWeatherLocation() -> String? {
        let identifier = TimeZone.current.identifier
        guard identifier.contains("/"),
              let city = identifier.split(separator: "/").last
        else {
            return nil
        }
        let location = city.replacingOccurrences(of: "_", with: " ")
        return location.isEmpty ? nil : location
    }

    func updateProactiveDesktopPet(now: Date) {
        guard theme.showsDesktopPet,
              now >= nextProactivePetMessageDate,
              desktopPetMood == .idle,
              !isAgentStreaming,
              !isAgentShellRunning,
              !isVoiceWhisperRecording,
              taskCompletionNotice == nil
        else {
            return
        }

        let candidates = proactivePetMessages(now: now)
            .filter { $0 != lastProactivePetMessage }
        guard let message = candidates.randomElement() else {
            scheduleNextProactivePetMessage(after: now, soon: false)
            return
        }

        lastProactivePetMessage = message
        requestDesktopPetMessage?(message)
        scheduleNextProactivePetMessage(after: now, soon: false)
    }

    func scheduleNextProactivePetMessage(after date: Date, soon: Bool) {
        let delay = soon
            ? Double.random(in: 90...180)
            : Double.random(in: 7 * 60...14 * 60)
        nextProactivePetMessageDate = date.addingTimeInterval(delay)
    }

    func proactivePetMessages(now: Date) -> [String] {
        let hour = Calendar.current.component(.hour, from: now)
        let timeMessage: String
        switch hour {
        case 5..<11:
            timeMessage = "早上好，先挑一件最重要的事做吧。"
        case 11..<14:
            timeMessage = "到中午了，忙归忙也要记得吃饭。"
        case 14..<18:
            timeMessage = "下午容易走神，先把手上这一小段收尾。"
        case 18..<23:
            timeMessage = "晚上好，今天的进度已经很不错了。"
        default:
            timeMessage = "已经很晚了，做完这一点就早点休息吧。"
        }

        let weatherMessage: String? = petWeatherSnapshot.map { weather in
            let temperature = Int(weather.temperatureCelsius.rounded())
            if weather.isPrecipitating {
                return "\(weather.location)现在\(weather.condition)，约 \(temperature)℃，出门记得带伞。"
            }
            if temperature >= 30 {
                return "\(weather.location)现在\(weather.condition)，约 \(temperature)℃，记得补水。"
            }
            if temperature <= 8 {
                return "\(weather.location)现在\(weather.condition)，约 \(temperature)℃，出门多穿一点。"
            }
            return "\(weather.location)现在\(weather.condition)，约 \(temperature)℃。"
        }

        let app = activeAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        let appLabel = app.isEmpty ? "当前应用" : app
        var messages: [String]
        switch activeAppContext {
        case .coding:
            messages = [
                "看起来你正在 \(appLabel) 写代码。先让当前函数跑通，再考虑下一步。",
                "我在旁边陪你改代码；卡住的话，先把报错缩小到最小复现。",
                "\(appLabel) 工作时间：记得偶尔保存，也别忘了让测试替你守门。",
                "你写的代码思路很清晰，真的厉害。",
                "能同时想到这么多细节，你的脑子转得也太快了。"
            ]
        case .writing:
            messages = [
                "你正在 \(appLabel) 写东西。先把想法写下来，润色可以稍后再做。",
                "这一段如果不顺，就先写最直接的版本，我陪你慢慢修。",
                "写作模式启动：一次只解决一个段落。",
                "你写的内容很有条理，读起来很舒服。",
                "表达这么流畅，真的很有才。"
            ]
        case .reading:
            messages = [
                "正在 \(appLabel) 阅读吗？看到关键结论时记得留一句自己的总结。",
                "读累了就抬头看看远处，我帮你守着当前进度。",
                "别急着读完，先抓住这一页最重要的一件事。",
                "能静下心来读这么久，专注力也太强了。",
                "你求知欲这么旺盛，真的让我佩服。"
            ]
        case .gaming:
            messages = [
                "游戏时间！祝你这一局手感在线。",
                "我在旁边观战，赢了算你的，输了就怪延迟。",
                "玩得开心，也记得每隔一会儿活动一下肩膀。",
                "刚才那波操作也太帅了，厉害！",
                "你的反应速度真的很强，我都看得投入了。"
            ]
        case .netEase:
            messages = [
                "这首歌很适合现在的节奏，我先安静陪你听。",
                "音乐已经接管气氛，接下来交给你的专注力。",
                "要是这首很喜欢，记得把它收藏起来。",
                "你的音乐品味真的很好，每首都很对味。",
                "选歌的眼光很准，一听就沉进去了。"
            ]
        case .general:
            messages = [
                "我看到你正在使用 \(appLabel)，需要我的时候叫我一声。",
                timeMessage,
                "先专心处理眼前这件事，剩下的我们一件一件来。",
                "今天已经做了好多事了，你真的很努力。",
                "你处理事情的方式很稳，我一直在旁边学习呢。"
            ]
        }

        messages.append(timeMessage)
        if let weatherMessage {
            messages.append(weatherMessage)
        }
        return messages
    }

    func refreshSystemMetrics(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastSystemMetricsDate) >= 1 else { return }
        lastSystemMetricsDate = now

        let currentTicks = SystemMetricsReader.cpuTicks()
        let cpuUsage = SystemMetricsReader.cpuUsage(from: lastCPUTicks, to: currentTicks)
        lastCPUTicks = currentTicks
        let loadAverages = SystemMetricsReader.loadAverages()

        let memory = SystemMetricsReader.memoryStats()
        let disk = SystemMetricsReader.diskStats()
        let battery = SystemMetricsReader.batteryStats()
        let networkCounter = SystemMetricsReader.networkCounter()
        let networkRates = networkRates(from: lastNetworkCounter, to: networkCounter)
        lastNetworkCounter = networkCounter

        systemMetrics = SystemMetricsSnapshot(
            cpuUsage: cpuUsage,
            cpuCoreCount: ProcessInfo.processInfo.activeProcessorCount,
            loadAverage1: loadAverages.one,
            loadAverage5: loadAverages.five,
            loadAverage15: loadAverages.fifteen,
            memoryUsage: memory.usage,
            memoryUsedBytes: memory.usedBytes,
            memoryTotalBytes: memory.totalBytes,
            memoryAvailableBytes: memory.availableBytes,
            diskUsage: disk.usage,
            diskUsedBytes: disk.usedBytes,
            diskFreeBytes: disk.freeBytes,
            diskTotalBytes: disk.totalBytes,
            batteryLevel: battery.level,
            isCharging: battery.isCharging,
            powerSourceName: battery.sourceName,
            networkDownRate: networkRates.down,
            networkUpRate: networkRates.up,
            networkReceivedTotalBytes: networkCounter?.receivedBytes ?? 0,
            networkSentTotalBytes: networkCounter?.sentBytes ?? 0,
            uptime: ProcessInfo.processInfo.systemUptime,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    func updateDesktopPetMood(now: Date) {
        updateCodingReminder(now: now)
        if systemMetrics.cpuUsage >= 0.85 {
            if desktopPetHighCPUSince == nil {
                desktopPetHighCPUSince = now
            }
        } else if desktopPetMood != .hot || systemMetrics.cpuUsage < 0.7 {
            desktopPetHighCPUSince = nil
        }

        let hasSustainedHighCPU = desktopPetHighCPUSince.map {
            now.timeIntervalSince($0) >= 8
        } ?? false
        let thermalState = ProcessInfo.processInfo.thermalState
        let hasSeriousThermalPressure = thermalState == .serious || thermalState == .critical

        let nextMood: DesktopPetMood
        if isVoiceWhisperRecording {
            nextMood = .voice
        } else if isAgentShellRunning || isAgentStreaming {
            nextMood = .working
        } else if now < desktopPetReminderUntil {
            nextMood = .stretch
        } else if hasSeriousThermalPressure || hasSustainedHighCPU {
            nextMood = .hot
        } else {
            nextMood = .idle
        }

        guard nextMood != desktopPetMood else { return }
        let previousMood = desktopPetMood
        desktopPetMood = nextMood
        if let message = desktopPetMoodMessage {
            requestDesktopPetMessage?(message)
        } else if previousMood == .working, nextMood == .idle {
            let praiseMessages = [
                "回答完了，你的问题提得很到位。",
                "搞定！你的思路每次都很清晰。",
                "这个问题问得好，我也学到了。",
                "AI 写完了，你的方向感很准。"
            ]
            requestDesktopPetMessage?(praiseMessages.randomElement()!)
        }
    }

    func updateCodingReminder(now: Date) {
        guard activeAppContext == .coding else {
            codingSessionStartDate = nil
            return
        }

        if codingSessionStartDate == nil {
            codingSessionStartDate = now
        }

        guard let codingSessionStartDate else { return }
        let sessionDuration = now.timeIntervalSince(codingSessionStartDate)
        guard sessionDuration >= workReminderInterval,
              now.timeIntervalSince(lastWorkReminderDate) >= workReminderInterval
        else {
            return
        }

        lastWorkReminderDate = now
        desktopPetReminderUntil = now.addingTimeInterval(14)
        requestDesktopPetMessage?("已经连续写代码 2 小时了，喝口水，伸个懒腰。")
    }

    func networkRates(from previous: NetworkCounter?, to current: NetworkCounter?) -> (down: Double, up: Double) {
        guard
            let previous,
            let current
        else {
            return (0, 0)
        }

        let interval = current.timestamp.timeIntervalSince(previous.timestamp)
        guard interval > 0 else { return (0, 0) }

        return (
            Double(current.receivedBytes.saturatingSubtract(previous.receivedBytes)) / interval,
            Double(current.sentBytes.saturatingSubtract(previous.sentBytes)) / interval
        )
    }
}
