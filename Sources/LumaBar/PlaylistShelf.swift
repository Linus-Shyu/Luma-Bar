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


@MainActor
final class PlaylistSwipeMonitorView: NSView {
    var onSwipe: ((Int) -> Void)?

    private var eventMonitor: Any?
    private var accumulatedHorizontalDelta: CGFloat = 0
    private var lastTriggerDate = Date.distantPast

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeEventMonitor()
        guard window != nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -2, dy: -2).contains(location) else { return }

        if event.type == .scrollWheel {
            guard event.momentumPhase.isEmpty else { return }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 0.7 else { return }

            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                accumulatedHorizontalDelta = 0
            }

            let physicalDelta = event.isDirectionInvertedFromDevice
                ? event.scrollingDeltaX
                : -event.scrollingDeltaX
            accumulatedHorizontalDelta += physicalDelta

            if abs(accumulatedHorizontalDelta) >= 24 {
                trigger(offset: accumulatedHorizontalDelta > 0 ? 1 : -1)
                accumulatedHorizontalDelta = 0
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                accumulatedHorizontalDelta = 0
            }
            return
        }

        guard event.type == .swipe, abs(event.deltaX) > abs(event.deltaY) else { return }
        trigger(offset: event.deltaX > 0 ? 1 : -1)
    }

    private func trigger(offset: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastTriggerDate) >= 0.32 else { return }
        lastTriggerDate = now
        onSwipe?(offset)
    }

    func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }
}

struct PlaylistSwipeMonitor: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> PlaylistSwipeMonitorView {
        let view = PlaylistSwipeMonitorView(frame: .zero)
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ view: PlaylistSwipeMonitorView, context: Context) {
        view.onSwipe = onSwipe
    }

    static func dismantleNSView(_ view: PlaylistSwipeMonitorView, coordinator: Void) {
        view.removeEventMonitor()
    }
}

struct NetEasePlaylistShelf: View {
    @ObservedObject var model: MusicPlayerModel
    @State private var scrollPositionID: String?
    @Environment(\.islandTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !model.netEasePlaylists.isEmpty {
            HStack(spacing: 4) {
                playlistStepButton(systemName: "chevron.left", help: LumaBarL10n.musicPrevPlaylist) {
                    model.browseAdjacentNetEasePlaylist(offset: -1)
                }

                // No ScrollView: its NSScroller still paints over the chips on this panel even
                // with hidden indicators. Arrows and swipes page through the playlists instead.
                // The chips live in an overlay so their total width never widens the panel.
                // Drag/swipe stay on this strip only — a gesture on the arrows made the
                // first click get swallowed, so ">" needed a second press.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 4) {
                            ForEach(visiblePlaylists) { playlist in
                                NetEasePlaylistChip(
                                    playlist: playlist,
                                    isSelected: model.selectedNetEasePlaylistID == playlist.id
                                ) {
                                    // Browse/load tracks in-panel; don't open NetEase (focus steal blocks selecting songs).
                                    model.browseNetEasePlaylist(playlist)
                                }
                                .fixedSize()
                                .id(playlist.id)
                            }
                        }
                        .fixedSize()
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: scrollPositionID)
                    }
                    .clipped()
                    .background {
                        PlaylistSwipeMonitor { offset in
                            model.browseAdjacentNetEasePlaylist(offset: offset)
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24)
                            .onEnded { value in
                                guard abs(value.translation.width) > abs(value.translation.height),
                                      abs(value.translation.width) >= 36
                                else {
                                    return
                                }
                                model.browseAdjacentNetEasePlaylist(
                                    offset: value.translation.width < 0 ? 1 : -1
                                )
                            }
                    )

