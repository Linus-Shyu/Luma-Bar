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

enum AgentFocusedField {
    case apiKey
    case message
}

final class AgentSecureTextFieldView: NSSecureTextField {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        if let panel = window as? IslandPanel {
            panel.allowsKeyboardFocus = true
            panel.lockTransparentRenderChrome()
        }
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

final class AgentMessageTextFieldView: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        if let panel = window as? IslandPanel {
            panel.allowsKeyboardFocus = true
            panel.lockTransparentRenderChrome()
        }
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

struct AgentAPIKeyField: NSViewRepresentable {
    @Binding var text: String
    let hasSavedKey: Bool
    let shouldFocus: Bool
    let onSubmit: () -> Void
    @Environment(\.islandTheme) private var theme

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> AgentSecureTextFieldView {
        let field = AgentSecureTextFieldView()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.textColor = textColor
        field.placeholderString = parentPlaceholder
        field.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        return field
    }

    func updateNSView(_ field: AgentSecureTextFieldView, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = parentPlaceholder
        field.textColor = textColor
        field.isEditable = true
        field.isEnabled = true
        if field.stringValue != text {
            field.stringValue = text
        }

        context.coordinator.focusIfNeeded(field)
    }

    private var parentPlaceholder: String {
        let provider = AgentModelProvider.current.displayName
        if hasSavedKey {
            return "\(provider) key saved  " + String(repeating: "\u{2022}", count: 10)
        }
        return "\(provider) API Key"
    }

