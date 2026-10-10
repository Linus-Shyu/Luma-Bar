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

struct MusicExpandedView: View {
    @ObservedObject var model: MusicPlayerModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                ZStack {
                    if model.activeMode == .system {
                        SystemGlyphBadge(metrics: model.systemMetrics)
                            .frame(width: 32, height: 32)
                    } else if model.activeMode == .token {
                        TokenGlyphBadge(progress: model.agentTokenProgress)
                            .frame(width: 32, height: 32)
                    } else if model.activeMode == .agent {
                        AgentGlyphBadge(isActive: model.isAgentStreaming)
                            .frame(width: 32, height: 32)
                    } else {
                        AlbumBadge(
                            artworkData: model.displayedArtworkData,
                            isPlaying: model.displayedIsPlaying
                        )
                            .frame(width: 32, height: 32)
                    }
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.activeDisplayTitle)
                        .font(theme.font(size: 13, weight: .bold))
                        .foregroundStyle(theme.foreground())
                        .lineLimit(1)
                    Text(model.activeDisplaySubtitle)
                        .font(theme.font(size: 10, weight: .medium))
                        .foregroundStyle(theme.mutedForeground(opacity: 0.94))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                HStack(spacing: NotchMetrics.expandedModePillSpacing) {
                    modePill(title: LumaBarL10n.modeMusic, icon: "music.note", active: model.activeMode == .music) {
                        model.showMusic()
                    }
                    modePill(title: LumaBarL10n.modeSystem, icon: "cpu", active: model.activeMode == .system) {
                        model.showSystem()
                    }
                    modePill(title: LumaBarL10n.modeAgent, icon: "sparkles", active: model.activeMode == .agent) {
                        model.showAgent()
                    }
                }