                playlistStepButton(systemName: "chevron.right", help: LumaBarL10n.musicNextPlaylist) {
                    model.browseAdjacentNetEasePlaylist(offset: 1)
                }
            }
            .frame(height: 28)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.isPixelStyled || theme.isLight ? theme.pixelBorder.opacity(0.24) : Color.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.horizontal, 28)
            }
            .onAppear {
                synchronizeInitialPosition()
            }
            .onChange(of: model.netEasePlaylists.map(\.id)) { _, playlistIDs in
                guard !playlistIDs.isEmpty else { return }
                if scrollPositionID == nil || !playlistIDs.contains(scrollPositionID ?? "") {
                    scrollPositionID = model.selectedNetEasePlaylistID ?? playlistIDs.first
                }
                selectInitialNetEasePlaylistIfNeeded()
            }
            .onChange(of: model.selectedNetEasePlaylistID) { _, playlistID in
                guard let playlistID, scrollPositionID != playlistID else { return }
                if reduceMotion {
                    scrollPositionID = playlistID
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        scrollPositionID = playlistID
                    }
                }
            }
        }
    }

    /// Starts one chip before the selected playlist so the user can see both directions.
    private var visiblePlaylists: ArraySlice<NetEasePlaylist> {
        let playlists = model.netEasePlaylists
        guard let anchorID = scrollPositionID ?? model.selectedNetEasePlaylistID,
              let index = playlists.firstIndex(where: { $0.id == anchorID })
        else {
            return playlists[...]
        }
        return playlists[max(playlists.startIndex, index - 1)...]
    }

    private func synchronizeInitialPosition() {
        scrollPositionID = model.selectedNetEasePlaylistID ?? model.netEasePlaylists.first?.id
        selectInitialNetEasePlaylistIfNeeded()
    }

    private func selectInitialNetEasePlaylistIfNeeded() {
        guard model.musicLibrarySource == .netEase,
              model.selectedNetEasePlaylistID == nil,
              let firstPlaylist = model.netEasePlaylists.first
        else {
            return
        }
        model.browseNetEasePlaylist(firstPlaylist)
    }

    private func playlistStepButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let enabled = model.netEasePlaylists.count > 1
        return Image(systemName: systemName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.foreground(opacity: enabled ? 0.78 : 0.28))
            .frame(width: 22, height: 26)
            .background(
                RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                    .fill(theme.controlFill)
            )
            .overlay {
                // Direct mouseDown. SwiftUI Button under the shelf's old drag gesture
                // ignored the first click.
                PlaylistStepCatcher(enabled: enabled, action: action)
            }
            .accessibilityLabel(help)
            .help(help)
    }
}

struct PlaylistStepCatcher: NSViewRepresentable {
    let enabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> PlaylistStepNSView {
        let view = PlaylistStepNSView()
        view.enabled = enabled
        view.action = action
        return view
    }

    func updateNSView(_ view: PlaylistStepNSView, context: Context) {
        view.enabled = enabled
        view.action = action
    }
}

final class PlaylistStepNSView: NSView {
    var enabled = true
    var action: (() -> Void)?
    private var lastFireAt = Date.distantPast

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFireAt) > 0.18 else { return }
        lastFireAt = now
        action?()
    }
}

struct NetEasePlaylistChip: View {
    let playlist: NetEasePlaylist
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                NetEasePlaylistCover(data: playlist.coverData)
                    .frame(width: 18, height: 18)

                Text(playlist.name)
                    .font(theme.font(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.foreground(opacity: isSelected ? 0.96 : 0.76))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 26, alignment: .leading)
            .background {
                ThemedCardBackground(
                    isSelected: isSelected,
                    accent: theme.primaryAccent,
                    cornerRadius: theme.isGrid ? 2 : 9
                )
            }
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(theme.primaryAccent)
                        .frame(height: theme.isPixelStyled ? 2 : 1.5)
                        .padding(.horizontal, theme.isPixelStyled ? 2 : 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandPressDownButtonStyle())
        .help(playlist.name)
    }
}

struct NetEasePlaylistCover: View {
    let data: Data?
    @Environment(\.islandTheme) private var theme

    private var image: NSImage? {
        data.flatMap(NSImage.init(data:))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.isGrid ? 1 : 6, style: .continuous)
                .fill(theme.controlFill)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note.list")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.mutedForeground(opacity: 0.9))
            }
        }
        .overlay {
            if theme.isPixelStyled || theme.isLight {
                RoundedRectangle(cornerRadius: theme.isGrid ? 1 : 6, style: .continuous)
                    .stroke(theme.pixelBorder.opacity(0.36), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.isGrid ? 1 : 6, style: .continuous))
    }
}