    private var textColor: NSColor {
        if theme.isForge {
            return NSColor(calibratedRed: 0.153, green: 0.212, blue: 0.173, alpha: 0.94)
        }
        if theme.isLight {
            return NSColor(calibratedRed: 0.094, green: 0.204, blue: 0.322, alpha: 0.92)
        }
        if theme.isPixelStyled {
            return NSColor(calibratedRed: 0.82, green: 1.0, blue: 0.92, alpha: 0.94)
        }
        return .white.withAlphaComponent(0.88)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AgentAPIKeyField
        private var didFocus = false

        init(parent: AgentAPIKeyField) {
            self.parent = parent
        }

        func focusIfNeeded(_ field: AgentSecureTextFieldView) {
            guard parent.shouldFocus, !didFocus else { return }
            didFocus = true

            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let panel = field.window as? IslandPanel {
                    panel.allowsKeyboardFocus = true
                    panel.lockTransparentRenderChrome()
                }
                field.window?.makeKeyAndOrderFront(nil)
                field.window?.makeFirstResponder(field)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSecureTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

/// AppKit-backed Agent chat field — SwiftUI TextField cannot become first responder when
/// the hosting NSPanel historically returned `canBecomeKey == false`.
struct AgentMessageTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    @Environment(\.islandTheme) private var theme

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> AgentMessageTextFieldView {
        let field = AgentMessageTextFieldView()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.textColor = textColor
        field.placeholderString = placeholder
        field.font = theme.isPixelStyled
            ? .monospacedSystemFont(ofSize: 12, weight: .medium)
            : .systemFont(ofSize: 12, weight: .medium)
        // Clip and scroll. Truncating the tail hides the caret and aborts IME composition.
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        return field
    }

    func updateNSView(_ field: AgentMessageTextFieldView, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.textColor = textColor
        field.isEditable = true
        field.isEnabled = true
        // Writing stringValue during marked text cancels the Chinese composition.
        guard !Self.isComposing(field), field.stringValue != text else { return }
        field.stringValue = text
    }

    private static func isComposing(_ field: NSTextField) -> Bool {
        (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
    }

    private var textColor: NSColor {
        if theme.isForge {
            return NSColor(calibratedRed: 0.153, green: 0.212, blue: 0.173, alpha: 0.94)
        }
        if theme.isLight {
            return NSColor(calibratedRed: 0.094, green: 0.204, blue: 0.322, alpha: 0.92)
        }
        if theme.isPixelStyled {
            return NSColor(calibratedRed: 0.82, green: 1.0, blue: 0.92, alpha: 0.94)
        }
        return .white.withAlphaComponent(0.9)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AgentMessageTextField

        init(parent: AgentMessageTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Marked pinyin is not committed text. Publishing it makes SwiftUI
            // write the field back and the input method drops the composition.
            if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true {
                return
            }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

enum AgentMarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedItem(String)
    case orderedItem(number: String, text: String)
    case quote(String)
    case code(String)
    case rule
}

struct AgentMarkdownOutputView: View {
    let markdown: String
    @Environment(\.islandTheme) private var theme

    private var blocks: [AgentMarkdownBlock] {
        Self.parse(markdown)
    }

    var body: some View {
        if markdown.isEmpty {
            Text("...")
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.mutedForeground(opacity: 0.82))
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func blockView(_ block: AgentMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inlineText(text)
                .font(theme.font(size: level == 1 ? 15 : (level == 2 ? 14 : 13), weight: .bold))
                .foregroundStyle(theme.foreground(opacity: 0.94))
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(text):
            inlineText(text)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.foreground(opacity: 0.84))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

        case let .unorderedItem(text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\u{2022}")
                    .font(theme.font(size: 12, weight: .bold))
                    .foregroundStyle(theme.activityAccent.opacity(0.9))
                    .frame(width: 9, alignment: .center)
                inlineText(text)
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.foreground(opacity: 0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .orderedItem(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number + ".")
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundStyle(theme.activityAccent.opacity(0.9))
                    .frame(minWidth: 14, alignment: .trailing)
                inlineText(text)
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.foreground(opacity: 0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(theme.activityAccent.opacity(0.62))
                    .frame(width: 2)
                inlineText(text)
                    .font(theme.font(size: 11, weight: .medium))
                    .italic()
                    .foregroundStyle(theme.mutedForeground(opacity: 0.94))
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        theme.isForge
                            ? theme.foreground(opacity: 0.92)
                            : (theme.isLight
                                ? theme.foreground(opacity: 0.88)
                                : (theme.isPixelStyled ? theme.primaryAccent.opacity(0.9) : Color.islandGreen.opacity(0.9)))
                    )
                    .textSelection(.enabled)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 8)
            }
            .background(
                theme.isForge
                    ? Color(red: 0.784, green: 0.745, blue: 0.647).opacity(0.42)
                    : (theme.isLight
                        ? theme.primaryAccent.opacity(0.1)
                        : Color.black.opacity(theme.isPixelStyled ? 0.32 : 0.24))
            )
            .clipShape(ThemeRectShape(radius: theme.controlCornerRadius, chamfer: 0))

        case .rule:
            Divider()
                .overlay(theme.separatorColor)
        }
    }

    private func inlineText(_ source: String) -> Text {
        Text(Self.inlineMarkdown(source))
    }

    private static func inlineMarkdown(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }

    private static func parse(_ source: String) -> [AgentMarkdownBlock] {
        var blocks: [AgentMarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInsideCodeBlock = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            blocks.append(.code(codeLines.joined(separator: "\n")))
            codeLines.removeAll(keepingCapacity: true)
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isInsideCodeBlock {
                if trimmed.hasPrefix("```") {
                    flushCode()
                    isInsideCodeBlock = false
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                isInsideCodeBlock = true
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            let headingLevel = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(headingLevel) {
                let textStart = trimmed.index(trimmed.startIndex, offsetBy: headingLevel)
                if textStart < trimmed.endIndex, trimmed[textStart].isWhitespace {
                    flushParagraph()
                    blocks.append(.heading(
                        level: headingLevel,
                        text: String(trimmed[textStart...]).trimmingCharacters(in: .whitespaces)
                    ))
                    continue
                }
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.unorderedItem(String(trimmed.dropFirst(2))))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if let markerIndex = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) {
                let number = trimmed[..<markerIndex]
                let contentStart = trimmed.index(after: markerIndex)
                if !number.isEmpty,
                   number.allSatisfy(\.isNumber),
                   contentStart < trimmed.endIndex,
                   trimmed[contentStart].isWhitespace {
                    flushParagraph()
                    blocks.append(.orderedItem(
                        number: String(number),
                        text: String(trimmed[contentStart...]).trimmingCharacters(in: .whitespaces)
                    ))
                    continue
                }
            }

            paragraphLines.append(trimmed)
        }

        if isInsideCodeBlock {
            flushParagraph()
            flushCode()
        } else {
            flushParagraph()
        }
        return blocks
    }
}

struct TokenUsageGauge: View {
    let progress: Double
    let label: String
    var accent: Color?
    @Environment(\.islandTheme) private var theme

    private var clampedProgress: Double {
        min(1, max(0, progress))
    }

    private var progressAccent: Color {
        accent ?? theme.activityAccent
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            switch theme {
            case .void:
                let lineWidth = max(3, side * 0.1)
                ZStack {
                    Circle()
                        .stroke(Color(red: 0.075, green: 0.105, blue: 0.17), lineWidth: lineWidth + 2)
                    Circle()
                        .trim(from: 0, to: clampedProgress)
                        .stroke(
                            progressAccent,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text(label)
                        .font(.system(size: max(8, side * 0.24), weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }

            case .horizon:
                let lineWidth = max(3, side * 0.1)
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.72))
                    Circle()
                        .stroke(theme.primaryAccent.opacity(0.16), lineWidth: lineWidth + 2)
                    Circle()
                        .trim(from: 0, to: clampedProgress)
                        .stroke(
                            LinearGradient(
                                colors: [theme.primaryAccent, progressAccent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text(label)
                        .font(.system(size: max(8, side * 0.24), weight: .bold, design: .rounded))
                        .foregroundStyle(theme.foregroundColor.opacity(0.92))
                }

            case .forge:
                let radius = max(3, side * 0.1)
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                let lineWidth = max(3, side * 0.085)
                ZStack {
                    shape
                        .fill(Color(red: 0.914, green: 0.875, blue: 0.788))
                    AdventureXGridOverlay()
                        .opacity(0.72)
                        .clipShape(shape)
                    shape
                        .stroke(theme.pixelBorder.opacity(0.92), lineWidth: 2)
                    shape
                        .inset(by: 4)
                        .stroke(Color.white.opacity(0.48), lineWidth: 1)
                    shape
                        .trim(from: 0, to: clampedProgress)
                        .stroke(
                            clampedProgress >= 0.72 ? progressAccent : theme.primaryAccent,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                        )
                        .rotationEffect(.degrees(-90))
                    Text(label)
                        .font(.system(size: max(8, side * 0.21), weight: .black, design: .monospaced))
                        .foregroundStyle(theme.foreground(opacity: 0.94))
                        .padding(.horizontal, 3)
                        .background(Color(red: 0.961, green: 0.933, blue: 0.863).opacity(0.82))
                }

            case .grid:
                let cellCount = 16
                let filledCells = Int(ceil(clampedProgress * Double(cellCount)))
                ZStack {
                    Rectangle()
                        .fill(Color(red: 0.018, green: 0.045, blue: 0.062).opacity(0.98))

                    VStack(spacing: 2) {
                        ForEach(0..<4, id: \.self) { row in
                            HStack(spacing: 2) {
                                ForEach(0..<4, id: \.self) { column in
                                    let fillIndex = (3 - row) * 4 + column
                                    Rectangle()
                                        .fill(
                                            fillIndex < filledCells
                                                ? (fillIndex.isMultiple(of: 3) ? theme.primaryAccent : progressAccent)
                                                : theme.pixelBorder.opacity(0.1)
                                        )
                                }
                            }
                        }
                    }
                    .padding(5)

                    Text(label)
                        .font(.system(size: max(7, side * 0.2), weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.96))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.78))
                }
                .overlay {
                    Rectangle()
                        .stroke(theme.pixelBorder.opacity(0.8), lineWidth: 2)
                }

            case .arcade:
                let radius = max(5, side * 0.18)
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.1, green: 0.13, blue: 0.18),
                                    Color(red: 0.045, green: 0.065, blue: 0.09)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(theme.pixelBorder.opacity(0.78), lineWidth: 1.5)

                    Text(">_")
                        .font(.system(size: max(8, side * 0.23), weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.primaryAccent.opacity(0.96))
                }
                .overlay(alignment: .bottomLeading) {
                    GeometryReader { meter in
                        Rectangle()
                            .fill(progressAccent)
                            .frame(
                                width: max(0, meter.size.width - 8) * clampedProgress,
                                height: 3
                            )
                            .offset(x: 4, y: -4)
                    }
                }

            case .nook:
                let lineWidth = max(4, side * 0.105)
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.976, blue: 0.945).opacity(0.96),
                                    Color(red: 0.988, green: 0.927, blue: 0.871).opacity(0.86)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Circle()
                        .stroke(
                            Color(red: 0.78, green: 0.61, blue: 0.52).opacity(0.18),
                            lineWidth: lineWidth
                        )
                    Circle()
                        .trim(from: 0, to: clampedProgress)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.95, green: 0.70, blue: 0.50),
                                    progressAccent
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text(label)
                        .font(.system(size: max(8, side * 0.23), weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.31, green: 0.22, blue: 0.19).opacity(0.88))
                }
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.78), lineWidth: 1)
                }
                .shadow(color: theme.primaryAccent.opacity(0.12), radius: 6, y: 2)

            case .aura:
                let lineWidth = max(3.5, side * 0.1)
                ZStack {
                    LiquidGlassSurface(shape: Circle(), role: .control, cornerRadius: side / 2)
                    Circle()
                        .trim(from: 0, to: clampedProgress)
                        .stroke(
                            LinearGradient(
                                colors: [theme.primaryAccent, progressAccent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text(label)
                        .font(.system(size: max(8, side * 0.24), weight: .bold, design: .rounded))
                        .foregroundStyle(theme.foreground(opacity: 0.94))
                }
            }
        }
        .animation(theme.isGrid ? nil : .easeInOut(duration: 0.22), value: clampedProgress)
    }
}

struct TokenProgressTrack: View {
    let progress: Double
    var accent: Color?
    @Environment(\.islandTheme) private var theme