                Button {
                    model.dismissExpandedPanel()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.foreground(opacity: 0.85))
                        .frame(
                            width: NotchMetrics.expandedCollapseButton,
                            height: NotchMetrics.expandedCollapseButton
                        )
                        .background(
                            RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                                .fill(theme.controlFill)
                        )
                }
                .buttonStyle(.plain)
                .help(LumaBarL10n.collapse)
            }
            .frame(height: NotchMetrics.expandedHeaderRowHeight)

            if model.activeMode == .system {
                ScrollView(showsIndicators: false) {
                    SystemDashboardView(metrics: model.systemMetrics)
                }
            } else if model.activeMode == .token {
                TokenDashboardView(model: model)
            } else if model.activeMode == .agent {
                AgentDashboardView(model: model)
            } else {
                HStack(spacing: 6) {
                    ForEach(IslandMusicLibrarySource.allCases) { source in
                        musicSourcePill(source)
                    }
                    Spacer(minLength: 0)
                }

                if model.musicLibrarySource == .netEase {
                    NetEasePlaylistShelf(model: model)
                } else if model.musicLibrarySource == .appleMusic {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 11, weight: .bold))
                        Text(model.appleMusicNowPlaying == nil
                             ? LumaBarL10n.openMusicHint
                             : "Apple Music · \(model.displayedTitle)")
                            .font(theme.font(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button(LumaBarL10n.openMusic) {
                            AppleMusicService.shared.openApplication(activates: true)
                        }
                        .buttonStyle(.plain)
                        .font(theme.font(size: 10, weight: .semibold))
                        .foregroundStyle(theme.primaryAccent)
                    }
                    .foregroundStyle(theme.mutedForeground(opacity: 0.9))
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                }

                if model.showsPlaybackTimeline {
                    HStack(spacing: 8) {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            Text(timeString(model.displayedPosition))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.mutedForeground(opacity: 0.84))
                                .frame(width: 36, alignment: .leading)
                        }
                        MusicSeekBar(
                            progress: model.displayedProgress,
                            duration: model.displayedDuration,
                            isSeeking: model.isSeekingPlayback,
                            previewProgress: model.isSeekingPlayback
                                ? model.seekPreviewProgress
                                : model.displayedProgress,
                            allowsScrubbing: model.canSeekPlayback,
                            onPreview: { progress in
                                model.beginSeekPreview(progress: progress)
                            },
                            onCommit: { progress in
                                model.commitSeek(progress: progress)
                            },
                            liveProgressProvider: { [weak model] in
                                model?.displayedProgress ?? 0
                            }
                        )
                        .id("luma-music-seek-bar")
                        .frame(height: 22)
                        .help(model.canSeekPlayback ? LumaBarL10n.musicSeek : model.seekUnavailableReason)
                        Text(timeString(model.displayedDuration))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.mutedForeground(opacity: 0.84))
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                ZStack {
                    HStack(spacing: 12) {
                        PlayerCircleButton(systemName: "backward.fill") {
                            model.previousTrack()
                        }

                        Button {
                            model.togglePlayback()
                        } label: {
                            Image(systemName: model.displayedIsPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(theme.accentForeground)
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                                        .fill(theme.isPixelStyled || theme.isLight ? theme.primaryAccent : Color.white)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(IslandPressDownButtonStyle())

                        PlayerCircleButton(systemName: "forward.fill") {
                            model.nextTrack()
                        }
                    }

                    // Volume sits on the trailing edge only. A hit-testable Spacer here used
                    // to cover the transport buttons so only the header pills received clicks.
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                            .allowsHitTesting(false)
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.mutedForeground(opacity: 0.94))
                            .allowsHitTesting(false)
                        IslandVolumeSlider(
                            value: $model.volume,
                            onEditingChanged: { isEditing in
                                model.setVolumeInteraction(active: isEditing)
                            }
                        )
                        .frame(width: 78, height: 22)
                    }
                }
                .frame(height: 36)

                Divider()
                    .overlay(theme.separatorColor)

                HStack(alignment: .top, spacing: 8) {
                    LyricsPane(
                        track: model.displayedLyricsTrack,
                        positionIsReliable: model.displayedPositionIsReliable,
                        positionProvider: { [weak model] in
                            model?.displayedPosition ?? 0
                        }
                    )
                    .frame(width: 148)

                    trackListScroll
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(NotchMetrics.expandedHeaderPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ExpandedIslandBackground()
        }
        .modifier(
            CompactBarClipIfNeeded(
                theme: theme,
                shape: ThemeRectShape(
                    radius: theme.expandedCornerRadius,
                    chamfer: 0
                )
            )
        )
        .shadow(
            color: theme == .aura
                ? Color.black.opacity(0.05)
                : (theme.isForge
                ? Color(red: 0.31, green: 0.33, blue: 0.28).opacity(0.72)
                : (theme.isLight
                ? theme.primaryAccent.opacity(0.22)
                : (theme.isArcade
                ? .clear
                : (theme.isNook
                    ? .black.opacity(0.38)
                    : (theme.isPixelStyled ? .black.opacity(0.72) : .black.opacity(0.26)))))),
            radius: theme == .aura
                ? 16
                : (theme.isNook ? 14 : (theme.isPixelStyled ? 0 : 12)),
            x: theme.isGrid ? 4 : 0,
            y: theme == .aura
                ? 6
                : (theme.isForge ? 7 : (theme.isGrid ? 4 : (theme.isNook ? 8 : 7)))
        )
        .animation(.spring(response: 0.24, dampingFraction: 0.9), value: model.activeMode)
        .contextMenu {
            Button(LumaBarL10n.actionRescan) {
                model.scanLocalMusic()
            }
            Button(LumaBarL10n.actionOpenNetEase) {
                model.openNetEaseCloudMusic()
            }
            Button(LumaBarL10n.actionOpenAppleMusic) {
                AppleMusicService.shared.openApplication(activates: true)
                model.setMusicLibrarySource(.appleMusic)
            }
            Button(LumaBarL10n.actionRefreshPlaylists) {
                model.refreshNetEasePlaylists()
            }
            Divider()
            Button(LumaBarL10n.actionSwitchMusic) {
                model.showMusic()
            }
            Button(LumaBarL10n.actionSwitchSystem) {
                model.showSystem()
            }
            Button(LumaBarL10n.actionSwitchAgent) {
                model.showAgent()
            }
            Divider()
            Button(LumaBarL10n.actionQuit) {
                AppController.quitFromUserAction()
            }
        }
    }

    private func musicSourcePill(_ source: IslandMusicLibrarySource) -> some View {
        let active = model.musicLibrarySource == source
        // Clicks are also routed via IslandPanel immediate actions; keep a press-down
        // SwiftUI button as fallback when hit regions lag a layout change.
        return Button {
            model.setMusicLibrarySource(source)
        } label: {
            Text(source.title)
                .font(theme.font(size: 10, weight: .semibold))
                .foregroundStyle(
                    active
                        ? (theme.isLight || theme == .aura ? theme.accentForeground : Color.black.opacity(0.82))
                        : theme.mutedForeground(opacity: 0.92)
                )
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                        .fill(
                            active
                                ? (theme.isPixelStyled || theme.isLight || theme == .aura
                                    ? theme.primaryAccent.opacity(theme == .aura ? 0.92 : 1)
                                    : Color.white.opacity(0.92))
                                : theme.controlFill
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandPressDownButtonStyle())
        // Keep pill hit targets stable when the playlist shelf mounts/unmounts under them.
        .zIndex(2)
    }

    @ViewBuilder
    private var trackListScroll: some View {
        // Stable identity so model ticks don't remount the scroller and jump to row 0.
        TrackListScrollView(model: model)
            .id("track-list-\(model.musicLibrarySource.rawValue)-\(model.selectedNetEasePlaylistID ?? "all")")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func modePill(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(
                    theme == .aura
                        ? (active ? Color.black.opacity(0.78) : theme.foreground(opacity: 0.78))
                        : (active ? theme.accentForeground : theme.foreground(opacity: 0.74))
                )
                .frame(
                    width: NotchMetrics.expandedModePillWidth,
                    height: NotchMetrics.expandedHeaderRowHeight - 4
                )
                .background {
                    let pill = RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                    if theme == .aura {
                        pill
                            .fill(active ? Color.white.opacity(0.88) : Color.white.opacity(0.10))
                            .overlay {
                                pill.strokeBorder(
                                    Color.white.opacity(active ? 0.72 : 0.28),
                                    lineWidth: 0.5
                                )
                            }
                    } else {
                        pill
                            .fill(
                                active
                                    ? (theme.isPixelStyled || theme.isLight ? theme.primaryAccent : Color.white.opacity(0.92))
                                    : theme.controlFill
                            )
                            .overlay {
                                if theme.isPixelStyled || theme.isLight {
                                    pill.stroke(
                                        active ? theme.primaryAccent : theme.pixelBorder.opacity(0.28),
                                        lineWidth: 1
                                    )
                                }
                            }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .zIndex(2)
    }

    private func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite && time > 0 else { return "0:00" }
        let total = Int(time)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

struct TrackListScrollView: View {
    @ObservedObject var model: MusicPlayerModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let tracks = model.displayedTrackList
        let currentID = tracks.first { model.isCurrentDisplayTrack($0) }?.id
        let scrollKey = "\(model.musicLibrarySource.rawValue)|\(model.selectedNetEasePlaylistID ?? "all")"
        // GeometryReader takes the leftover slot and gives the scroller that
        // exact size. Without it the scroller reports every song's height,
        // the island window clips the rest, and the wheel has nowhere to go.
        GeometryReader { geo in
            SongListScroller(
                tracks: tracks,
                currentID: currentID,
                isPlaying: model.displayedIsPlaying,
                message: model.displayedTrackListMessage,
                theme: theme,
                scrollKey: scrollKey,
                onPlay: { model.play(track: $0) }
            )
            .frame(
                width: max(geo.size.width, 1),
                height: min(max(geo.size.height, 1), 320)
            )
        }
    }
}

enum SongListOffsetStore {
    nonisolated(unsafe) private static var values: [String: CGFloat] = [:]

    static func value(for key: String) -> CGFloat? {
        values[key]
    }

    static func set(_ value: CGFloat, for key: String) {
        guard !key.isEmpty else { return }
        values[key] = value
    }
}

struct SongRowView: View {
    let track: LocalTrack
    let isCurrent: Bool
    let isPlaying: Bool
    let theme: IslandTheme
    let action: () -> Void

    var body: some View {
        TrackRow(
            track: track,
            isCurrent: isCurrent,
            isPlaying: isPlaying,
            action: action
        )
        .environment(\.islandTheme, theme)
    }
}

final class SongRowHost: NSHostingView<SongRowView> {
    private var acceptsFrame = false
    var shownTrackID: URL?
    var shownCurrent = false
    var shownPlaying = false
    var shownArtworkCount = 0
    var shownTheme: IslandTheme?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 38)
    }

    override var fittingSize: NSSize {
        NSSize(width: bounds.width > 1 ? bounds.width : 200, height: 38)
    }

    func place(in rect: NSRect) {
        guard frame != rect else { return }
        acceptsFrame = true
        frame = rect
        acceptsFrame = false
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard acceptsFrame else { return }
        super.setFrameSize(newSize)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        guard acceptsFrame else { return }
        super.setFrameOrigin(newOrigin)
    }
}

final class SongListWheelBox: @unchecked Sendable {
    weak var viewport: SongListViewport?
}

/// Shows only the rows that fit in the island slot and moves those rows itself.
/// A single tall document kept getting resized to the whole playlist, which
/// cleared the scroll offset and jumped back to the first song.
final class SongListViewport: NSView {
    var tracks: [LocalTrack] = []
    var currentID: URL?
    var isPlaying = false
    var theme: IslandTheme = .aura
    var message = ""
    var scrollKey = ""
    var onPlay: (LocalTrack) -> Void = { _ in }
    var pinnedY: CGFloat = 0
    var slotSize: NSSize = .zero

    private let rowPitch: CGFloat = 42
    private let rowHeight: CGFloat = 38
    private var rowHosts: [SongRowHost] = []
    private var placing = false
    private var wheelMonitor: Any?
    private var lastHandledTimestamp: TimeInterval = -1
    private var lastPlayAt = Date.distantPast
    private let wheelTarget = SongListWheelBox()
    private let messageLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.isHidden = true
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        clipsToBounds = true
        autoresizesSubviews = false
        addSubview(messageLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: slotSize.height > 40 ? slotSize.height : 160)
    }

    override var fittingSize: NSSize {
        NSSize(
            width: slotSize.width > 1 ? slotSize.width : 280,
            height: slotSize.height > 40 ? slotSize.height : 160
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if size.height >= 340 {
            size.height = slotSize.height > 40 && slotSize.height < 340 ? slotSize.height : 180
        } else if slotSize.height > 40, slotSize.height < 340, size.height > slotSize.height + 1 {
            size.height = slotSize.height
        }
        super.setFrameSize(size)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeWheelMonitor()
        } else {
            installWheelMonitor()
            placeRows()
        }
    }

    override func layout() {
        super.layout()
        placeRows()
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return }
        let index = Int((local.y + pinnedY) / rowPitch)
        playRow(at: index)
    }

    override func scrollWheel(with event: NSEvent) {
        _ = handleWheel(
            deltaY: event.scrollingDeltaY,
            deltaX: event.scrollingDeltaX,
            lineDelta: event.deltaY,
            precise: event.hasPreciseScrollingDeltas,
            timestamp: event.timestamp,
            windowPoint: event.locationInWindow,
            eventWindowMatches: event.window === window
        )
    }

    func playRow(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPlayAt) > 0.18 else { return }
        lastPlayAt = now
        onPlay(tracks[index])
    }

    fileprivate func removeWheelMonitor() {
        if let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
        }
    }

    func placeRows() {
        guard !placing else { return }
        placing = true
        defer { placing = false }

        let width = max(bounds.width, 1)
        let port = scrollPortHeight()
        let contentHeight = CGFloat(tracks.count) * rowPitch
        let maxY = max(0, contentHeight - port)
        if pinnedY < 0.5, maxY > 1, let saved = SongListOffsetStore.value(for: scrollKey), saved > 1 {
            pinnedY = min(saved, maxY)
        }
        if maxY > 1 {
            pinnedY = min(max(0, pinnedY), maxY)
            SongListOffsetStore.set(pinnedY, for: scrollKey)
        } else {
            pinnedY = 0
            SongListOffsetStore.set(0, for: scrollKey)
        }

        messageLabel.isHidden = !tracks.isEmpty
        if tracks.isEmpty {
            messageLabel.stringValue = message
            messageLabel.frame = NSRect(x: 8, y: 8, width: max(width - 16, 1), height: min(port, 64))
            for host in rowHosts { host.isHidden = true }
            return
        }

        let first = max(0, Int(floor(pinnedY / rowPitch)) - 1)
        let visibleCount = max(1, Int(ceil(port / rowPitch)) + 3)
        let last = min(tracks.count, first + visibleCount)
        let needed = max(0, last - first)
        while rowHosts.count < needed {
            let host = SongRowHost(rootView: SongRowView(
                track: tracks[0],
                isCurrent: false,
                isPlaying: false,
                theme: theme,
                action: {}
            ))
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = true
            addSubview(host)
            rowHosts.append(host)
        }

        for (offset, host) in rowHosts.enumerated() {
            guard offset < needed else {
                host.isHidden = true
                continue
            }
            let index = first + offset
            let track = tracks[index]
            let isCurrent = track.id == currentID
            let playing = isPlaying && isCurrent
            let artworkCount = track.artworkData?.count ?? 0
            let y = CGFloat(index) * rowPitch - pinnedY
            host.isHidden = false
            if host.shownTrackID != track.id
                || host.shownCurrent != isCurrent
                || host.shownPlaying != playing
                || host.shownArtworkCount != artworkCount
                || host.shownTheme != theme
            {
                let index = index
                host.rootView = SongRowView(
                    track: track,
                    isCurrent: isCurrent,
                    isPlaying: playing,
                    theme: theme,
                    action: { [weak self] in
                        self?.playRow(at: index)
                    }
                )
                host.shownTrackID = track.id
                host.shownCurrent = isCurrent
                host.shownPlaying = playing
                host.shownArtworkCount = artworkCount
                host.shownTheme = theme
            }
            host.place(in: NSRect(x: 0, y: y, width: width, height: rowHeight))
        }
    }

    /// Height of the on-screen list. Never the full playlist, or the offset is illegal and snaps to 0.
    private func scrollPortHeight() -> CGFloat {
        if slotSize.height > 40, slotSize.height < 340 {
            return slotSize.height
        }
        if let window, bounds.height >= 340 {
            let inWindow = convert(bounds, to: nil)
            let windowBounds = window.contentView?.bounds ?? NSRect(origin: .zero, size: window.frame.size)
            let visible = inWindow.intersection(windowBounds)
            if visible.height > 40, visible.height < 340 {
                return visible.height
            }
        }
        if bounds.height > 40, bounds.height < 340 {
            return bounds.height
        }
        return 160
    }

    @MainActor
    func handleWheel(
        deltaY: CGFloat,
        deltaX: CGFloat,
        lineDelta: CGFloat,
        precise: Bool,
        timestamp: TimeInterval,
        windowPoint: NSPoint?,
        eventWindowMatches: Bool
    ) -> Bool {
        if abs(timestamp - lastHandledTimestamp) < 0.000_000_1, lastHandledTimestamp >= 0 {
            return true
        }
        guard cursorIsOverList(windowPoint: windowPoint, eventWindowMatches: eventWindowMatches) else {
            return false
        }
        guard abs(deltaY) > abs(deltaX) * 0.55 else { return false }
        let delta: CGFloat
        if precise {
            delta = deltaY
        } else {
            let lines = abs(lineDelta) > 0.01 ? lineDelta : deltaY
            delta = lines * rowPitch
        }
        guard abs(delta) > 0.15 else { return false }
        let maxY = max(0, CGFloat(tracks.count) * rowPitch - scrollPortHeight())
        guard maxY > 1 else { return false }
        // Positive scrollingDeltaY moves toward the first song.
        let y = min(maxY, max(0, pinnedY - delta))
        lastHandledTimestamp = timestamp
        guard abs(y - pinnedY) > 0.2 else { return true }
        pinnedY = y
        SongListOffsetStore.set(y, for: scrollKey)
        placeRows()
        return true
    }

    private func cursorIsOverList(windowPoint: NSPoint?, eventWindowMatches: Bool) -> Bool {
        if eventWindowMatches, let windowPoint, bounds.contains(convert(windowPoint, from: nil)) {
            return true
        }
        guard let window, bounds.width > 2, bounds.height > 2 else { return false }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        return onScreen.contains(NSEvent.mouseLocation)
    }

    private func installWheelMonitor() {
        guard wheelMonitor == nil else { return }
        wheelTarget.viewport = self
        let wheelTarget = wheelTarget
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let deltaY = event.scrollingDeltaY
            let deltaX = event.scrollingDeltaX
            let lineDelta = event.deltaY
            let precise = event.hasPreciseScrollingDeltas
            let timestamp = event.timestamp
            let windowPoint = event.locationInWindow
            let eventWindowID = event.window.map { ObjectIdentifier($0) }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let viewport = wheelTarget.viewport else { return false }
                let matches = eventWindowID == viewport.window.map { ObjectIdentifier($0) }
                return viewport.handleWheel(
                    deltaY: deltaY,
                    deltaX: deltaX,
                    lineDelta: lineDelta,
                    precise: precise,
                    timestamp: timestamp,
                    windowPoint: windowPoint,
                    eventWindowMatches: matches
                )
            }
            return consumed ? nil : event
        }
    }
}

