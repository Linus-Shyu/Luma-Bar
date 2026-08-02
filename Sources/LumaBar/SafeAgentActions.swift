import AppKit
import Foundation

/// Mac App Store–safe replacements for arbitrary shell execution.
enum SafeAgentActions {
    struct Result: Sendable {
        let exitCode: Int32
        let output: String
        let timedOut: Bool
    }

    enum Action: Equatable {
        case openURL(URL)
        case openApplication(name: String)
        case openBundleIdentifier(String)
        case copyToClipboard(String)
        case runShortcut(name: String)
        case unsupported(reason: String)
    }

    static func parse(command raw: String) -> Action {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = command.lowercased()

        if lower.hasPrefix("shortcut ") || lower.hasPrefix("shortcuts ") {
            let name = command
                .split(separator: " ", maxSplits: 1)
                .dropFirst()
                .joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !name.isEmpty else {
                return .unsupported(reason: "Provide a Shortcuts name: shortcut \"My Shortcut\"")
            }
            return .runShortcut(name: name)
        }

        if let url = extractURL(from: command) {
            return .openURL(url)
        }
        if let bundleID = extractOpenBundleID(from: command) {
            return .openBundleIdentifier(bundleID)
        }
        if let appName = extractOpenAppName(from: command) {
            return .openApplication(name: appName)
        }
        if lower.hasPrefix("pbcopy") || lower.hasPrefix("clipboard ") {
            let text = command
                .split(separator: " ", maxSplits: 1)
                .dropFirst()
                .joined(separator: " ")
            return .copyToClipboard(text)
        }

        return .unsupported(
            reason: """
            Mac App Store edition cannot run arbitrary shell commands.
            Supported: open -a AppName, open -b bundle.id, open https://…, shortcut "Name", clipboard text
            """
        )
    }

    @MainActor
    static func execute(_ action: Action) -> Result {
        switch action {
        case .openURL(let url):
            let ok = NSWorkspace.shared.open(url)
            return Result(
                exitCode: ok ? 0 : 1,
                output: ok ? "Opened \(url.absoluteString)" : "Failed to open URL",
                timedOut: false
            )
        case .openApplication(name: let name):
            let candidates = [
                URL(fileURLWithPath: "/Applications/\(name).app"),
                URL(fileURLWithPath: "/System/Applications/\(name).app"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/\(name).app"),
            ]
            if let appURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
                return Result(exitCode: 0, output: "Launched \(name)", timedOut: false)
            }
            return Result(exitCode: 1, output: "Could not launch \(name)", timedOut: false)
        case .openBundleIdentifier(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return Result(exitCode: 1, output: "No app for bundle id \(bundleID)", timedOut: false)
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return Result(exitCode: 0, output: "Launching \(bundleID)", timedOut: false)
        case .copyToClipboard(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return Result(exitCode: 0, output: "Copied to clipboard", timedOut: false)
        case .runShortcut(name: let name):
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            if let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)"),
               NSWorkspace.shared.open(url)
            {
                return Result(exitCode: 0, output: "Requested Shortcuts to run “\(name)”", timedOut: false)
            }
            return Result(exitCode: 1, output: "Could not open Shortcuts for “\(name)”", timedOut: false)
        case .unsupported(let reason):
            return Result(exitCode: 1, output: reason, timedOut: false)
        }
    }

    private static func extractURL(from command: String) -> URL? {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        for token in tokens {
            if (token.hasPrefix("http://") || token.hasPrefix("https://")),
               let url = URL(string: token)
            {
                return url
            }
        }
        if tokens.count >= 2, tokens[0] == "open",
           let url = URL(string: tokens[1]),
           url.scheme == "http" || url.scheme == "https"
        {
            return url
        }
        return nil
    }

    private static func extractOpenBundleID(from command: String) -> String? {
        let pattern = #"open\s+-b\s+([A-Za-z0-9.-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[range])
    }

    private static func extractOpenAppName(from command: String) -> String? {
        let quoted = #"open\s+-a\s+\"([^\"]+)\""#
        if let regex = try? NSRegularExpression(pattern: quoted),
           let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
           let range = Range(match.range(at: 1), in: command)
        {
            return String(command[range])
        }
        let plain = #"open\s+-a\s+([^\s]+)"#
        if let regex = try? NSRegularExpression(pattern: plain),
           let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
           let range = Range(match.range(at: 1), in: command)
        {
            return String(command[range])
        }
        return nil
    }
}
