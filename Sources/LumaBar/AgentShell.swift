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

struct AgentShellResult: Sendable {
    let exitCode: Int32
    let output: String
    let timedOut: Bool
}

#if LUMA_APP_STORE
enum AgentShellRunner {
    static func run(_ command: String) async throws -> AgentShellResult {
        let action = SafeAgentActions.parse(command: command)
        let result = await MainActor.run {
            SafeAgentActions.execute(action)
        }
        return AgentShellResult(
            exitCode: result.exitCode,
            output: result.output,
            timedOut: result.timedOut
        )
    }
}
#else
enum AgentShellRunner {
    private static let defaultTimeout: TimeInterval = 120

    static func run(_ command: String) async throws -> AgentShellResult {
        try await Task.detached(priority: .userInitiated) {
            let timeout = Self.configuredTimeout()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lumabar-agent-shell-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let handle = try FileHandle(forWritingTo: outputURL)
            let inputPipe = Pipe()
            inputPipe.fileHandleForWriting.closeFile()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", command]
            process.currentDirectoryURL = Self.workingDirectory()
            process.environment = Self.shellEnvironment()
            process.standardInput = inputPipe.fileHandleForReading
            process.standardOutput = handle
            process.standardError = handle
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let timedOut = process.isRunning
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
            try handle.close()

            let data = (try? Data(contentsOf: outputURL)) ?? Data()
            let limitedData = data.prefix(120_000)
            let output = String(data: limitedData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return AgentShellResult(
                exitCode: process.terminationStatus,
                output: output,
                timedOut: timedOut
            )
        }.value
    }

    private static func configuredTimeout() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        guard let rawValue = environment["LUMA_BAR_AGENT_SHELL_TIMEOUT"],
              let value = TimeInterval(rawValue),
              value > 0
        else {
            return defaultTimeout
        }
        return min(value, 600)
    }

    private static func workingDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let rawPath = environment["LUMA_BAR_AGENT_SHELL_CWD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty
        {
            let expandedPath = (rawPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func shellEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let userName = NSUserName()

        environment["HOME"] = homePath
        environment["USER"] = userName
        environment["LOGNAME"] = userName
        environment["SHELL"] = environment["SHELL"] ?? "/bin/zsh"
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["LC_CTYPE"] = environment["LC_CTYPE"] ?? "en_US.UTF-8"
        environment["LUMA_BAR_AGENT"] = "1"

        let existingPaths = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let defaultPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        var seenPaths = Set<String>()
        let mergedPaths = (existingPaths + defaultPaths).filter { path in
            guard !path.isEmpty, !seenPaths.contains(path) else { return false }
            seenPaths.insert(path)
            return true
        }
        environment["PATH"] = mergedPaths.joined(separator: ":")

        return environment
    }
}
#endif