struct SongListScroller: NSViewRepresentable {
    let tracks: [LocalTrack]
    let currentID: URL?
    let isPlaying: Bool
    let message: String
    let theme: IslandTheme
    let scrollKey: String
    let onPlay: (LocalTrack) -> Void

    func makeNSView(context: Context) -> SongListViewport {
        let viewport = SongListViewport()
        apply(to: viewport)
        return viewport
    }

    func updateNSView(_ viewport: SongListViewport, context: Context) {
        apply(to: viewport)
    }

    static func dismantleNSView(_ nsView: SongListViewport, coordinator: Coordinator) {
        nsView.removeWheelMonitor()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SongListViewport,
        context: Context
    ) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 1 ? $0 : nil } ?? 280
        if let height = proposal.height, height.isFinite, height > 40, height < 340 {
            nsView.slotSize = NSSize(width: width, height: height)
            return CGSize(width: width, height: height)
        }
        let height = nsView.slotSize.height > 40 ? nsView.slotSize.height : 160
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func apply(to viewport: SongListViewport) {
        viewport.onPlay = onPlay
        viewport.scrollKey = scrollKey
        viewport.tracks = tracks
        viewport.currentID = currentID
        viewport.isPlaying = isPlaying
        viewport.theme = theme
        viewport.message = message
        viewport.placeRows()
    }

    final class Coordinator {}
}