    private var clampedProgress: Double {
        min(1, max(0, progress))
    }

    private var progressAccent: Color {
        accent ?? theme.activityAccent
    }

    var body: some View {
        Group {
            switch theme {
            case .void:
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.08))
                        Capsule(style: .continuous)
                            .fill(
	                                LinearGradient(
	                                    colors: [Color.islandCyan, progressAccent],
	                                    startPoint: .leading,
	                                    endPoint: .trailing
	                                )
                            )
                            .frame(width: proxy.size.width * clampedProgress)

                        HStack(spacing: 0) {
                            Spacer()
                            tick(opacity: 0.2)
                            Spacer()
                            tick(opacity: 0.2)
                            Spacer()
                            tick(opacity: 0.2)
                            Spacer()
                        }
                    }
                }

            case .horizon:
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(theme.primaryAccent.opacity(0.13))
                        Capsule(style: .continuous)
                            .fill(
	                                LinearGradient(
	                                    colors: [theme.primaryAccent, progressAccent],
	                                    startPoint: .leading,
	                                    endPoint: .trailing
	                                )
                            )
                            .frame(width: proxy.size.width * clampedProgress)
                    }
                }

            case .forge:
                let segmentCount = 20
                let filledSegments = Int(ceil(clampedProgress * Double(segmentCount)))
                HStack(spacing: 2) {
                    ForEach(0..<segmentCount, id: \.self) { index in
                        Rectangle()
                            .fill(
	                                index < filledSegments
	                                    ? (index.isMultiple(of: 4) ? theme.primaryAccent : progressAccent)
	                                    : theme.pixelBorder.opacity(0.14)
                            )
                            .overlay {
                                Rectangle()
                                    .stroke(theme.pixelBorder.opacity(0.28), lineWidth: 0.5)
                            }
                    }
                }

            case .grid:
                let segmentCount = 24
                let filledSegments = Int(ceil(clampedProgress * Double(segmentCount)))
                HStack(spacing: 2) {
                    ForEach(0..<segmentCount, id: \.self) { index in
                        Rectangle()
                            .fill(
	                                index < filledSegments
	                                    ? (index.isMultiple(of: 5) ? theme.primaryAccent : progressAccent)
	                                    : theme.pixelBorder.opacity(0.1)
                            )
                            .overlay {
                                Rectangle()
                                    .stroke(theme.pixelBorder.opacity(0.18), lineWidth: 0.5)
                            }
                    }
                }

            case .arcade:
                GeometryReader { proxy in
                    let filledWidth = proxy.size.width * clampedProgress
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(theme.pixelControlFill.opacity(0.88))

                        Rectangle()
                            .fill(
	                                LinearGradient(
	                                    colors: [theme.primaryAccent, progressAccent],
	                                    startPoint: .leading,
	                                    endPoint: .trailing
	                                )
                            )
                            .frame(width: filledWidth)

                        HStack(spacing: 0) {
                            ForEach(0..<9, id: \.self) { _ in
                                Rectangle()
                                    .fill(.black.opacity(0.24))
                                    .frame(width: 1)
                                Spacer()
                            }
                        }

                        if clampedProgress > 0 {
                            Rectangle()
                                .fill(.white.opacity(0.9))
                                .frame(width: 2)
                                .offset(x: max(0, filledWidth - 2))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(theme.pixelBorder.opacity(0.62), lineWidth: 1)
                    }
                }

            case .nook:
                GeometryReader { proxy in
                    let filledWidth = proxy.size.width * clampedProgress
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.82, green: 0.66, blue: 0.57).opacity(0.15))
                        Capsule(style: .continuous)
                            .fill(
	                                LinearGradient(
	                                    colors: [
                                            Color(red: 0.96, green: 0.73, blue: 0.54),
                                            progressAccent
                                        ],
	                                    startPoint: .leading,
	                                    endPoint: .trailing
	                                )
                            )
                            .frame(width: filledWidth)
                    }
                    .clipShape(Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.7), lineWidth: 0.75)
                    }
                    .shadow(color: theme.primaryAccent.opacity(0.1), radius: 3, y: 1)
                }

            case .aura:
                GeometryReader { proxy in
                    let track = Capsule(style: .continuous)
                    ZStack(alignment: .leading) {
                        LiquidGlassSurface(
                            shape: track,
                            role: .control,
                            cornerRadius: proxy.size.height / 2
                        )
                        track
                            .fill(
                                LinearGradient(
                                    colors: [theme.primaryAccent, progressAccent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: proxy.size.width * clampedProgress)
                            .clipShape(track)
                    }
                }
            }
        }
        .frame(height: theme == .void || theme == .horizon || theme == .aura ? 4 : 7)
        .animation(theme.isGrid ? nil : .easeInOut(duration: 0.22), value: clampedProgress)
    }

    private func tick(opacity: Double) -> some View {
        Rectangle()
            .fill(.white.opacity(opacity))
            .frame(width: 1)
    }
}

