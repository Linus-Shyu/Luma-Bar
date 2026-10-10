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

struct CameraBarView: View {
    var body: some View {
        CompactBarBackground(isHovering: false)
    }
}

/// Compact title that gently scrolls back and forth when it cannot fit instead of truncating.
/// Clipped to its container so the animation never bleeds over neighboring elements.
struct CompactMarqueeText: View {
    let text: String
    let font: Font
    let measuredFont: NSFont
    let color: Color
    @State private var phase: CGFloat = 0

    private var lineHeight: CGFloat {
        max(measuredFont.ascender - measuredFont.descender + measuredFont.leading, 12)
    }

    private var textWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: measuredFont]).width)
    }

    var body: some View {
        GeometryReader { proxy in
            let containerWidth = proxy.size.width
            let needsScroll = textWidth > containerWidth + 0.5
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: needsScroll, vertical: false)
                .offset(x: needsScroll ? -phase * (textWidth - containerWidth + 24) : 0)
                .frame(width: containerWidth, alignment: .leading)
                .clipped()
                .onAppear {
                    startScroll(needsScroll: needsScroll, containerWidth: containerWidth)
                }
                .onChange(of: text) { _, _ in
                    startScroll(needsScroll: needsScroll, containerWidth: containerWidth)
                }
        }
        .frame(height: lineHeight)
    }

    private func startScroll(needsScroll: Bool, containerWidth: CGFloat) {
        guard needsScroll else {
            phase = 0
            return
        }
        let travel = textWidth - containerWidth + 24
        guard travel > 1 else { return }
        phase = 0
        withAnimation(
            .easeInOut(duration: max(2.8, travel / 26))
                .repeatForever(autoreverses: true)
        ) {
            phase = 1
        }
    }
}

struct CompactLeftView: View {
    @ObservedObject var model: MusicPlayerModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Button {
            if model.isExpanded {
                model.isExpanded = false
            } else {
                model.prepareExpandedContentForUserInteraction()
                model.isExpanded = true
            }
        } label: {
            HStack(spacing: 10) {
                if model.activeMode == .system {
                    SystemGlyphBadge(metrics: model.systemMetrics)
                        .frame(width: 24, height: 24)
                } else if model.shouldShowExternalTokenInCompact || model.activeMode == .token {
                    TokenGlyphBadge(progress: model.agentTokenProgress)
                        .frame(width: 24, height: 24)
                } else if model.activeMode == .agent {
                    AgentGlyphBadge(isActive: model.isAgentStreaming)
                        .frame(width: 24, height: 24)
                } else {
                    AlbumBadge(
                        artworkData: model.displayedArtworkData,
                        isPlaying: model.displayedIsPlaying
                    )
                        .frame(width: 24, height: 24)
                }

                VStack(alignment: .leading, spacing: 2) {
                    CompactMarqueeText(
                        text: model.shouldShowExternalTokenInCompact
                            ? model.agentModelDisplayName
                            : (model.activeMode == .music ? model.compactMusicTitle : model.activeDisplayTitle),
                        font: theme.font(size: 10, weight: .semibold),
                        measuredFont: theme.nsFont(size: 10, weight: .semibold),
                        color: theme.foreground(opacity: 0.92)
                    )
                    Text(
                        model.shouldShowExternalTokenInCompact
                            ? model.agentTokenSummaryText
                            : (model.activeMode == .music ? model.compactMusicSubtitle : model.activeDisplaySubtitle)
                    )
                        .font(theme.font(size: 8.5, weight: .medium))
                        .foregroundStyle(theme.mutedForeground(opacity: 0.92))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10 + NotchMetrics.notchEdgeOverlap)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.16), value: model.activeMode)
        .animation(.easeInOut(duration: 0.16), value: model.displayedIsPlaying)
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
}