struct TrackRow: View {
    let track: LocalTrack
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AlbumBadge(artworkData: track.artworkData, isPlaying: isPlaying)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(theme.font(size: 12, weight: .semibold))
                        .foregroundStyle(theme.foreground(opacity: isCurrent ? 0.96 : 0.72))
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(theme.font(size: 10, weight: .medium))
                        .foregroundStyle(theme.mutedForeground(opacity: 0.84))
                        .lineLimit(1)
                }

                Spacer()

                if track.hasLyrics {
                    Image(systemName: "text.quote")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isCurrent ? theme.primaryAccent.opacity(0.9) : theme.mutedForeground(opacity: 0.54))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background {
                ThemedCardBackground(
                    isSelected: isCurrent,
                    accent: theme.primaryAccent,
                    cornerRadius: theme.cardCornerRadius
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandPressDownButtonStyle())
    }
}

struct LyricsPane: View {
    let track: LocalTrack?
    /// When false the whole lyric sheet stays unhighlighted rather than marking a wrong line.
    var positionIsReliable: Bool = true
    /// Live playhead sampled on a local timer — keeps the ScrollView identity stable.
    let positionProvider: () -> TimeInterval
    @Environment(\.islandTheme) private var theme
    @State private var loadingTimedOut = false
    /// Sampled playhead; updated without remounting the scroller.
    @State private var tickPosition: TimeInterval = 0
    /// Keep the last reliable line so a brief unreliable sample does not flash the sheet blank.
    @State private var stickyLyricIndex: Int?
    @State private var lastScrolledLineID: Int?