struct TokenUsageCardBackground: View {
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let radius: CGFloat = theme == .void || theme == .horizon || theme == .aura ? 41 : (theme.isGrid ? 2 : 12)
        let shape = ThemeRectShape(radius: radius, chamfer: 0)

        ZStack(alignment: .top) {
            switch theme {
            case .void:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.145, blue: 0.245),
                            Color(red: 0.31, green: 0.45, blue: 0.7)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                shape.strokeBorder(.white.opacity(0.22), lineWidth: 1)

            case .horizon:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.985, green: 0.997, blue: 1.0),
                            Color(red: 0.86, green: 0.93, blue: 0.99)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.strokeBorder(theme.primaryAccent.opacity(0.34), lineWidth: 1)

            case .forge:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.97, green: 0.945, blue: 0.86),
                            Color(red: 0.82, green: 0.78, blue: 0.66)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.strokeBorder(theme.pixelBorder.opacity(0.58), lineWidth: 1.5)

            case .grid:
                shape.fill(Color(red: 0.018, green: 0.045, blue: 0.062).opacity(0.98))
                PixelGridOverlay()
                    .clipShape(shape)
                shape.strokeBorder(theme.pixelBorder.opacity(0.78), lineWidth: 2)
                PixelAccentRail()
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)

            case .arcade:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.11, blue: 0.15),
                            Color(red: 0.045, green: 0.06, blue: 0.085)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                shape.strokeBorder(theme.pixelBorder.opacity(0.76), lineWidth: 1.5)
                PixelAccentRail()
                    .frame(height: 2)
                    .padding(.horizontal, 8)
                    .padding(.top, 5)

            case .nook:
                VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
                    .clipShape(shape)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.84),
                            Color(red: 1.0, green: 0.95, blue: 0.9).opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.strokeBorder(Color.white.opacity(0.72), lineWidth: 1)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.primaryAccent, theme.activityAccent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 58, height: 2)
                    .padding(.top, 6)

            case .aura:
                AuraPlateFill(cornerRadius: radius)
            }
        }
        .modifier(CompactBarClipIfNeeded(theme: theme, shape: shape))
    }
}

struct CodexTokenOverlayBackground: View {
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let shape = ThemeRectShape(radius: theme.tokenOverlayCornerRadius, chamfer: 0)

        ZStack(alignment: .top) {
            switch theme {
            case .void:
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                    .clipShape(shape)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.045, green: 0.06, blue: 0.08).opacity(0.9),
                            Color(red: 0.065, green: 0.105, blue: 0.145).opacity(0.94)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                shape.strokeBorder(.white.opacity(0.11), lineWidth: 1)

            case .horizon:
                VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
                    .clipShape(shape)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.96),
                            Color(red: 0.88, green: 0.95, blue: 1.0).opacity(0.96)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.strokeBorder(theme.primaryAccent.opacity(0.36), lineWidth: 1)

            case .forge:
                shape.fill(Color(red: 0.961, green: 0.933, blue: 0.863))
                AdventureXGridOverlay()
                    .clipShape(shape)
                shape.strokeBorder(theme.pixelBorder.opacity(0.98), lineWidth: 2)
                AdventureXHardwareMarks()
                    .clipShape(shape)
                HStack(spacing: 3) {
                    Rectangle().fill(theme.primaryAccent).frame(width: 82)
                    Rectangle().fill(theme.activityAccent).frame(width: 42)
                    Rectangle().fill(Color(red: 0.32, green: 0.34, blue: 0.28).opacity(0.64))
                }
                .frame(height: 4)
                .padding(.horizontal, 18)
                .padding(.top, 6)

            case .grid:
                shape.fill(Color(red: 0.018, green: 0.045, blue: 0.062).opacity(0.99))
                PixelGridOverlay()
                    .clipShape(shape)
                shape.strokeBorder(theme.pixelBorder.opacity(0.88), lineWidth: 2)
                PixelAccentRail()
                    .frame(height: 2)
                    .padding(.horizontal, 5)
                    .padding(.top, 4)

            case .arcade:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.065, green: 0.09, blue: 0.13),
                            Color(red: 0.025, green: 0.045, blue: 0.07)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                shape.strokeBorder(theme.pixelBorder.opacity(0.9), lineWidth: 1.5)
                PixelAccentRail()
                    .frame(height: 3)
                    .padding(.horizontal, 10)
                    .padding(.top, 5)

            case .nook:
                VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
                    .clipShape(shape)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.86),
                            Color(red: 1.0, green: 0.95, blue: 0.9).opacity(0.74)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.strokeBorder(Color.white.opacity(0.76), lineWidth: 1)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.primaryAccent, theme.activityAccent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 68, height: 2)
                    .padding(.top, 6)

            case .aura:
                AuraPlateFill(cornerRadius: theme.tokenOverlayCornerRadius)
            }
        }
        .modifier(CompactBarClipIfNeeded(theme: theme, shape: shape))
    }
}

struct AgentTokenUsageBar: View {
    @ObservedObject var model: MusicPlayerModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: theme.isGrid ? 11 : 14) {
            TokenUsageGauge(
                progress: model.agentTokenProgress,
                label: "AI",
                accent: model.agentTokenAccentColor
            )
                .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.agentModelDisplayName)
                    .font(theme.font(size: 18, weight: .bold))
                    .foregroundStyle(theme.foreground())
                    .lineLimit(1)

                Text("\(model.agentTokenStateText) · \(model.agentTokenSummaryText)")
                    .font(theme.font(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.mutedForeground(opacity: theme.isPixelStyled ? 0.72 : 0.9))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(model.agentTokenPercentText)
                .font(theme.font(size: 18, weight: .bold))
                .foregroundStyle(model.agentTokenAccentColor)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, theme.isGrid ? 12 : 16)
        .frame(width: 344, height: 82)
        .background { TokenUsageCardBackground() }
        .shadow(
            color: theme.isPixelStyled
                ? .clear
                : (theme.isLight ? theme.primaryAccent.opacity(0.2) : .black.opacity(0.38)),
            radius: theme.isPixelStyled ? 0 : 18,
            x: 0,
            y: theme.isPixelStyled ? 0 : 10
        )
        .help("\(model.agentRemainingTokens) tokens remain in the configured context window")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AI token usage")
        .accessibilityValue("\(model.agentTokenPercentText), \(model.agentTokenSummaryText) tokens")
    }
}

