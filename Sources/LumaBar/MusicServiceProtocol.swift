import Foundation

/// Shared now-playing snapshot used by external music services (NetEase / Apple Music).
struct MusicNowPlayingInfo: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var artworkData: Data?
    var position: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool

    func with(position: TimeInterval) -> MusicNowPlayingInfo {
        var copy = self
        copy.position = position
        return copy
    }

    func withArtworkData(_ data: Data) -> MusicNowPlayingInfo {
        var copy = self
        copy.artworkData = data
        return copy
    }
}

/// Unified playback surface so the island UI can swap music backends without changing controls.
@MainActor
protocol MusicServiceProtocol: AnyObject {
    var currentTrack: MusicNowPlayingInfo? { get }
    var isPlaying: Bool { get }
    var playbackTime: TimeInterval { get }
    var duration: TimeInterval { get }

    func play()
    func pause()
    func togglePlayPause()
    func next()
    func previous()
    func seek(to position: TimeInterval)

    /// Begin observing player changes. `onChange` is always invoked on the main actor.
    func startMonitoring(onChange: @escaping @MainActor () -> Void)
    func stopMonitoring()
    func refresh(completion: (@MainActor () -> Void)?)
}