    private var lyricsText: String {
        guard let track else { return LumaBarL10n.lyricsNoTrack }
        let trimmed = track.lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch track.playbackSource {
        case .netEaseSong:
            // Once we have artwork/metadata, or loading timed out, stop infinite spinner copy.
            if track.artworkData != nil || loadingTimedOut {
                return LumaBarL10n.lyricsNone
            }
            return LumaBarL10n.lyricsLoading
        case .appleMusic:
            // Artwork may arrive before lyrics — don't treat artwork as "lyrics finished".
            if loadingTimedOut {
                return LumaBarL10n.lyricsNone
            }
            return LumaBarL10n.lyricsLoading
        case .netEase, .direct:
            return LumaBarL10n.lyricsNoEmbedded
        }
    }

    private var liveLyricIndex: Int? {
        guard positionIsReliable else { return nil }
        guard let timedLyrics = track?.timedLyrics, !timedLyrics.isEmpty else { return nil }
        // Hold the current line until the next line's timestamp begins —
        // no lead-in offset (that caused premature advances).
        let currentTime = tickPosition
        for index in timedLyrics.indices {
            let start = timedLyrics[index].time
            let end = index + 1 < timedLyrics.count
                ? timedLyrics[index + 1].time
                : TimeInterval.infinity
            if currentTime >= start && currentTime < end {
                return index
            }
        }
        return nil
    }