struct CodexTokenOverlayView: View {
    @ObservedObject var model: MusicPlayerModel
    @Environment(\.islandTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: theme.isGrid ? 10 : 12) {
            HStack(spacing: theme.isGrid ? 11 : 14) {
                TokenUsageGauge(
                    progress: model.agentTokenProgress,
                    label: "AI",
                    accent: model.agentTokenAccentColor
                )
                    .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
	                        Group {
	                            if theme.isGrid {
	                                Rectangle()
	                                    .fill(model.agentTokenAccentColor.opacity(model.agentTokenProgress >= 0.7 ? 0.95 : 0.44))
	                            } else {
	                                Circle()
	                                    .fill(model.agentTokenAccentColor.opacity(model.agentTokenProgress >= 0.7 ? 0.95 : 0.44))
	                            }
	                        }
                        .frame(width: 5, height: 5)

                        Text(model.externalTokenBrandLabel)
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(
                                theme.isLight
                                    ? theme.primaryAccent.opacity(0.86)
                                    : (theme.isPixelStyled
                                    ? theme.pixelBorder.opacity(0.82)
                                    : Color.white.opacity(0.4))
                            )
                    }

                    Text(model.agentModelDisplayName)
                        .font(theme.font(size: 18, weight: .bold))
                        .foregroundStyle(theme.foreground(opacity: 0.94))
                        .lineLimit(1)

                    Text("\(model.agentTokenStateText) · \(model.agentTokenSummaryText)")
                        .font(theme.font(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.mutedForeground(opacity: theme.isPixelStyled ? 0.76 : 0.92))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

	                VStack(alignment: .trailing, spacing: 1) {
	                    Text(model.agentTokenPercentText)
	                        .font(theme.font(size: theme.isGrid ? 22 : 25, weight: .bold))
	                        .foregroundStyle(model.agentTokenAccentColor)
	                        .monospacedDigit()
	                        .lineLimit(1)
	                    Text("\(model.agentRemainingTokenText) LEFT")
	                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
	                        .foregroundStyle(model.agentTokenAccentColor.opacity(0.78))
	                        .lineLimit(1)
	                }
	            }
	            .frame(height: 50)

	            TokenProgressTrack(progress: model.agentTokenProgress, accent: model.agentTokenAccentColor)

            if let weekly = model.codexWeeklyQuota {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Text("WEEKLY · \(weekly.windowLabel)")
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(
                                theme.isLight
                                    ? theme.primaryAccent.opacity(0.86)
                                    : (theme.isPixelStyled
                                        ? theme.pixelBorder.opacity(0.82)
                                        : Color.white.opacity(0.4))
                            )
                        Spacer(minLength: 4)
                        Text(LumaBarL10n.remainingPercent(weekly.remainingPercentText))
                            .font(theme.font(size: 10, weight: .bold))
                            .foregroundStyle(model.codexWeeklyQuotaAccentColor)
                            .monospacedDigit()
                        Text(LumaBarL10n.usedPercent(weekly.usedPercentText))
                            .font(theme.font(size: 10, weight: .semibold))
                            .foregroundStyle(theme.foreground(opacity: 0.88))
                            .monospacedDigit()
                    }

                    TokenProgressTrack(progress: weekly.progress, accent: model.codexWeeklyQuotaAccentColor)

                    HStack {
                        Text(weekly.resetLabel ?? "周额度")
                            .font(theme.font(size: 9, weight: .medium))
                            .foregroundStyle(theme.mutedForeground(opacity: theme.isPixelStyled ? 0.72 : 0.84))
                        Spacer(minLength: 4)
                        if let plan = weekly.planType?.uppercased(), !plan.isEmpty {
                            Text(plan)
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(model.codexWeeklyQuotaAccentColor.opacity(0.82))
                        }
                    }
                }
            }

            if let credits = model.kiroCreditsUsage {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Text("MONTHLY \(credits.displayName.uppercased())")
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(
                                theme.isLight
                                    ? theme.primaryAccent.opacity(0.86)
                                    : (theme.isPixelStyled
                                        ? theme.pixelBorder.opacity(0.82)
                                        : Color.white.opacity(0.4))
                            )
                        Spacer(minLength: 4)
                        Text(credits.summaryText)
                            .font(theme.font(size: 10, weight: .semibold))
                            .foregroundStyle(theme.foreground(opacity: 0.88))
                            .monospacedDigit()
                        Text(credits.percentText)
                            .font(theme.font(size: 10, weight: .bold))
                            .foregroundStyle(model.kiroCreditsAccentColor)
                            .monospacedDigit()
                    }

                    TokenProgressTrack(progress: credits.progress, accent: model.kiroCreditsAccentColor)

                    HStack {
                        Text(credits.resetLabel ?? "本月额度")
                            .font(theme.font(size: 9, weight: .medium))
                            .foregroundStyle(theme.mutedForeground(opacity: theme.isPixelStyled ? 0.72 : 0.84))
                        Spacer(minLength: 4)
                        Text(credits.remainingText)
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(model.kiroCreditsAccentColor.opacity(0.82))
                    }
                }
            }
        }
        .padding(.horizontal, theme.isGrid ? 14 : 18)
        .padding(.vertical, theme.isGrid ? 12 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { CodexTokenOverlayBackground() }
        .scaleEffect(
            x: theme.isGrid ? 1 : 0.985,
            y: hasAppeared || theme.isGrid ? 1 : 0.88,
            anchor: .top
        )
        .offset(y: hasAppeared || theme.isGrid ? 0 : -6)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            if reduceMotion {
                hasAppeared = true
            } else if theme.isGrid {
                withAnimation(.linear(duration: 0.1)) {
                    hasAppeared = true
                }
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    hasAppeared = true
                }
            }
        }
        .animation(theme.isGrid ? nil : .easeInOut(duration: 0.22), value: model.agentTokenProgress)
        .animation(theme.isGrid ? nil : .easeInOut(duration: 0.22), value: model.kiroCreditsUsage?.progress)
        .help(
            model.kiroCreditsUsage.map {
                "\(model.agentRemainingTokens) tokens remain · \($0.remainingText.lowercased()) credits"
            } ?? "\(model.agentRemainingTokens) tokens remain in the configured context window"
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.externalTokenAccessibilityLabel)
        .accessibilityValue(
            model.kiroCreditsUsage.map {
                "\(model.agentTokenPercentText), \(model.agentTokenSummaryText) tokens, credits \($0.summaryText)"
            } ?? "\(model.agentTokenPercentText), \(model.agentTokenSummaryText) tokens"
        )
    }
}