struct CompactRightView: View {
    @ObservedObject var model: MusicPlayerModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Group {
            if model.activeMode == .system {
                HStack(spacing: 4) {
                    CompactMetricChip(systemName: "cpu", value: model.systemMetrics.cpuText)
                    CompactMetricChip(systemName: "memorychip", value: model.systemMetrics.memoryText)
                }
            } else if model.activeMode == .token {
                Button {
                    if model.isExpanded {
                        model.isExpanded = false
                    } else {
                        model.prepareExpandedContentForUserInteraction()
                        model.isExpanded = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        TokenUsageGauge(
                            progress: model.agentTokenProgress,
                            label: "AI",
                            accent: model.agentTokenAccentColor
                        )
                            .frame(width: 24, height: 24)

                        Text(model.agentTokenPercentText)
                            .font(theme.font(size: 11, weight: .bold))
                            .foregroundStyle(model.agentTokenAccentColor)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help(LumaBarL10n.tokenOpenHelp(model.agentTokenSummaryText))
                .animation(.easeInOut(duration: 0.2), value: model.agentTokenProgress)
            } else if model.activeMode == .agent {
                Button {
                    if model.isExpanded, model.activeMode == .agent {
                        model.dismissExpandedPanel()
                    } else {
                        model.showAgent()
                        model.isExpanded = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.isAgentStreaming ? "bolt.fill" : "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text(model.isAgentStreaming ? LumaBarL10n.agentLive : (model.agentHasAPIKey ? LumaBarL10n.agentAsk : LumaBarL10n.agentKeyBadge))
                            .font(theme.font(size: 9, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(theme.foreground(opacity: 0.86))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                            .fill(theme.controlFill)
                    )
                }
                .buttonStyle(.plain)
                .help(model.isExpanded ? LumaBarL10n.agentClose : LumaBarL10n.agentOpen)
            } else {
                HStack(spacing: NotchMetrics.compactRightControlSpacing) {
                    Button {
                        model.togglePlayback()
                    } label: {
                        Image(systemName: model.displayedIsPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.accentForeground)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                                    .fill(theme.isLight ? theme.primaryAccent : (theme.isPixelStyled ? theme.primaryAccent : Color.white.opacity(0.92)))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(model.displayedIsPlaying ? LumaBarL10n.musicPause : LumaBarL10n.musicPlay)

                    Button {
                        if model.isExpanded {
                            model.isExpanded = false
                        } else {
                            model.prepareExpandedContentForUserInteraction()
                            model.isExpanded = true
                        }
                    } label: {
                        if model.shouldShowExternalTokenInCompact {
                            TokenUsageGauge(
                                progress: model.agentTokenProgress,
                                label: "AI",
                                accent: model.agentTokenAccentColor
                            )
                            .frame(width: 24, height: 24)
                        } else {
                            ProgressRing(
                                progress: model.showsPlaybackTimeline ? model.displayedProgress : 0,
                                active: model.displayedIsPlaying
                            )
                                .frame(width: 24, height: 24)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(
                        model.shouldShowExternalTokenInCompact
                            ? LumaBarL10n.musicOpenPlayer(brand: model.externalTokenBrandLabel, percent: model.agentTokenPercentText)
                            : LumaBarL10n.musicOpenPlayer
                    )
                    .animation(.easeInOut(duration: 0.2), value: model.agentTokenProgress)
                    .animation(.easeInOut(duration: 0.16), value: model.isMonitoringExternalTokenUsage)

                    Button {
                        model.nextTrack()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.foreground(opacity: 0.76))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(LumaBarL10n.quickNext)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.16), value: model.activeMode)
        .animation(.easeInOut(duration: 0.16), value: model.displayedIsPlaying)
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
}

struct CompactMetricChip: View {
    let systemName: String
    let value: String
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.foreground(opacity: 0.85))

            Text(value)
                .font(theme.font(size: 9, weight: .semibold))
                .foregroundStyle(theme.foreground(opacity: 0.88))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                .fill(theme.controlFill)
                .overlay {
                    if theme.isPixelStyled || theme.isLight {
                        RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                            .stroke(theme.pixelBorder.opacity(theme.isLight ? 0.22 : 0.42), lineWidth: 1)
                    }
                }
        }
    }
}

struct SystemGlyphBadge: View {
    let metrics: SystemMetricsSnapshot
    @Environment(\.islandTheme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: theme.isForge
                            ? [Color(red: 0.965, green: 0.941, blue: 0.855), Color(red: 0.906, green: 0.863, blue: 0.753)]
                            : (theme.isLight
                            ? [Color.white.opacity(0.98), Color(red: 0.88, green: 0.95, blue: 1.0)]
                            : [Color(red: 0.12, green: 0.13, blue: 0.16), Color(red: 0.07, green: 0.08, blue: 0.1)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                .stroke(theme.isPixelStyled || theme.isLight ? theme.pixelBorder.opacity(0.62) : .white.opacity(0.16), lineWidth: 2)

            RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                .trim(from: 0, to: max(0.04, min(1, metrics.cpuUsage)))
                .stroke(theme.activityAccent, style: StrokeStyle(lineWidth: 2.4, lineCap: theme.isPixelStyled ? .butt : .round))
                .rotationEffect(.degrees(-90))

            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.isLight ? theme.foreground(opacity: 0.9) : Color.white.opacity(0.9))
        }
    }
}

struct AgentGlyphBadge: View {
    let isActive: Bool
    @Environment(\.islandTheme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.isForge
                                ? Color(red: 0.965, green: 0.941, blue: 0.855)
                                : (theme.isLight ? Color.white.opacity(0.96) : Color(red: 0.12, green: 0.16, blue: 0.24)),
                            theme.isForge
                                ? Color(red: 0.906, green: 0.863, blue: 0.753)
                                : (theme.isLight ? Color(red: 0.9, green: 0.96, blue: 1.0) : Color(red: 0.05, green: 0.07, blue: 0.1))
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: theme.controlCornerRadius, style: .continuous)
                .stroke(
                    isActive ? theme.activityAccent.opacity(0.82) : ((theme.isPixelStyled || theme.isLight) ? theme.pixelBorder.opacity(0.62) : .white.opacity(0.16)),
                    lineWidth: 2
                )

            Image(systemName: isActive ? "bolt.fill" : "sparkles")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isActive ? theme.activityAccent : theme.foreground(opacity: 0.9))
        }
        .animation(.easeInOut(duration: 0.16), value: isActive)
    }
}

struct TokenGlyphBadge: View {
    let progress: Double

    var body: some View {
        TokenUsageGauge(progress: progress, label: "AI")
    }
}

struct SystemDashboardView: View {
    let metrics: SystemMetricsSnapshot
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                SystemMetricTile(
                    title: LumaBarL10n.sysCPU,
                    value: metrics.cpuText,
                    detail: metrics.cpuDetailText,
                    systemName: "cpu",
                    tint: Color.islandGreen,
                    progress: metrics.cpuUsage
                )
                SystemMetricTile(
                    title: LumaBarL10n.sysMemory,
                    value: metrics.memoryText,
                    detail: "\(metrics.memoryDetailText) • Free \(metrics.memoryFreeText)",
                    systemName: "memorychip",
                    tint: Color(red: 0.43, green: 0.69, blue: 1.0),
                    progress: metrics.memoryUsage
                )
            }

            HStack(spacing: 10) {
                SystemMetricTile(
                    title: LumaBarL10n.sysDisk,
                    value: metrics.diskText,
                    detail: "Used \(metrics.diskUsedText) • \(metrics.diskDetailText)",
                    systemName: "internaldrive",
                    tint: Color(red: 1.0, green: 0.66, blue: 0.26),
                    progress: metrics.diskUsage
                )
                SystemMetricTile(
                    title: LumaBarL10n.sysBattery,
                    value: metrics.batteryText,
                    detail: "\(metrics.powerSourceName) • \(metrics.isCharging ? "Charging" : "Discharging")",
                    systemName: metrics.isCharging ? "bolt.fill" : "battery.75",
                    tint: metrics.isCharging ? Color.islandGreen : Color(red: 1.0, green: 0.56, blue: 0.22),
                    progress: metrics.batteryLevel ?? 1
                )
            }

            HStack(spacing: 10) {
                ThemedCardBackground()
                    .overlay {
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(metrics.networkDownText, systemImage: "arrow.down")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(theme.foreground(opacity: 0.9))
                                    Text(LumaBarL10n.sysTotal(metrics.networkDownTotalText))
                                        .font(theme.font(size: 9, weight: .medium))
                                        .foregroundStyle(theme.mutedForeground(opacity: 0.9))
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Label(metrics.networkUpText, systemImage: "arrow.up")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(theme.foreground(opacity: 0.9))
                                    Text(LumaBarL10n.sysTotal(metrics.networkUpTotalText))
                                        .font(theme.font(size: 9, weight: .medium))
                                        .foregroundStyle(theme.mutedForeground(opacity: 0.9))
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(metrics.uptimeText)
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundStyle(theme.foreground(opacity: 0.92))
                                    Text(LumaBarL10n.sysUptime)
                                        .font(theme.font(size: 9, weight: .medium))
                                        .foregroundStyle(theme.mutedForeground(opacity: 0.9))
                                }
                            }

                            HStack(spacing: 12) {
                                Label("Load \(metrics.loadAverageText)", systemImage: "gauge.with.needle")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(theme.foreground(opacity: 0.78))

                                Spacer()

                                Text(metrics.osVersionText)
                                    .font(theme.font(size: 9, weight: .medium))
                                    .foregroundStyle(theme.mutedForeground(opacity: 0.94))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    .frame(height: 86)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct SystemMetricTile: View {
    let title: String
    let value: String
    let detail: String
    let systemName: String
    let tint: Color
    let progress: Double
    @Environment(\.islandTheme) private var theme

    var body: some View {
        ThemedCardBackground(accent: tint)
            .overlay {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: systemName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(tint)

                        Text(title)
                            .font(theme.font(size: 10, weight: .bold))
                            .foregroundStyle(theme.foreground(opacity: 0.88))
                    }

                    Text(value)
                        .font(theme.font(size: 15, weight: .bold))
                        .foregroundStyle(theme.foreground(opacity: 0.94))

                    Text(detail)
                        .font(theme.font(size: 9, weight: .medium))
                        .foregroundStyle(theme.mutedForeground(opacity: 0.9))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    SystemUsageBar(tint: tint, progress: progress)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
    }
}

struct SystemUsageBar: View {
    let tint: Color
    let progress: Double
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Group {
            if theme.isPixelStyled && !theme.isNook {
                let segmentCount = 14
                let filledSegments = Int(ceil(min(1, max(0, progress)) * Double(segmentCount)))

                HStack(spacing: 2) {
                    ForEach(0..<segmentCount, id: \.self) { index in
                        Rectangle()
                            .fill(index < filledSegments ? tint.opacity(0.95) : theme.pixelBorder.opacity(0.1))
                    }
                }
            } else {
                GeometryReader { proxy in
                    let width = max(0, min(1, progress)) * proxy.size.width

                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(theme.isLight ? theme.primaryAccent.opacity(0.12) : Color.white.opacity(0.08))

                        Capsule(style: .continuous)
                            .fill(tint.opacity(0.9))
                            .frame(width: width)
                    }
                }
            }
        }
        .frame(height: theme.isPixelStyled ? 6 : 4)
    }
}