    private var currentLyricIndex: Int? {
        liveLyricIndex ?? stickyLyricIndex
    }

    private var currentLineID: Int? {
        guard let currentLyricIndex, let timedLyrics = track?.timedLyrics,
              timedLyrics.indices.contains(currentLyricIndex)
        else {
            return nil
        }
        return timedLyrics[currentLyricIndex].id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10, weight: .bold))
                Text(LumaBarL10n.lyrics)
                    .font(theme.font(size: 10, weight: .bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.mutedForeground(opacity: 0.9))

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    if let timedLyrics = track?.timedLyrics, !timedLyrics.isEmpty {
                        // Eager VStack: LazyVStack recycles cells when scrollTo recenters
                        // and a growing highlight font reflows — reads as bounce/flicker.
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(timedLyrics.enumerated()), id: \.element.id) { index, line in
                                let isCurrent = currentLyricIndex == index
                                Text(line.text)
                                    .font(theme.font(size: 11.5, weight: isCurrent ? .bold : .medium))
                                    .foregroundStyle(
                                        isCurrent
                                            ? (theme.isPixelStyled || theme.isLight
                                                ? theme.primaryAccent
                                                : Color.white.opacity(0.96))
                                            : theme.mutedForeground(opacity: 0.86)
                                    )
                                    .lineLimit(nil)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(.vertical, 32)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(lyricsText)
                            .font(theme.font(size: track?.hasLyrics == true ? 11 : 12, weight: .medium))
                            .foregroundStyle(track?.hasLyrics == true ? theme.foreground(opacity: 0.76) : theme.mutedForeground(opacity: 0.82))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 8)
                            .textSelection(.enabled)
                    }
                }
                .onAppear {
                    samplePlayhead()
                    scrollToCurrentLine(proxy: proxy, animated: false)
                }
                .onChange(of: track?.id) { _, _ in
                    stickyLyricIndex = nil
                    lastScrolledLineID = nil
                    samplePlayhead()
                    scrollToCurrentLine(proxy: proxy, animated: false)
                }
                .onChange(of: liveLyricIndex) { _, newIndex in
                    if let newIndex {
                        stickyLyricIndex = newIndex
                    }
                }
                .onChange(of: currentLineID) { _, newID in
                    guard newID != nil else { return }
                    scrollToCurrentLine(proxy: proxy, animated: true)
                }
            }
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            samplePlayhead()
        }
        .task(id: track?.id) {
            loadingTimedOut = false
            guard track?.hasLyrics != true else { return }
            let timeoutNs: UInt64 = track?.playbackSource == .appleMusic
                ? 10_000_000_000
                : 4_000_000_000
            try? await Task.sleep(nanoseconds: timeoutNs)
            if track?.hasLyrics != true {
                loadingTimedOut = true
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            ThemedCardBackground(cornerRadius: theme.isGrid ? 2 : 12)
        }
    }

    private func samplePlayhead() {
        let next = positionProvider()
        if abs(next - tickPosition) > 0.04 {
            tickPosition = next
        }
    }

    private func scrollToCurrentLine(proxy: ScrollViewProxy, animated: Bool) {
        guard let currentLineID, currentLineID != lastScrolledLineID else { return }
        lastScrolledLineID = currentLineID
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(currentLineID, anchor: .center)
            }
        } else {
            proxy.scrollTo(currentLineID, anchor: .center)
        }
    }
}