@MainActor
enum TaskCompletionAppearance {
    /// Notice whose entrance already played. Layout passes rebuild the hosting view
    /// several times a second; replaying the spring each time reads as repeated pop-ups.
    static var animatedNoticeID: String?
}

struct TaskCompletionOverlayView: View {
    @ObservedObject var model: MusicPlayerModel
    @Environment(\.islandTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared: Bool

    init(model: MusicPlayerModel) {
        self.model = model
        let id = model.taskCompletionNotice?.id
        _hasAppeared = State(initialValue: id != nil && id == TaskCompletionAppearance.animatedNoticeID)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.islandGreen.opacity(theme.isLight ? 0.16 : 0.2))
                Circle()
                    .strokeBorder(Color.islandGreen.opacity(0.5), lineWidth: 1)
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.islandGreen)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text("\((model.taskCompletionNotice?.source.uppercaseBrandName ?? "AI")) \(LumaBarL10n.taskComplete.uppercased(with: LumaBarL10n.resolvedLocale))")
                    .font(theme.font(size: 8.5, weight: .semibold))
                    .foregroundStyle(theme.primaryAccent.opacity(theme.isLight ? 0.9 : 0.72))
                Text(LumaBarL10n.taskComplete)
                    .font(theme.font(size: 18, weight: .bold))
                    .foregroundStyle(theme.foreground(opacity: 0.96))
                Text(model.taskCompletionNotice?.title ?? LumaBarL10n.taskCompleteFallbackDetail)
                    .font(theme.font(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.mutedForeground(opacity: 0.9))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                model.dismissTaskCompletionNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.mutedForeground(opacity: 0.78))
                    .frame(width: 28, height: 28)
                    .background(theme.controlFill.opacity(0.75))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(LumaBarL10n.dismissNotice)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { CodexTokenOverlayBackground() }
        .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.92, anchor: .top)
        .offset(y: hasAppeared || reduceMotion ? 0 : -5)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            guard !hasAppeared else { return }
            TaskCompletionAppearance.animatedNoticeID = model.taskCompletionNotice?.id
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    hasAppeared = true
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            LumaBarL10n.taskCompleteA11y(brand: model.taskCompletionNotice?.source.shortBrandName ?? "AI")
        )
    }
}

struct FullScreenTaskCompletionToastView: View {
    let notice: TaskCompletionNotice
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.islandGreen.opacity(theme.isLight ? 0.15 : 0.2))
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.islandGreen)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(LumaBarL10n.backgroundTaskComplete(brand: notice.source.uppercaseBrandName))
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.primaryAccent)
                Text(notice.title)
                    .font(theme.font(size: 14, weight: .bold))
                    .foregroundStyle(theme.foreground(opacity: 0.95))
                    .lineLimit(1)
                Text(LumaBarL10n.returnForFullResult)
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.mutedForeground(opacity: 0.84))
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            ZStack {
                VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
                    .clipShape(shape)
                shape.fill(
                    theme.isLight
                        ? Color.white.opacity(0.82)
                        : Color(red: 0.045, green: 0.055, blue: 0.075).opacity(0.9)
                )
                shape.strokeBorder(
                    theme.isLight ? Color.white.opacity(0.78) : Color.white.opacity(0.14),
                    lineWidth: 1
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            LumaBarL10n.backgroundTaskCompleteA11y(brand: notice.source.shortBrandName, title: notice.title)
        )
    }
}

struct TokenDashboardView: View {
    @ObservedObject var model: MusicPlayerModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(spacing: theme.isPixelStyled ? 16 : 22) {
            Spacer(minLength: 4)

            AgentTokenUsageBar(model: model)

            HStack(spacing: 0) {
                tokenMetric(
                    title: LumaBarL10n.tokenInput,
                    value: model.agentInputTokenText,
                    tint: theme.isPixelStyled ? theme.pixelBorder : Color.islandCyan
                )
                divider
                tokenMetric(title: LumaBarL10n.tokenOutput, value: model.agentOutputTokenText, tint: theme.activityAccent)
	                divider
	                tokenMetric(
	                    title: LumaBarL10n.tokenRemaining,
	                    value: model.agentRemainingTokenText,
	                    tint: model.agentTokenAccentColor
	                )
            }
            .padding(.horizontal, theme.isPixelStyled ? 6 : 0)
            .frame(width: 344, height: 58)
            .background {
                if theme.isPixelStyled {
                    ThemedCardBackground(cornerRadius: theme.cardCornerRadius)
                }
            }

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.isPixelStyled ? theme.pixelBorder.opacity(0.32) : theme.separatorColor)
            .frame(width: theme.isGrid ? 2 : 1, height: 34)
    }

    private func tokenMetric(title: String, value: String, tint: Color) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(theme.font(size: 17, weight: .bold))
                .foregroundStyle(tint.opacity(0.94))
                .monospacedDigit()
                .lineLimit(1)
            Text(title.uppercased())
                .font(theme.font(size: 9, weight: .semibold))
                .foregroundStyle(theme.mutedForeground(opacity: theme.isPixelStyled ? 0.66 : 0.84))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct AdventureXAgentSectionBackground: View {
    let label: String
    let detail: String
    let accent: Color
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let shape = ThemeRectShape(radius: theme.fieldCornerRadius, chamfer: 0)

        ZStack(alignment: .top) {
            shape.fill(Color(red: 0.914, green: 0.875, blue: 0.788))
            AdventureXGridOverlay()
                .opacity(0.78)
                .clipShape(shape)
            shape.strokeBorder(theme.pixelBorder.opacity(0.92), lineWidth: 2)

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(accent)
                        .frame(width: 28, height: 3)
                    Text(label)
                        .font(.system(size: 8.5, weight: .black, design: .monospaced))
                        .tracking(0.45)
                    Spacer(minLength: 6)
                    Text(detail)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.mutedForeground(opacity: 0.92))
                }
                .foregroundStyle(theme.foreground(opacity: 0.92))
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Color(red: 0.839, green: 0.804, blue: 0.698).opacity(0.94))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.pixelBorder.opacity(0.72))
                        .frame(height: 1)
                }

                Spacer(minLength: 0)
            }
            .clipShape(shape)
        }
    }
}

