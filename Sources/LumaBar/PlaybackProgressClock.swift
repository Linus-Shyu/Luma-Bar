import Foundation

/// Timestamp-interpolated playback position.
/// UI reads `calculatedCurrentTime()` every tick; system polls only recalibrate the anchor.
struct PlaybackProgressClock: Equatable, Sendable {
    /// Anchor position from the last accepted system sample / seek / pause lock.
    private(set) var cachedPosition: TimeInterval = 0
    /// Wall-clock time when `cachedPosition` was anchored.
    private(set) var lastFetchTime: Date = .distantPast
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying: Bool = false
    private(set) var playbackRate: Double = 1
    private(set) var trackIdentity: String = ""

    /// Polling jitter below this delta is ignored so the bar does not jump.
    static let calibrationTolerance: TimeInterval = 1.5

    func calculatedCurrentTime(at date: Date = Date()) -> TimeInterval {
        let capped: (TimeInterval) -> TimeInterval = { value in
            let clamped = max(0, value)
            guard duration > 0 else { return clamped }
            return min(clamped, duration)
        }

        guard isPlaying else { return capped(cachedPosition) }
        guard lastFetchTime != .distantPast else { return capped(cachedPosition) }

        let elapsed = max(0, date.timeIntervalSince(lastFetchTime))
        return capped(cachedPosition + elapsed * max(0, playbackRate))
    }

    /// Force-set the anchor (user seek, track change, or explicit sync).
    mutating func seek(to position: TimeInterval, at date: Date = Date()) {
        cachedPosition = max(0, position)
        lastFetchTime = date
        if duration > 0 {
            cachedPosition = min(cachedPosition, duration)
        }
    }

    /// Lock the live interpolated time when pausing so the bar stops immediately.
    mutating func lockForPause(at date: Date = Date()) {
        cachedPosition = calculatedCurrentTime(at: date)
        lastFetchTime = date
        isPlaying = false
    }

    /// Resume interpolation from the locked / system position.
    mutating func resumePlayback(at date: Date = Date()) {
        lastFetchTime = date
        isPlaying = true
    }

    mutating func reset() {
        self = PlaybackProgressClock()
    }

    /// Merge a system-reported sample. Small deltas keep local interpolation; large deltas snap.
    mutating func calibrate(
        systemPosition: TimeInterval,
        duration newDuration: TimeInterval,
        isPlaying newIsPlaying: Bool,
        trackIdentity newTrackIdentity: String,
        playbackRate newRate: Double = 1,
        force: Bool = false,
        at date: Date = Date()
    ) {
        duration = max(0, newDuration)
        playbackRate = max(0, newRate)

        let trackChanged = !trackIdentity.isEmpty
            && !newTrackIdentity.isEmpty
            && trackIdentity != newTrackIdentity
        if !newTrackIdentity.isEmpty {
            trackIdentity = newTrackIdentity
        }

        let sanitizedSystem = max(0, systemPosition)
        let wasPlaying = isPlaying

        if trackChanged || force || lastFetchTime == .distantPast {
            cachedPosition = sanitizedSystem
            lastFetchTime = date
            isPlaying = newIsPlaying
            return
        }

        // Playing → paused: freeze the interpolated playhead first.
        if wasPlaying && !newIsPlaying {
            lockForPause(at: date)
            // Accept a real system position when it meaningfully differs (seek-while-paused).
            if sanitizedSystem > 0.05,
               abs(sanitizedSystem - cachedPosition) > Self.calibrationTolerance
            {
                cachedPosition = sanitizedSystem
                lastFetchTime = date
            }
            return
        }

        // Paused → playing: re-anchor wall clock; prefer non-zero system position.
        if !wasPlaying && newIsPlaying {
            if sanitizedSystem > 0.05 {
                let delta = abs(sanitizedSystem - cachedPosition)
                if delta > Self.calibrationTolerance || cachedPosition <= 0.05 {
                    cachedPosition = sanitizedSystem
                }
            }
            resumePlayback(at: date)
            return
        }

        isPlaying = newIsPlaying

        guard newIsPlaying else {
            // Still paused: ignore near-zero polls that would wipe a valid playhead.
            if sanitizedSystem > 0.05 {
                let delta = abs(sanitizedSystem - cachedPosition)
                if delta > Self.calibrationTolerance {
                    cachedPosition = sanitizedSystem
                    lastFetchTime = date
                }
            }
            return
        }

        let local = calculatedCurrentTime(at: date)
        let delta = abs(sanitizedSystem - local)
        if delta > Self.calibrationTolerance {
            cachedPosition = sanitizedSystem
            lastFetchTime = date
        }
        // else: keep interpolating from the existing anchor (no jitter jump).
    }
}