/// Fires on mouseDown. SwiftUI's default button waits for mouseUp; on this non-key
/// island panel a timer-driven rebuild often cancels the press before release.
///
/// The catcher must NOT steal hit-testing: forwarding wheel events into AppKit's
/// NSScrollView scrolled the clip view without updating SwiftUI's offset, so the
/// list snapped back to the first row on the next model refresh.
struct IslandPressDownButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .overlay {
                IslandPressDownCatcher(onDown: configuration.trigger)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
    }
}

struct IslandPressDownCatcher: NSViewRepresentable {
    let onDown: () -> Void

    func makeNSView(context: Context) -> IslandPressDownNSView {
        let view = IslandPressDownNSView()
        view.onDown = onDown
        return view
    }

    func updateNSView(_ view: IslandPressDownNSView, context: Context) {
        view.onDown = onDown
    }

    static func dismantleNSView(_ view: IslandPressDownNSView, coordinator: ()) {
        view.onDown = nil
    }
}

final class IslandPressDownNSView: NSView {
    var onDown: (() -> Void)?
    private var lastFireAt = Date.distantPast
    private var isMonitorRegistered = false

    private static var sharedMouseDownMonitor: Any?
    private static var installedViewCount = 0

    override var isOpaque: Bool { false }

    /// Pass all hit-testing through so SwiftUI ScrollView owns wheel / drag offset.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            guard !isMonitorRegistered else { return }
            isMonitorRegistered = true
            Self.installedViewCount += 1
            Self.installSharedMonitorIfNeeded()
        } else if isMonitorRegistered {
            isMonitorRegistered = false
            Self.installedViewCount = max(0, Self.installedViewCount - 1)
            if Self.installedViewCount == 0 {
                Self.removeSharedMonitor()
            }
        }
    }

    fileprivate func fireFromSharedMonitor() {
        let now = Date()
        guard now.timeIntervalSince(lastFireAt) > 0.18 else { return }
        lastFireAt = now
        onDown?()
    }

    private static func installSharedMonitorIfNeeded() {
        guard sharedMouseDownMonitor == nil else { return }
        sharedMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window else { return event }
            // Never steal seek / volume scrubbers — they need the full drag sequence.
            if hitIsIslandScrubber(in: window, at: event.locationInWindow) {
                return event
            }
            // Playlist arrows handle mouseDown themselves. A press-down overlay
            // nearby must not consume that click.
            if hitIsPlaylistStep(in: window, at: event.locationInWindow) {
                return event
            }
            guard let target = findPressDownView(in: window, at: event.locationInWindow) else {
                return event
            }
            target.fireFromSharedMonitor()
            // Consume — action already ran on mouseDown; don't wait for SwiftUI mouseUp.
            return nil
        }
    }

    private static func hitIsIslandScrubber(in window: NSWindow, at windowPoint: NSPoint) -> Bool {
        var view: NSView? = window.contentView?.hitTest(windowPoint)
        while let current = view {
            if current is NativeMusicSeekBarView || current is NativeIslandVolumeSliderView {
                return true
            }
            view = current.superview
        }
        // hitTest can miss transparent scrubbers; also probe by frame.
        func search(_ view: NSView) -> Bool {
            let local = view.convert(windowPoint, from: nil)
            guard view.bounds.contains(local) else { return false }
            if view is NativeMusicSeekBarView || view is NativeIslandVolumeSliderView {
                return true
            }
            for subview in view.subviews.reversed() {
                if search(subview) { return true }
            }
            return false
        }
        return window.contentView.map(search) ?? false
    }

    private static func hitIsPlaylistStep(in window: NSWindow, at windowPoint: NSPoint) -> Bool {
        func search(_ view: NSView) -> Bool {
            let local = view.convert(windowPoint, from: nil)
            guard view.bounds.contains(local) else { return false }
            if view is PlaylistStepNSView { return true }
            for subview in view.subviews.reversed() {
                if search(subview) { return true }
            }
            return false
        }
        return window.contentView.map(search) ?? false
    }

    private static func removeSharedMonitor() {
        if let sharedMouseDownMonitor {
            NSEvent.removeMonitor(sharedMouseDownMonitor)
            self.sharedMouseDownMonitor = nil
        }
    }

    /// Deepest press-down target under the cursor (hitTest is nil, so walk frames).
    private static func findPressDownView(in window: NSWindow, at windowPoint: NSPoint) -> IslandPressDownNSView? {
        guard let content = window.contentView else { return nil }

        func search(_ view: NSView) -> IslandPressDownNSView? {
            let local = view.convert(windowPoint, from: nil)
            guard view.bounds.contains(local) else { return nil }

            for subview in view.subviews.reversed() {
                if let found = search(subview) {
                    return found
                }
            }
            return view as? IslandPressDownNSView
        }

        return search(content)
    }
}