struct AgentDashboardView: View {
    @ObservedObject var model: MusicPlayerModel
    @FocusState private var focusedField: AgentFocusedField?
    @Environment(\.islandTheme) private var theme

    private var canSaveAPIKey: Bool {
        !model.agentAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: theme.isForge ? 6 : 8) {
            if model.agentShowsAPIKeySetup {
            HStack(spacing: 8) {
                Image(systemName: model.agentHasAPIKey ? "key.fill" : "key")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(model.agentHasAPIKey ? theme.activityAccent : theme.foreground(opacity: 0.72))
                    .frame(width: 22, height: 22)

                AgentAPIKeyField(
                    text: $model.agentAPIKeyDraft,
                    hasSavedKey: model.agentHasAPIKey,
                    shouldFocus: !model.agentHasAPIKey
                ) {
                    model.saveAgentAPIKey()
                }
                .frame(height: 24)

                Button {
                    model.pasteAgentAPIKeyFromPasteboard()
                    focusedField = .apiKey
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.foreground(opacity: 0.76))
                .background { controlSurface(fill: theme.controlFill) }
                .help(LumaBarL10n.agentPasteKey)

                Button {
                    model.saveAgentAPIKey()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSaveAPIKey ? theme.accentForeground : theme.mutedForeground(opacity: 0.62))
                .background {
                    controlSurface(
                        fill: canSaveAPIKey
                            ? (theme.isPixelStyled || theme.isLight ? theme.primaryAccent : Color.white.opacity(0.9))
                            : theme.controlFill
                    )
                }
                .disabled(!canSaveAPIKey)
                .help(model.agentHasAPIKey ? "Replace API key" : "Save API key")

                if model.agentHasAPIKey {
                    Button {
                        model.clearSavedAgentAPIKey()
                        focusedField = .apiKey
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.foreground(opacity: 0.66))
                    .background {
                        controlSurface(
                            fill: theme.isPixelStyled
                                ? Color.red.opacity(0.16)
                                : (theme.isLight ? Color.red.opacity(0.1) : Color.white.opacity(0.08))
                        )
                    }
                    .help(LumaBarL10n.agentClearKey)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .padding(.top, theme.isForge ? 18 : 0)
            .background {
                if theme.isForge {
                    AdventureXAgentSectionBackground(
                        label: "ACCESS KEY",
                        detail: model.agentHasAPIKey ? "SECURE / READY" : "INPUT REQUIRED",
                        accent: model.agentHasAPIKey ? theme.activityAccent : theme.primaryAccent
                    )
                } else {
                    ThemedCardBackground(cornerRadius: theme.fieldCornerRadius)
                }
            }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.activityAccent)
                        .frame(width: 22, height: 22)
                    Text("\(AgentModelProvider.current.displayName) · \(LumaBarL10n.builtinKey)")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(theme.foreground(opacity: 0.78))
                    Spacer(minLength: 0)
                    Text(AgentModelProvider.current.defaultModel)
                        .font(theme.font(size: 9.5, weight: .medium))
                        .foregroundStyle(theme.mutedForeground(opacity: 0.8))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .padding(.top, theme.isForge ? 18 : 0)
                .background {
                    if theme.isForge {
                        AdventureXAgentSectionBackground(
                            label: "PROVIDER",
                            detail: "BUILT-IN / READY",
                            accent: theme.activityAccent
                        )
                    } else {
                        ThemedCardBackground(cornerRadius: theme.fieldCornerRadius)
                    }
                }
            }

            HStack(spacing: 6) {
                if theme.isForge {
                    Text(LumaBarL10n.agentCTX)
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(theme.accentForeground)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background { controlSurface(fill: theme.primaryAccent) }
                }
                Image(systemName: model.agentContextIcon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(
                        theme.isForge
                            ? theme.activityAccent.opacity(0.96)
                            : Color.islandCyan.opacity(0.9)
                    )
                Text(model.agentContextLabel)
                    .font(theme.font(size: 10, weight: .semibold))
                    .foregroundStyle(theme.foreground(opacity: 0.68))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(model.agentStatus)
                    .font(theme.font(size: 9, weight: .medium))
                    .foregroundStyle(theme.mutedForeground(opacity: 0.84))
                    .lineLimit(1)
            }
            .padding(.horizontal, theme.isForge ? 6 : 0)
            .frame(height: theme.isForge ? 22 : 16)
            .background {
                if theme.isForge {
                    ThemedCardBackground(cornerRadius: theme.fieldCornerRadius)
                }
            }

            ZStack(alignment: .topLeading) {
                ScrollView(showsIndicators: false) {
                    AgentMarkdownOutputView(markdown: model.agentResponse)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 9)
                        .padding(.top, theme.isForge ? 24 : 10)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: theme.isForge ? 64 : 56,
                maxHeight: theme.isForge ? 78 : 72
            )
            .background {
                if theme.isForge {
                    AdventureXAgentSectionBackground(
                        label: "AGENT FIELD LOG",
                        detail: model.isAgentStreaming ? "LIVE FEED" : "STANDBY",
                        accent: model.isAgentStreaming ? theme.activityAccent : theme.primaryAccent
                    )
                } else {
                    ThemedCardBackground(cornerRadius: theme.fieldCornerRadius)
                }
            }

            if !model.agentQuickActions.isEmpty {
                HStack(spacing: 7) {
                    if theme.isForge {
                        Text(LumaBarL10n.agentTools)
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(theme.accentForeground)
                            .padding(.horizontal, 6)
                            .frame(height: 24)
                            .background { controlSurface(fill: theme.activityAccent) }
                    }
                    ForEach(model.agentQuickActions) { action in
                        quickButton(title: action.title, icon: action.icon) {
                            model.runAgentQuickAction(action.kind)
                            if !model.agentInput.isEmpty {
                                focusedField = .message
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    Button {
                        model.isAgentStreaming ? model.cancelAgentRequest() : model.clearAgentOutput()
                    } label: {
                            Image(systemName: model.isAgentStreaming ? "stop.fill" : "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 26, height: 24)
                                .background { controlSurface(fill: theme.controlFill) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.foreground(opacity: 0.74))
                    .help(model.isAgentStreaming ? "Stop" : "Clear")
                }
            }

            if let message = model.pendingMessageAction {
                HStack(spacing: 7) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.primaryAccent)
                    Text("给 \(message.recipient)：\(message.content)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.foreground(opacity: 0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Button {
                        model.cancelPendingMessage()
                    } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 24, height: 22)
                                .background { controlSurface(fill: theme.controlFill) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.foreground(opacity: 0.68))
                    .help(LumaBarL10n.cancelSend)

                    Button {
                        model.requestOrSendPendingMessage()
                    } label: {
                            Image(systemName: model.isMessageConfirmationPending ? "checkmark" : "paperplane.fill")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 24, height: 22)
                                .background {
                                    controlSurface(
                                        fill: model.isMessageConfirmationPending
                                            ? theme.primaryAccent
                                            : theme.controlFill
                                    )
                                }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        model.isMessageConfirmationPending
                            ? Color.white
                            : theme.foreground(opacity: 0.76)
                    )
                    .help(model.isMessageConfirmationPending ? "确认发送" : "发送信息")
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(ThemedCardBackground(cornerRadius: theme.isGrid ? 2 : 7))
            }

            if let command = model.pendingAgentShellCommand {
                HStack(spacing: 7) {
                    Image(systemName: "terminal")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.islandGreen)
                    Text(command)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.foreground(opacity: 0.72))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    Button {
                        model.copyPendingAgentShellCommand()
                    } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 24, height: 22)
                                .background { controlSurface(fill: theme.controlFill) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.foreground(opacity: 0.72))
                    .help(LumaBarL10n.agentCopyCommand)

                    Button {
                        model.requestOrExecutePendingAgentShellCommand()
                    } label: {
                            Image(systemName: model.isAgentShellConfirmationPending ? "checkmark" : "play.fill")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 24, height: 22)
                                .background {
                                    controlSurface(
                                        fill: model.isAgentShellConfirmationPending
                                            ? Color.islandRed.opacity(0.9)
                                            : theme.controlFill
                                    )
                                }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.isAgentShellConfirmationPending ? Color.white : theme.foreground(opacity: 0.76))
                    .help(model.isAgentShellConfirmationPending ? LumaBarL10n.confirmRun : LumaBarL10n.runCommand)
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(ThemedCardBackground(cornerRadius: theme.isGrid ? 2 : 7))
            }

            HStack(spacing: 8) {
                Button {
                    model.toggleVoiceWhisper()
                } label: {
                    Image(
                        systemName: model.isVoiceWhisperFinalizing
                            ? "ellipsis.circle.fill"
                            : (model.isVoiceWhisperRecording ? "stop.fill" : "mic.fill")
                        )
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 32, height: 34)
                        .background {
                            controlSurface(
                                fill: model.isVoiceWhisperRecording
                                    ? theme.primaryAccent.opacity(0.92)
                                    : theme.controlFill
                            )
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.isVoiceWhisperRecording ? theme.accentForeground : theme.foreground(opacity: 0.74))
                .disabled(model.isVoiceWhisperFinalizing)
                .help(
                    model.isVoiceWhisperFinalizing
                        ? LumaBarL10n.voiceFinishing
                        : (model.isVoiceWhisperRecording ? LumaBarL10n.voiceFinishWhisper : LumaBarL10n.voiceStartWhisper)
                )

                AgentMessageTextField(
                    text: $model.agentInput,
                    placeholder: model.agentInputPlaceholder
                ) {
                    model.submitAgentPrompt()
                }
                    .frame(minHeight: 34)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(ThemedCardBackground(cornerRadius: theme.fieldCornerRadius))

                Button {
                    model.submitAgentPrompt()
                } label: {
                    Image(systemName: model.isAgentStreaming ? "waveform" : "paperplane.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.accentForeground)
                        .frame(width: 34, height: 34)
                        .background {
                            controlSurface(
                                fill: theme.isPixelStyled || theme.isLight
                                    ? theme.primaryAccent.opacity(model.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.34 : 0.96)
                                    : Color.white.opacity(model.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.42 : 0.94)
                            )
                        }
                }
                .buttonStyle(.plain)
                .disabled(model.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(LumaBarL10n.send)
            }
        }
        .onAppear {
            focusedField = model.agentShowsAPIKeySetup && !model.agentHasAPIKey ? .apiKey : .message
        }
        .onChange(of: model.agentFocusRequestID) { _, _ in
            focusedField = .message
        }
        .onExitCommand {
            model.dismissExpandedPanel()
        }
    }

    private func quickButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(theme.font(size: 9.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(theme.foreground(opacity: 0.78))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background { controlSurface(fill: theme.controlFill) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func controlSurface(fill: Color) -> some View {
        let shape = ThemeRectShape(radius: theme.controlCornerRadius, chamfer: 0)
        ZStack {
            shape.fill(fill)
            if theme.isForge {
                AdventureXGridOverlay()
                    .opacity(0.42)
                    .clipShape(shape)
                shape.strokeBorder(theme.pixelBorder.opacity(0.84), lineWidth: 1)
                shape
                    .inset(by: 2)
                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.7)
            }
        }
    }
}

/// Reactive expanded surface — opacity / hit-testing must observe `@Published` flags
/// so Space suppress and collapse cannot leave a permanently invisible panel.
struct ExpandedIslandSurface: View {
    @ObservedObject var model: MusicPlayerModel
    let size: NSSize

    var body: some View {
        Group {
            if model.taskCompletionNotice != nil {
                TaskCompletionOverlayView(model: model)
            } else if model.isCodexTokenAutoExpanded {
                CodexTokenOverlayView(model: model)
            } else {
                MusicExpandedView(model: model)
            }
        }
        .frame(width: size.width, height: size.height)
        // Hard-kill paint while collapsed / Space-settling — WindowServer may briefly restore the panel.
        .opacity(model.isExpanded && !model.suppressTransientIslandSurfaces ? 1 : 0)
        .allowsHitTesting(model.isExpanded && !model.suppressTransientIslandSurfaces)
        .clipped()
        .environment(\.islandTheme, model.theme)
        // Liquid Glass: don't force dark scheme — it milks the behind-window blur gray/white.
        .preferredColorScheme(model.theme == .aura ? nil : model.theme.preferredColorScheme)
    }
}

