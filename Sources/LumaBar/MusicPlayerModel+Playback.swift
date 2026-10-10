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
    func prepareCurrentTrack() {
        guard let track = currentTrack else {
            audioPlayer = nil
            position = 0
            duration = 0
            isPlaying = false
            return
        }

        guard musicLibrarySource == .local || Self.isLocallyPlayableFile(track) else {
            audioPlayer = nil
            position = 0
            duration = 0
            isPlaying = false
            return
        }

        guard Self.isLocallyPlayableFile(track) else {
            audioPlayer = nil
            position = 0
            duration = 0
            isPlaying = false
            return
        }

        prepareDirectTrack(track)
    }

    func prepareDirectTrack(_ track: LocalTrack) {
        audioPlayerHoldsNetEaseDownload = false
        guard Self.isLocallyPlayableFile(track) else {
            audioPlayer = nil
            position = 0
            duration = 0
            isPlaying = false
            return
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: track.url)
            audioPlayer?.delegate = self
            audioPlayer?.volume = SystemAudioController.outputVolume() == nil ? Float(volume) : 1.0
            audioPlayer?.prepareToPlay()
            position = 0
            duration = audioPlayer?.duration ?? 0
            isPlaying = false
        } catch {
            scanMessage = "Cannot play \(track.title)"
            audioPlayer = nil
            position = 0
            duration = 0
            isPlaying = false
        }
    }

    func togglePlayback() {
        dismissTaskCompletionNoticeForInteraction()

        let applePlaying =
            (appleMusicNowPlaying?.isPlaying == true) || AppleMusicService.shared.isPlaying
        let localPlaying = audioPlayer?.isPlaying == true

        // Library channel the user selected is the absolute control surface —
        // never let a dormant Now Playing snapshot steal the Play button.
        switch musicLibrarySource {
        case .appleMusic:
            executeTargetedPlayPause(target: .appleMusic, currentlyPlaying: applePlaying)
            return
        case .netEase:
            if let audioPlayer = netEaseDownloadPlayer {
                if audioPlayer.isPlaying || isPlaying {
                    audioPlayer.pause()
                    isPlaying = false
                    if let netEaseNowPlaying {
                        self.netEaseNowPlaying = netEaseNowPlaying.with(isPlaying: false)
                    }
                    netEaseProgressClock.lockForPause()
                } else {
                    isPlaying = audioPlayer.play()
                    if let netEaseNowPlaying {
                        self.netEaseNowPlaying = netEaseNowPlaying.with(isPlaying: isPlaying)
                    }
                    if isPlaying {
                        netEaseProgressClock.resumePlayback()
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = ExclusiveAudioFocus.pauseNetEase(likelyPlaying: true)
                    }
                }
                return
            }
            // Audible output lags a pause by seconds and sometimes never clears. Follow the last
            // command so the second press resumes instead of sending pause again.
            executeTargetedPlayPause(
                target: .netEase,
                currentlyPlaying: netEaseCommandedPlaying ?? netEaseReportedPlaying
            )
            return
        case .local:
            break
        }

        // Local channel: only local / explicitly owned backends — never "netEaseNowPlaying != nil".
        if localPlaying || (activeMusicSource == .local && audioPlayer != nil) {
            if localPlaying || isPlaying {
                audioPlayer?.pause()
                isPlaying = false
            } else if let audioPlayer {
                ensureSinglePlayerPlaying(target: .local) {
                    self.isPlaying = audioPlayer.play()
                }
            }
            return
        }

        if activeMusicSource == .appleMusic || (isUsingAppleMusic && applePlaying) {
            executeTargetedPlayPause(target: .appleMusic, currentlyPlaying: applePlaying)
            return
        }

        // Idle local — prefer local engine / current track; do not fall through to NetEase
        // merely because a stale NetEase snapshot exists in memory.
        let idleTarget = resolvedExclusivePlaybackTarget()
        switch idleTarget {
        case .appleMusic:
            executeTargetedPlayPause(target: .appleMusic, currentlyPlaying: false)
            return
        case .netEase:
            // Only if local channel somehow still points at NetEase ownership (unlocked legacy).
            if !musicSourceUserLocked, isUsingNetEase {
                executeTargetedPlayPause(target: .netEase, currentlyPlaying: displayedIsPlaying)
                return
            }
        case .local:
            break
        }

        if let currentTrack, currentTrack.playbackSource == .direct {
            if audioPlayer == nil {
                ensureSinglePlayerPlaying(target: .local) {
                    self.playDirectTrack(currentTrack)
                }
                return
            }

            if isPlaying {
                audioPlayer?.pause()
                isPlaying = false
            } else {
                ensureSinglePlayerPlaying(target: .local) {
                    self.isPlaying = self.audioPlayer?.play() ?? false
                }
            }
            return
        }

        if shouldRouteControlsToSystemPlayer {
            // Spotify / VLC / IINA — silence AM + NetEase only; never NX_KEYTYPE / MediaRemote play.
            pauseLocalPlaybackEngine()
            markAppleMusicPausedInUI()
            markNetEasePausedInUI()
            DispatchQueue.global(qos: .userInitiated).async {
                ExclusiveAudioFocus.pauseAppleMusic()
                ExclusiveAudioFocus.pauseNetEase()
            }
            return
        }

        guard !tracks.isEmpty else {
            if musicLibrarySource == .appleMusic || appleMusicNowPlaying != nil {
                executeTargetedPlayPause(target: .appleMusic, currentlyPlaying: false)
            } else if musicLibrarySource == .netEase {
                executeTargetedPlayPause(target: .netEase, currentlyPlaying: displayedIsPlaying)
            } else {
                scanLocalMusic()
            }
            return
        }

        // Local channel: never launch a NetEase-backed catalog row as a hijack path.
        if !musicSourceUserLocked || musicLibrarySource == .netEase,
           let currentTrack, currentTrack.playbackSource.isNetEaseBacked
        {
            ensureSinglePlayerPlaying(target: .netEase) {
                self.playNetEaseTrack(currentTrack)
            }
            return
        }

        if audioPlayer == nil {
            prepareCurrentTrack()
        }

        if isPlaying {
            audioPlayer?.pause()
            isPlaying = false
        } else {
            ensureSinglePlayerPlaying(target: .local) {
                self.isPlaying = self.audioPlayer?.play() ?? false
            }
        }
    }

    /// Explicit Play/Pause hub — the only path that may change external playback state.
    /// On play: hard-silence rivals first (blocking), then play the target immediately.
    /// On pause: pause only the target (rivals stay as-is).
    func executeTargetedPlayPause(
        target: IslandMusicLibrarySource,
        currentlyPlaying: Bool
    ) {
        exclusivePlayGeneration &+= 1
        let generation = exclusivePlayGeneration

        activeMusicSource = target
        musicSourceUserLocked = true
        musicLibrarySourceUserPinUntil = .distantFuture
        if musicLibrarySource != target {
            musicLibrarySource = target
        }
        // Prefer live Now Playing; fall back to ownership flag when MR lags after a channel switch.
        let netEaseLikelyPlaying =
            (netEaseNowPlaying?.isPlaying == true) || (isUsingNetEase && target != .netEase)

        switch target {
        case .appleMusic:
            isUsingAppleMusic = true
            isUsingNetEase = false
            pauseLocalPlaybackEngine()
            if currentlyPlaying {
                markAppleMusicPausedInUI()
            } else {
                markNetEasePausedInUI()
            }
        case .netEase:
            isUsingNetEase = true
            isUsingAppleMusic = false
            pauseLocalPlaybackEngine()
            if currentlyPlaying {
                forceNetEaseLocalPaused()
            } else {
                markAppleMusicPausedInUI()
                forceNetEaseLocalPlaying()
            }
        case .local:
            isUsingAppleMusic = false
            isUsingNetEase = false
            markAppleMusicPausedInUI()
            markNetEasePausedInUI()
        }
        syncMusicLibrarySourceToActivePlayback(force: false)

        let appleTrackKnown = appleMusicNowPlaying != nil || AppleMusicService.shared.currentTrack != nil
        if target == .appleMusic, !currentlyPlaying {
            // Move the playhead immediately. Waiting for Music's scripting reply leaves the
            // bar at 0:00 until `player position` finally comes back.
            AppleMusicService.shared.applyOptimisticIsPlaying(true)
            if var info = appleMusicNowPlaying {
                info.isPlaying = true
                info.position = AppleMusicService.shared.playbackTime
                appleMusicNowPlaying = info
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if currentlyPlaying {
                // Pause only the selected app — do not poke rivals (Space would toggle NetEase).
                switch target {
                case .appleMusic:
                    ExclusiveAudioFocus.pauseAppleMusic()
                case .netEase:
                    _ = ExclusiveAudioFocus.pauseNetEase(likelyPlaying: true)
                case .local:
                    break
                }
            } else {
                // Exclusive play: silence rivals FIRST (blocking), then play — no gap for dual audio.
                ExclusiveAudioFocus.silenceRivals(
                    of: target,
                    netEaseLikelyPlaying: netEaseLikelyPlaying
                )
                switch target {
                case .appleMusic:
                    ExclusiveAudioFocus.playAppleMusic(knownTrack: appleTrackKnown)
                case .netEase:
                    _ = ExclusiveAudioFocus.playNetEase()
                case .local:
                    break
                }
            }

            DispatchQueue.main.async {
                guard let self, self.exclusivePlayGeneration == generation else { return }
                if target == .appleMusic {
                    if !currentlyPlaying {
                        AppleMusicService.shared.applyOptimisticIsPlaying(true)
                    }
                    AppleMusicService.shared.refresh {
                        self.applyAppleMusicNowPlaying(AppleMusicService.shared.currentTrack)
                    }
                } else if target == .netEase {
                    if currentlyPlaying {
                        self.forceNetEaseLocalPaused()
                    } else {
                        self.forceNetEaseLocalPlaying()
                    }
                    self.refreshNetEaseNowPlaying(force: true)
                }
            }
        }
    }

    /// Which backend should own the next play/pause from the island controls.
    func resolvedExclusivePlaybackTarget() -> IslandMusicLibrarySource {
        // User-selected library tab is absolute while exclusivity is locked.
        if musicSourceUserLocked {
            return musicLibrarySource
        }
        switch musicLibrarySource {
        case .appleMusic:
            return .appleMusic
        case .netEase:
            return .netEase
        case .local:
            if activeMusicSource == .appleMusic, appleMusicNowPlaying != nil {
                return .appleMusic
            }
            if activeMusicSource == .local || audioPlayer != nil {
                return .local
            }
            if isUsingAppleMusic, appleMusicNowPlaying != nil {
                return .appleMusic
            }
            return .local
        }
    }

    /// Pause every rival (blocking), then play only `target` — no deferred gap for dual audio.
    /// Never synthesizes NX_KEYTYPE_PLAY / global media keys.
    func ensureSinglePlayerPlaying(
        target: IslandMusicLibrarySource,
        playAction: (() -> Void)? = nil
    ) {
        exclusivePlayGeneration &+= 1
        let generation = exclusivePlayGeneration
        let netEaseLikelyPlaying =
            (netEaseNowPlaying?.isPlaying == true) || (isUsingNetEase && target != .netEase)

        activeMusicSource = target
        musicSourceUserLocked = true
        musicLibrarySourceUserPinUntil = .distantFuture
        switch target {
        case .appleMusic:
            isUsingAppleMusic = true
            isUsingNetEase = false
            pauseLocalPlaybackEngine()
            markNetEasePausedInUI()
        case .netEase:
            isUsingNetEase = true
            isUsingAppleMusic = false
            pauseLocalPlaybackEngine()
            markAppleMusicPausedInUI()
        case .local:
            isUsingAppleMusic = false
            isUsingNetEase = false
            markAppleMusicPausedInUI()
            markNetEasePausedInUI()
        }
        // Keep the visible channel aligned with intentional play without unlocking exclusivity.
        if musicLibrarySource != target {
            musicLibrarySource = target
        }
        syncMusicLibrarySourceToActivePlayback(force: false)

        // Box the main-thread-only continuation so GCD @Sendable closures don't warn.
        struct MainPlayContinuation: @unchecked Sendable {
            let body: () -> Void
        }
        let continuation = playAction.map { MainPlayContinuation(body: $0) }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Hard exclusive: rivals must be paused before any play command.
            ExclusiveAudioFocus.silenceRivals(
                of: target,
                netEaseLikelyPlaying: netEaseLikelyPlaying
            )

            DispatchQueue.main.async {
                guard let self, self.exclusivePlayGeneration == generation else { return }
                if let continuation {
                    continuation.body()
                    return
                }
                switch target {
                case .appleMusic:
                    AppleMusicService.shared.play()
                    if var info = self.appleMusicNowPlaying {
                        info.isPlaying = true
                        info.position = AppleMusicService.shared.playbackTime
                        self.appleMusicNowPlaying = info
                    }
                case .netEase:
                    ExclusiveAudioFocus.playNetEase()
                    _ = NetEaseBridge.shared.playNetEaseOnly()
                    if let netEaseNowPlaying = self.netEaseNowPlaying {
                        self.netEaseNowPlaying = netEaseNowPlaying.with(isPlaying: true)
                    }
                case .local:
                    self.isPlaying = self.audioPlayer?.play() ?? false
                }
            }
        }
    }

    /// Marks `source` as the sole active backend and pauses every other player.
    func activateExclusivePlayback(source: IslandMusicLibrarySource) {
        // Used by next/previous/open — pause rivals immediately; play is caller's job.
        exclusivePlayGeneration &+= 1
        let netEaseLikelyPlaying = netEaseNowPlaying?.isPlaying == true
        claimMusicSourceExclusivity(source, reason: "activate-exclusive")
        switch source {
        case .appleMusic:
            pauseLocalPlaybackEngine()
            markNetEasePausedInUI()
            DispatchQueue.global(qos: .userInitiated).async {
                ExclusiveAudioFocus.silenceRivals(
                    of: .appleMusic,
                    netEaseLikelyPlaying: netEaseLikelyPlaying
                )
            }
        case .netEase:
            pauseLocalPlaybackEngine()
            markAppleMusicPausedInUI()
            DispatchQueue.global(qos: .userInitiated).async {
                ExclusiveAudioFocus.silenceRivals(
                    of: .netEase,
                    netEaseLikelyPlaying: false
                )
            }
        case .local:
            markAppleMusicPausedInUI()
            markNetEasePausedInUI()
            DispatchQueue.global(qos: .userInitiated).async {
                ExclusiveAudioFocus.silenceRivals(
                    of: .local,
                    netEaseLikelyPlaying: netEaseLikelyPlaying
                )
            }
        }
    }

    func silenceOtherPlaybackSources(except source: IslandMusicLibrarySource) {
        switch source {
        case .appleMusic:
            pauseLocalPlaybackEngine()
            pauseNetEasePlaybackEngine()
        case .netEase:
            pauseLocalPlaybackEngine()
            pauseAppleMusicPlaybackEngine()
        case .local:
            pauseNetEasePlaybackEngine()
            pauseAppleMusicPlaybackEngine()
        }
    }

    /// If multiple backends report playing, keep one and hard-pause the rest by bundle ID.
    func reconcileExclusiveAudioFocus() {
        let applePlaying = (appleMusicNowPlaying?.isPlaying == true) || AppleMusicService.shared.isPlaying
        let localPlaying = audioPlayer?.isPlaying == true
        // A NetEase download playing in AVAudioPlayer is one source, not two.
        let netEasePlaying = (netEaseNowPlaying?.isPlaying == true)
            && netEaseDownloadPlayer?.isPlaying != true
        let playingCount = [applePlaying, netEasePlaying, localPlaying].filter { $0 }.count
        guard playingCount > 1 else { return }

        // Safety net only — primary exclusive path must silence before play.
        // Keep this snappy so dual-audio residue dies in <200ms, not seconds.
        let now = Date()
        guard now.timeIntervalSince(lastExclusiveAudioReconcileDate) >= 0.2 else { return }
        lastExclusiveAudioReconcileDate = now

        let preferred: IslandMusicLibrarySource = {
            // User lock wins: silence rivals for the locked channel, never promote a dormant source.
            if musicSourceUserLocked {
                return musicLibrarySource
            }
            switch musicLibrarySource {
            case .appleMusic where applePlaying:
                return .appleMusic
            case .netEase where netEasePlaying:
                return .netEase
            case .local where localPlaying:
                return .local
            default:
                break
            }
            switch activeMusicSource {
            case .appleMusic where applePlaying:
                return .appleMusic
            case .netEase where netEasePlaying:
                return .netEase
            case .local where localPlaying:
                return .local
            default:
                break
            }
            if applePlaying { return .appleMusic }
            if localPlaying { return .local }
            if netEasePlaying { return .netEase }
            return .local
        }()

        activeMusicSource = preferred
        let netEaseLikelyPlaying = netEasePlaying
        switch preferred {
        case .appleMusic:
            isUsingAppleMusic = true
            isUsingNetEase = false
            pauseLocalPlaybackEngine()
            markNetEasePausedInUI()
            DispatchQueue.global(qos: .userInitiated).async {
                ExclusiveAudioFocus.silenceRivals(
                    of: .appleMusic,
                    netEaseLikelyPlaying: netEaseLikelyPlaying
                )
            }
        case .netEase:
            isUsingNetEase = true
            isUsingAppleMusic = false
            if netEaseDownloadPlayer?.isPlaying != true {
                pauseLocalPlaybackEngine()
            }
            markAppleMusicPausedInUI()
            DispatchQueue.global(qos: .userInitiated).async {
                ExclusiveAudioFocus.silenceRivals(
                    of: .netEase,
                    netEaseLikelyPlaying: false
                )
            }
        case .local:
            isUsingAppleMusic = false
            isUsingNetEase = false
            markAppleMusicPausedInUI()
            markNetEasePausedInUI()
            DispatchQueue.global(qos: .userInitiated).async {
                ExclusiveAudioFocus.silenceRivals(
                    of: .local,
                    netEaseLikelyPlaying: netEaseLikelyPlaying
                )
            }
        }
    }

    func markAppleMusicPausedInUI() {
        if var info = appleMusicNowPlaying {
            info.isPlaying = false
            appleMusicNowPlaying = info
        }
    }

    func markNetEasePausedInUI() {
        forceNetEaseLocalPaused()
    }

    /// Hard-stop local NetEase UI / lyric clock regardless of remote Now Playing truth.
    func forceNetEaseLocalPaused() {
        if let netEaseNowPlaying {
            self.netEaseNowPlaying = netEaseNowPlaying.with(isPlaying: false)
        }
        netEaseCommandedPlaying = false
        netEaseHoldPosition = true
        netEaseProgressClock.lockForPause()
        // NetEase applies the pause URL a few seconds later. Keep the icon paused until then.
        suppressNetEasePlayingUntil = Date().addingTimeInterval(8.0)
        isPlaying = false
        objectWillChange.send()
    }

    /// Optimistic play UI — icon flips even if NetEase AE is rejected.
    func forceNetEaseLocalPlaying() {
        suppressNetEasePlayingUntil = .distantPast
        netEaseCommandedPlaying = true
        if let netEaseNowPlaying {
            self.netEaseNowPlaying = netEaseNowPlaying.with(isPlaying: true)
        }
        netEaseProgressClock.resumePlayback()
        objectWillChange.send()
    }

    func pauseLocalPlaybackEngine() {
        guard audioPlayer != nil else {
            isPlaying = false
            return
        }
        audioPlayer?.pause()
        isPlaying = false
    }

    func pauseNetEasePlaybackEngine() {
        markNetEasePausedInUI()
        DispatchQueue.global(qos: .userInitiated).async {
            ExclusiveAudioFocus.pauseNetEase()
        }
        if activeMusicSource != .netEase, musicLibrarySource != .netEase {
            isUsingNetEase = false
        }
    }

    func pauseAppleMusicPlaybackEngine() {
        markAppleMusicPausedInUI()
        DispatchQueue.global(qos: .userInitiated).async {
            ExclusiveAudioFocus.pauseAppleMusic()
        }
        if activeMusicSource != .appleMusic, musicLibrarySource != .appleMusic {
            isUsingAppleMusic = false
        }
    }

    func play(track: LocalTrack) {
        dismissTaskCompletionNoticeForInteraction()

        // Local channel: always play the file with AVAudioPlayer, never open NetEase.
        if musicLibrarySource == .local {
            let list = activePlaybackList
            if let index = list.firstIndex(of: track) {
                currentIndex = index
            } else if let index = list.firstIndex(where: {
                $0.id == track.id || ($0.title == track.title && $0.artist == track.artist)
            }) {
                currentIndex = index
            } else if Self.isLocallyPlayableFile(track) {
                // Track visible but not yet indexed — play it directly and keep queue on local.
                currentIndex = 0
            }
            playDirectTrack(track)
            return
        }

        if selectedNetEasePlaylistID != nil,
           let index = selectedNetEasePlaylistTracks.firstIndex(of: track)
        {
            currentIndex = index
        } else if let index = selectedNetEasePlaylistTracks.firstIndex(where: {
            $0.id == track.id || ($0.title == track.title && $0.artist == track.artist)
        }) {
            currentIndex = index
        } else if let index = tracks.firstIndex(of: track) {
            currentIndex = index
        } else if let index = tracks.firstIndex(where: {
            $0.id == track.id || ($0.title == track.title && $0.artist == track.artist)
        }) {
            currentIndex = index
        }

        playNetEaseOwnedTrack(track)
    }

    func nextTrack() {
        dismissTaskCompletionNoticeForInteraction()

        // Local queue is absolute while on the local channel.
        if musicLibrarySource == .local {
            let list = activePlaybackList
            guard !list.isEmpty else { return }
            currentIndex = (currentIndex + 1) % list.count
            playCurrentSelection()
            return
        }

        if shouldRouteControlsToAppleMusic {
            ensureSinglePlayerPlaying(target: .appleMusic) {
                AppleMusicService.shared.next()
                // Align island UI after skip+play settles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    AppleMusicService.shared.refresh {
                        self?.applyAppleMusicNowPlaying(AppleMusicService.shared.currentTrack)
                    }
                }
            }
            return
        }

        if shouldRouteControlsToNetEase || isDisplayingNetEaseNowPlaying {
            // NetEase's own Next follows its queue and play mode (often shuffle), not the list on screen.
            let skippedInList = followsNetEaseListOnScreen && skipNetEaseTrack(offset: 1)
            if !skippedInList, !NetEaseBridge.shared.send(.nextTrack), !skipNetEaseTrack(offset: 1) {
                openNetEaseCloudMusic()
            }
            // The history row lands a couple of seconds after the skip.
            for delay in [1.8, 3.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.refreshNetEaseNowPlaying(force: true)
                }
            }
            return
        }

        if shouldRouteControlsToSystemPlayer, NetEaseBridge.shared.send(.nextTrack) {
            return
        }

        let list = currentPlaybackList
        guard !list.isEmpty else { return }
        currentIndex = (currentIndex + 1) % list.count
        playCurrentSelection()
    }

    func previousTrack() {
        dismissTaskCompletionNoticeForInteraction()

        if musicLibrarySource == .local {
            let list = activePlaybackList
            guard !list.isEmpty else { return }
            currentIndex = (currentIndex - 1 + list.count) % list.count
            playCurrentSelection()
            return
        }

        if shouldRouteControlsToAppleMusic {
            ensureSinglePlayerPlaying(target: .appleMusic) {
                AppleMusicService.shared.previous()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    AppleMusicService.shared.refresh {
                        self?.applyAppleMusicNowPlaying(AppleMusicService.shared.currentTrack)
                    }
                }
            }
            return
        }

        if shouldRouteControlsToNetEase || isDisplayingNetEaseNowPlaying {
            let skippedInList = followsNetEaseListOnScreen && skipNetEaseTrack(offset: -1)
            if !skippedInList, !NetEaseBridge.shared.send(.previousTrack), !skipNetEaseTrack(offset: -1) {
                openNetEaseCloudMusic()
            }
            for delay in [1.8, 3.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.refreshNetEaseNowPlaying(force: true)
                }
            }
            return
        }

        if shouldRouteControlsToSystemPlayer, NetEaseBridge.shared.send(.previousTrack) {
            return
        }

        let list = currentPlaybackList
        guard !list.isEmpty else { return }
        currentIndex = (currentIndex - 1 + list.count) % list.count
        playCurrentSelection()
    }

    /// Drag start / move — UI only. Never pause or seek the system player here.
    func beginSeekPreview(progress: Double) {
        let clamped = min(1, max(0, progress))
        if !isSeekingPlayback {
            seekLockedIsPlaying = displayedIsPlaying
            isSeekingPlayback = true
        }
        seekUnlockWorkItem?.cancel()
        seekUnlockWorkItem = nil
        seekPreviewProgress = clamped
    }

    /// Drag end — atomic seek once, keep the lock until the player settles.
    func commitSeek(progress: Double) {
        let clamped = min(1, max(0, progress))
        let wasPlaying = seekLockedIsPlaying ?? displayedIsPlaying
        seekLockedIsPlaying = wasPlaying
        isSeekingPlayback = true
        seekPreviewProgress = clamped
        seekUnlockWorkItem?.cancel()

        let moved = performSeek(to: clamped, resumeIfPlaying: wasPlaying)
        guard moved else {
            isSeekingPlayback = false
            seekLockedIsPlaying = nil
            objectWillChange.send()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // If we intended to keep playing, ignore a stale paused flash before unlocking.
            if wasPlaying {
                self.ensurePlaybackResumedAfterSeek()
            }
            self.isSeekingPlayback = false
            self.seekLockedIsPlaying = nil
            self.seekUnlockWorkItem = nil
        }
        seekUnlockWorkItem = workItem
        // Hold the scrub lock briefly so async pause notifications from Music.app don't win.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    func seek(to progress: Double) {
        commitSeek(progress: progress)
    }

    /// Internal seek transport — captures play state and forces resume when needed.
    @discardableResult
    func performSeek(to progress: Double, resumeIfPlaying: Bool) -> Bool {
        let clampedProgress = min(1, max(0, progress))

        if shouldRouteControlsToAppleMusic {
            let duration = max(displayedDuration, appleMusicNowPlaying?.duration ?? 0)
            guard duration > 0 else { return false }
            let newTime = duration * clampedProgress
            if let appleMusicNowPlaying {
                var updated = appleMusicNowPlaying.with(position: newTime)
                updated.isPlaying = resumeIfPlaying
                self.appleMusicNowPlaying = updated
            }
            pendingAppleMusicSeek = (
                position: newTime,
                expiresAt: Date().addingTimeInterval(1.6)
            )
            AppleMusicService.shared.seek(to: newTime, resumePlayback: resumeIfPlaying)
            if resumeIfPlaying {
                // Immediate local resume signal; AppleScript also issues `play`.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.seekLockedIsPlaying == true else { return }
                    AppleMusicService.shared.play()
                    if var info = self.appleMusicNowPlaying {
                        info.isPlaying = true
                        self.appleMusicNowPlaying = info
                    }
                }
            }
            objectWillChange.send()
            return true
        }

        if shouldRouteControlsToNetEase {
#if LUMA_APP_STORE
            if let localCopy = netEaseLocalCopyOfCurrentSong {
                return seekByTakingOverNetEaseSong(
                    localCopy,
                    progress: clampedProgress,
                    resumeIfPlaying: resumeIfPlaying
                )
            }
            return false
#else
            let duration = max(displayedDuration, netEaseNowPlaying?.duration ?? 0)
            guard duration > 0 else { return false }

            let newTime = duration * clampedProgress
            guard NetEaseBridge.shared.seek(to: newTime) else {
                if let localCopy = netEaseLocalCopyOfCurrentSong {
                    return seekByTakingOverNetEaseSong(
                        localCopy,
                        progress: clampedProgress,
                        resumeIfPlaying: resumeIfPlaying
                    )
                }
                objectWillChange.send()
                return false
            }
            netEaseProgressClock.seek(to: newTime)
            if resumeIfPlaying {
                netEaseProgressClock.resumePlayback()
            }
            if let netEaseNowPlaying {
                self.netEaseNowPlaying = netEaseNowPlaying
                    .with(position: newTime)
                    .with(isPlaying: resumeIfPlaying)
            }

            pendingNetEaseSeek = (
                position: newTime,
                expiresAt: Date().addingTimeInterval(2.5)
            )
#if !LUMA_APP_STORE
            // The direct build's seek can pause the player. The store URL seek must not be
            // followed by resume: that command restarts the song at the beginning.
            if resumeIfPlaying {
                _ = NetEaseBridge.shared.playNetEaseOnly()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.seekLockedIsPlaying == true else { return }
                    _ = NetEaseBridge.shared.playNetEaseOnly()
                }
            }
#endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, !self.isSeekingPlayback else { return }
                self.refreshNetEaseNowPlaying(force: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [weak self] in
                guard let self, !self.isSeekingPlayback else { return }
                self.refreshNetEaseNowPlaying(force: true)
            }
            return true
#endif
        }

        guard let audioPlayer, duration > 0 else { return false }
        let newTime = duration * clampedProgress
        audioPlayer.currentTime = newTime
        position = newTime
        if resumeIfPlaying, !audioPlayer.isPlaying {
            isPlaying = audioPlayer.play()
        }
        return true
    }

    /// Pauses the NetEase client and continues the same song from its download at the new position.
    func seekByTakingOverNetEaseSong(
        _ track: LocalTrack,
        progress: Double,
        resumeIfPlaying: Bool
    ) -> Bool {
        playOwnedNetEaseDownload(track)
        guard let audioPlayer, audioPlayer.duration > 0 else { return false }
        let newTime = audioPlayer.duration * progress
        audioPlayer.currentTime = newTime
        position = newTime
        if !resumeIfPlaying {
            audioPlayer.pause()
            isPlaying = false
        }
        netEaseCommandedPlaying = audioPlayer.isPlaying
        if let netEaseNowPlaying {
            self.netEaseNowPlaying = netEaseNowPlaying
                .with(position: newTime)
                .with(isPlaying: audioPlayer.isPlaying)
        }
        netEaseProgressClock.seek(to: newTime)
        objectWillChange.send()
        return true
    }

    func ensurePlaybackResumedAfterSeek() {
        if shouldRouteControlsToAppleMusic {
            if appleMusicNowPlaying?.isPlaying != true || !AppleMusicService.shared.isPlaying {
                AppleMusicService.shared.play()
            }
            if var info = appleMusicNowPlaying {
                info.isPlaying = true
                appleMusicNowPlaying = info
            }
            return
        }
        if shouldRouteControlsToNetEase {
#if !LUMA_APP_STORE
            _ = NetEaseBridge.shared.playNetEaseOnly()
#endif
            if let netEaseNowPlaying {
                self.netEaseNowPlaying = netEaseNowPlaying.with(isPlaying: true)
            }
            netEaseProgressClock.resumePlayback()
            return
        }
        if let audioPlayer, !audioPlayer.isPlaying {
            isPlaying = audioPlayer.play()
        }
    }

    func collapse() {
        isSelectionTranslationActive = false
        guard taskCompletionNotice == nil else { return }
        isExpanded = false
    }

    func dismissSelectionTranslationForFullScreen() {
        guard isSelectionTranslationActive else { return }
        agentTask?.cancel()
        agentRequestToken = UUID()
        isSelectionTranslationActive = false
        isAgentStreaming = false
        agentLiveEstimatedTokens = 0
        agentStatus = LumaBarL10n.agentReady
        agentResponse = ""
        isExpanded = false
    }

    func dismissExpandedPanel() {
        requestExpandedPanelDismissal?() ?? collapse()
    }

    func suppressAutomaticExpansion(for duration: TimeInterval) {
        suppressAutomaticExpansionUntil = Date().addingTimeInterval(duration)
    }

    /// Explicit user / product expand. System notifications (Spaces, playerInfo) must not call this.
    func expandFromUserAction() {
        guard Date() >= suppressAutomaticExpansionUntil else { return }
        isExpanded = true
    }

    func setVolumeInteraction(active: Bool) {
        isAdjustingSystemVolume = active
        if !active {
            suppressSystemVolumeSyncUntil = Date().addingTimeInterval(0.35)
        }
    }
}