struct PlayerCircleButton: View {
    let systemName: String
    let action: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.foreground(opacity: 0.86))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                        .fill(theme.controlFill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandPressDownButtonStyle())
    }
}

struct NotchSideShape: Shape {
    let side: NotchSide
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()

        switch side {
        case .left:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - r),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        case .right:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }

        path.closeSubpath()
        return path
    }
}

struct NotchPaint {
    static let surface = LinearGradient(
        colors: [
            Color.black.opacity(0.74),
            Color(red: 0.004, green: 0.004, blue: 0.006).opacity(0.78),
            Color(red: 0.018, green: 0.019, blue: 0.022).opacity(0.82)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let panel = LinearGradient(
        colors: [
            Color(red: 0.018, green: 0.019, blue: 0.022).opacity(0.82),
            Color(red: 0.006, green: 0.006, blue: 0.008).opacity(0.88)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func edge(isHovering: Bool) -> LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(isHovering ? 0.035 : 0.012),
                .clear,
                .white.opacity(0.004)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct AlbumBadge: View {
    let artworkData: Data?
    let isPlaying: Bool
    @Environment(\.islandTheme) private var theme

    private var artworkImage: NSImage? {
        artworkData.flatMap(NSImage.init(data:))
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = theme.isGrid ? CGFloat(1) : max(6, side * 0.18)

            ZStack {
                if let artworkImage {
                    Image(nsImage: artworkImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    ZStack {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.0, green: 0.48, blue: 0.18),
                                        Color(red: 1.0, green: 0.82, blue: 0.22),
                                        Color(red: 0.13, green: 0.16, blue: 0.24)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        ForEach(0..<4, id: \.self) { index in
                            RoundedRectangle(cornerRadius: theme.isGrid ? 0 : 999)
                                .fill(.white.opacity(index == 0 ? 0.82 : 0.3))
                                .frame(
                                    width: side * CGFloat(0.64 + Double(index) * 0.18),
                                    height: max(1, side * (index == 0 ? 0.07 : 0.04))
                                )
                                .rotationEffect(.degrees(-24))
                                .offset(
                                    x: side * CGFloat(Double(index) * 0.08 - 0.18),
                                    y: side * CGFloat(Double(index) * 0.13 - 0.28)
                                )
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }

                if isPlaying {
                    if theme.isPixelStyled {
                        Rectangle()
                            .stroke(theme.activityAccent.opacity(0.92), lineWidth: max(1.1, side * 0.04))
                            .frame(width: side * 0.3, height: side * 0.3)
                    } else {
                        Circle()
                            .stroke(.white.opacity(0.65), lineWidth: max(1.1, side * 0.04))
                            .frame(width: side * 0.28, height: side * 0.28)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(theme.isPixelStyled ? theme.pixelBorder.opacity(0.58) : .white.opacity(0.14), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct ProgressRing: View {
    let progress: Double
    let active: Bool
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Group {
            if theme.isPixelStyled {
                GeometryReader { proxy in
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.2))
                        Rectangle()
                            .stroke(theme.pixelBorder.opacity(0.58), lineWidth: 2)

                        Image(systemName: active ? "waveform" : "music.note")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(active ? theme.activityAccent : theme.primaryAccent)
                    }
                    .overlay(alignment: .bottomLeading) {
                        Rectangle()
                            .fill(active ? theme.activityAccent : theme.primaryAccent)
                            .frame(
                                width: proxy.size.width * CGFloat(min(1, max(0, progress))),
                                height: 3
                            )
                    }
                }
            } else {
                ZStack {
                    Circle()
                        .stroke(
                            theme.isNook ? theme.pixelBorder.opacity(0.24) : .white.opacity(0.12),
                            lineWidth: 3
                        )

                    Circle()
                        .trim(from: 0, to: min(1, max(0, progress)))
                        .stroke(
                            theme.isNook
                                ? (active ? theme.activityAccent : theme.primaryAccent)
                                : (active ? Color.islandGreen : Color.islandTangerine),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    Image(systemName: active ? "waveform" : "music.note")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(
                            theme.isNook
                                ? theme.foreground(opacity: 0.84)
                                : Color.white.opacity(0.78)
                        )
                }
            }
        }
        .animation(.linear(duration: 0.18), value: progress)
        .animation(.easeInOut(duration: 0.16), value: active)
    }
}

extension Color {
    static let islandTangerine = Color(red: 1.0, green: 0.56, blue: 0.22)
    static let islandGreen = Color(red: 0.34, green: 0.94, blue: 0.42)
    static let islandCyan = Color(red: 0.33, green: 0.82, blue: 1.0)
    static let islandRed = Color(red: 1.0, green: 0.32, blue: 0.35)
}

