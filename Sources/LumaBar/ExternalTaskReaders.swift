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

enum CodexSessionUsageReader {
    private static let tokenMarker = "\"type\":\"token_count\""
    private static let turnContextMarker = "\"type\":\"turn_context\""
    private static let initialTailSize = 512 * 1_024
    private static let maximumTailSize = 32 * 1_024 * 1_024

    static func latestSnapshot(previous: CodexTokenUsageSnapshot?) -> CodexTokenUsageSnapshot? {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey
        ]

        var latestFile: (url: URL, modifiedAt: Date)?
        for sessionsRoot in sessionRoots() {
            guard let enumerator = fileManager.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard
                    let values = try? url.resourceValues(forKeys: resourceKeys),
                    values.isRegularFile == true,
                    let modifiedAt = values.contentModificationDate
                else {
                    continue
                }

                if latestFile == nil || modifiedAt > latestFile!.modifiedAt {
                    latestFile = (url, modifiedAt)
                }
            }
        }

        guard let latestFile else { return nil }
        return snapshot(
            from: latestFile.url,
            modifiedAt: latestFile.modifiedAt,
            previous: previous
        )
    }

    static func taskStates() -> [ExternalTaskState] {
        openAITaskStates().filter { $0.source == .codex }
    }

    static func openAITaskStates() -> [ExternalTaskState] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]

        var files: [(url: URL, modifiedAt: Date)] = []
        for sessionsRoot in sessionRoots() {
            guard let enumerator = fileManager.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard
                    let values = try? url.resourceValues(forKeys: resourceKeys),
                    values.isRegularFile == true,
                    let modifiedAt = values.contentModificationDate
                else {
                    continue
                }
                files.append((url, modifiedAt))
            }
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(24)
            .compactMap { taskState(from: $0.url, modifiedAt: $0.modifiedAt) }
    }

    private static func sessionRoots() -> [URL] {
        #if LUMA_APP_STORE
        var roots: [URL] = []
        if let home = SecurityScopedBookmarks.retainedURL(for: .codexHome) {
            roots.append(home.appendingPathComponent("sessions", isDirectory: true))
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
        #else
        let fileManager = FileManager.default
        var roots: [URL] = []
        if let customHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !customHome.isEmpty
        {
            roots.append(
                URL(fileURLWithPath: customHome, isDirectory: true)
                    .appendingPathComponent("sessions", isDirectory: true)
            )
        }
        roots.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        )
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
        #endif
    }

    private static func taskState(from url: URL, modifiedAt: Date) -> ExternalTaskState? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let fileSize = try? handle.seekToEnd()
        else {
            return nil
        }
        defer { try? handle.close() }

        let headSize = min(UInt64(8 * 1_024), fileSize)
        let headData = (try? handle.read(upToCount: Int(headSize))) ?? Data()
        let headText = String(decoding: headData, as: UTF8.self)

        let readSize = min(UInt64(512 * 1_024), fileSize)
        try? handle.seek(toOffset: fileSize - readSize)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)

        // Codex writes `task_complete` for failed turns too (quota, auth, tool errors),
        // so decode the last lifecycle event instead of matching raw substrings.
        guard let event = lastLifecycleEvent(in: text) else { return nil }

        let isRunning = event.type == "task_started"
        let isComplete = event.type == "task_complete" && event.error == nil
        let meta = sessionMeta(from: headText)
        let source = classifiedOpenAISource(meta: meta)
        let project = projectName(from: meta, url: url)
        let brand = source.shortBrandName

        return ExternalTaskState(
            source: source,
            sessionID: url.path,
            title: ExternalTokenSource.noticeTitle(brand: brand, detail: project),
            isRunning: isRunning,
            isComplete: isComplete,
            updatedAt: modifiedAt
        )
    }

    private struct OpenAISessionMeta {
        let originator: String
        let source: String
        let cwd: String
    }

    private static func sessionMeta(from headText: String) -> OpenAISessionMeta {
        for line in headText.split(separator: "\n").prefix(12) {
            guard line.contains("\"session_meta\""),
                  let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? [String: Any]
            else {
                continue
            }
            return OpenAISessionMeta(
                originator: payload["originator"] as? String ?? "",
                source: payload["source"] as? String ?? "",
                cwd: payload["cwd"] as? String ?? ""
            )
        }
        return OpenAISessionMeta(originator: "", source: "", cwd: "")
    }

    private static func classifiedOpenAISource(meta: OpenAISessionMeta) -> ExternalTokenSource {
        let originator = meta.originator.lowercased()
        let source = meta.source.lowercased()
        // Official ChatGPT macOS app is bundle com.openai.codex; treat Desktop-originated
        // sessions as ChatGPT so reminders match the app the user actually sees.
        if originator.contains("chatgpt")
            || originator.contains("desktop")
            || source == "chatgpt"
        {
            return .chatgpt
        }
        return .codex
    }

    private static func projectName(from meta: OpenAISessionMeta, url: URL) -> String {
        let cwd = meta.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name != "/" {
                return name
            }
        }
        let stem = url.deletingPathExtension().lastPathComponent
        if let range = stem.range(of: #"\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) {
            let prefix = String(stem[..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            if !prefix.isEmpty, prefix.lowercased() != "rollout" {
                return prefix
            }
        }
        return "会话"
    }

    private struct CodexLifecyclePayload: Decodable {
        let type: String
        let error: CodexLifecycleError?
    }

    private struct CodexLifecycleError: Decodable {
        let message: String?
    }

    private struct CodexLifecycleEvent: Decodable {
        let payload: CodexLifecyclePayload
    }

    private static func lastLifecycleEvent(in text: String) -> CodexLifecyclePayload? {
        let lifecycleTypes: Set<String> = ["task_started", "task_complete", "turn_aborted"]
        let decoder = JSONDecoder()

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"task_started\"")
                    || line.contains("\"task_complete\"")
                    || line.contains("\"turn_aborted\"")
            else {
                continue
            }
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(CodexLifecycleEvent.self, from: data),
                  lifecycleTypes.contains(event.payload.type)
            else {
                continue
            }
            return event.payload
        }

        return nil
    }

    private static func snapshot(
        from url: URL,
        modifiedAt: Date,
        previous: CodexTokenUsageSnapshot?
    ) -> CodexTokenUsageSnapshot? {
        guard
            let fileHandle = try? FileHandle(forReadingFrom: url),
            let fileSize = try? fileHandle.seekToEnd()
        else {
            return nil
        }
        defer { try? fileHandle.close() }

        var requestedSize = min(UInt64(initialTailSize), fileSize)
        var tailText = ""
        var tokenLine: Substring?
        var modelLine: Substring?
        let cachedModel = previous?.sessionURL == url ? previous?.model : nil

        while requestedSize > 0 {
            do {
                try fileHandle.seek(toOffset: fileSize - requestedSize)
                let data = try fileHandle.read(upToCount: Int(requestedSize)) ?? Data()
                tailText = String(decoding: data, as: UTF8.self)
                tokenLine = latestLine(containing: tokenMarker, in: tailText)
                modelLine = latestLine(containing: turnContextMarker, in: tailText)
            } catch {
                return nil
            }

            let hasModel = modelLine != nil || cachedModel != nil
            if
                (tokenLine != nil && hasModel)
                    || requestedSize == fileSize
                    || requestedSize >= maximumTailSize
            {
                break
            }
            requestedSize = min(fileSize, requestedSize * 2)
        }

        guard
            let tokenLine,
            let tokenData = String(tokenLine).data(using: .utf8),
            let tokenEvent = try? JSONDecoder().decode(CodexRolloutEvent.self, from: tokenData),
            let info = tokenEvent.payload.info,
            let usage = info.lastTokenUsage ?? info.totalTokenUsage
        else {
            return nil
        }

        let model: String?
        if
            let modelLine,
            let modelData = String(modelLine).data(using: .utf8),
            let modelEvent = try? JSONDecoder().decode(CodexRolloutEvent.self, from: modelData)
        {
            model = modelEvent.payload.model
        } else {
            model = cachedModel
        }

        return CodexTokenUsageSnapshot(
            source: .codex,
            usage: AgentTokenUsage(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                totalTokens: usage.totalTokens
            ),
            contextWindow: max(1_000, info.modelContextWindow),
            model: model,
            sessionURL: url,
            updatedAt: modifiedAt,
            weeklyQuota: weeklyQuota(
                from: tokenEvent.payload.rateLimits,
                previous: previous
            )
        )
    }

    private final class WeeklyScanState: @unchecked Sendable {
        let lock = NSLock()
        var didExhaust = false
    }

    private static let weeklyScanState = WeeklyScanState()

    private static func weeklyQuota(
        from rateLimits: CodexRolloutEvent.RateLimits?,
        previous: CodexTokenUsageSnapshot?
    ) -> CodexWeeklyQuota? {
        if let quota = weeklyQuota(from: rateLimits) {
            weeklyScanState.lock.lock()
            weeklyScanState.didExhaust = false
            weeklyScanState.lock.unlock()
            persistWeeklyQuotaCache(quota)
            return quota
        }
        if let cached = previous?.weeklyQuota ?? loadWeeklyQuotaCache() {
            return cached
        }
        // Avoid re-scanning dozens of rollouts every poll when none contain rate_limits.
        weeklyScanState.lock.lock()
        let alreadyScanned = weeklyScanState.didExhaust
        weeklyScanState.lock.unlock()
        guard !alreadyScanned else { return nil }
        if let scanned = latestWeeklyQuotaAcrossSessions() {
            weeklyScanState.lock.lock()
            weeklyScanState.didExhaust = false
            weeklyScanState.lock.unlock()
            return scanned
        }
        weeklyScanState.lock.lock()
        weeklyScanState.didExhaust = true
        weeklyScanState.lock.unlock()
        return nil
    }

    private static func weeklyQuota(
        from rateLimits: CodexRolloutEvent.RateLimits?
    ) -> CodexWeeklyQuota? {
        guard let rateLimits else { return nil }
        // Prefer secondary (~weekly). Fall back to primary if that's all we have.
        let window = rateLimits.secondary ?? rateLimits.primary
        guard let window, let used = window.usedPercent else { return nil }

        let resetDate: Date?
        if let resetsAt = window.resetsAt {
            resetDate = Date(timeIntervalSince1970: resetsAt)
        } else if let resetsIn = window.resetsInSeconds {
            resetDate = Date().addingTimeInterval(resetsIn)
        } else {
            resetDate = nil
        }

        return CodexWeeklyQuota(
            usedPercent: min(100, max(0, used)),
            resetDate: resetDate,
            planType: rateLimits.planType,
            windowMinutes: window.windowMinutes
        )
    }

    private static func latestWeeklyQuotaAcrossSessions() -> CodexWeeklyQuota? {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        var files: [(url: URL, modifiedAt: Date)] = []
        for sessionsRoot in sessionRoots() {
            guard let enumerator = fileManager.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard
                    let values = try? url.resourceValues(forKeys: resourceKeys),
                    values.isRegularFile == true,
                    let modifiedAt = values.contentModificationDate
                else {
                    continue
                }
                files.append((url, modifiedAt))
            }
        }

        for file in files.sorted(by: { $0.modifiedAt > $1.modifiedAt }).prefix(24) {
            if let quota = weeklyQuota(inTailOf: file.url) {
                persistWeeklyQuotaCache(quota)
                return quota
            }
        }
        return nil
    }

    private static func weeklyQuota(inTailOf url: URL) -> CodexWeeklyQuota? {
        guard
            let fileHandle = try? FileHandle(forReadingFrom: url),
            let fileSize = try? fileHandle.seekToEnd()
        else {
            return nil
        }
        defer { try? fileHandle.close() }

        let requestedSize = min(UInt64(initialTailSize), fileSize)
        do {
            try fileHandle.seek(toOffset: fileSize - requestedSize)
            let data = try fileHandle.read(upToCount: Int(requestedSize)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            // Walk newest → oldest token_count lines looking for non-null secondary/primary.
            var search = text.endIndex
            while search > text.startIndex {
                guard let markerRange = text[..<search].range(of: tokenMarker, options: .backwards) else {
                    break
                }
                let lineStart = text[..<markerRange.lowerBound].lastIndex(of: "\n")
                    .map { text.index(after: $0) } ?? text.startIndex
                let lineEnd = text[markerRange.upperBound...].firstIndex(of: "\n") ?? text.endIndex
                let line = text[lineStart..<lineEnd]
                search = markerRange.lowerBound
                guard
                    let lineData = String(line).data(using: .utf8),
                    let event = try? JSONDecoder().decode(CodexRolloutEvent.self, from: lineData),
                    let quota = weeklyQuota(from: event.payload.rateLimits)
                else {
                    continue
                }
                return quota
            }
        } catch {
            return nil
        }
        return nil
    }

    private static var weeklyQuotaCacheURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("LumaBar", isDirectory: true)
            .appendingPathComponent("codex-weekly-quota.json")
    }

    private static func persistWeeklyQuotaCache(_ quota: CodexWeeklyQuota) {
        let directory = weeklyQuotaCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "usedPercent": quota.usedPercent,
            "resetAt": quota.resetDate?.timeIntervalSince1970 as Any,
            "planType": quota.planType as Any,
            "windowMinutes": quota.windowMinutes as Any,
            "cachedAt": Date().timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: weeklyQuotaCacheURL, options: [.atomic])
    }

    private static func loadWeeklyQuotaCache() -> CodexWeeklyQuota? {
        guard
            let data = try? Data(contentsOf: weeklyQuotaCacheURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let used = json["usedPercent"] as? Double
        else {
            return nil
        }
        // Drop cache older than 36h — weekly numbers move.
        if let cachedAt = json["cachedAt"] as? Double,
           Date().timeIntervalSince1970 - cachedAt > 36 * 3600
        {
            return nil
        }
        let resetDate = (json["resetAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return CodexWeeklyQuota(
            usedPercent: used,
            resetDate: resetDate,
            planType: json["planType"] as? String,
            windowMinutes: json["windowMinutes"] as? Int
        )
    }

    private static func latestLine(containing marker: String, in text: String) -> Substring? {
        guard let markerRange = text.range(of: marker, options: .backwards) else { return nil }
        let lineStart = text[..<markerRange.lowerBound].lastIndex(of: "\n")
            .map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[markerRange.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        return text[lineStart..<lineEnd]
    }
}

enum CursorSessionUsageReader {
    private static let defaultContextWindow = 200_000
    /// Security-scoped access must stay open for the life of the process.
    /// Ending it when the URL is returned makes later SQLite reads fail in the sandbox.
    private nonisolated(unsafe) static var keptSupportAccess = false
    private nonisolated(unsafe) static var keptProjectsAccess = false

    static func latestSnapshot(previous: CodexTokenUsageSnapshot?) -> CodexTokenUsageSnapshot? {
        for databaseURL in databaseURLs() {
            if let snapshot = latestSnapshot(in: databaseURL, previous: previous) {
                return snapshot
            }
        }
        return nil
    }

    static func taskStates() -> [ExternalTaskState] {
        var statesByID: [String: ExternalTaskState] = [:]
        for databaseURL in databaseURLs() {
            for state in transcriptTaskStates(in: databaseURL) {
                statesByID[state.sessionID] = state
            }

            guard FileManager.default.fileExists(atPath: databaseURL.path),
                  let headersJSON = queryText(
                    databaseURL: databaseURL,
                    sql: "SELECT value FROM ItemTable WHERE key = 'composer.composerHeaders' LIMIT 1;"
                  ),
                  let headersData = headersJSON.data(using: .utf8),
                  let headers = try? JSONDecoder().decode(CursorComposerHeaders.self, from: headersData)
            else {
                continue
            }

            let candidates = headers.allComposers.sorted(by: {
                ($0.lastUpdatedAt ?? 0) > ($1.lastUpdatedAt ?? 0)
            })

            for header in candidates.prefix(24) {
                let key = "composerData:\(header.composerId)".replacingOccurrences(of: "'", with: "''")
                guard let json = queryText(
                    databaseURL: databaseURL,
                    sql: "SELECT value FROM cursorDiskKV WHERE key = '\(key)' LIMIT 1;"
                ),
                      let data = json.data(using: .utf8),
                      let composer = try? JSONDecoder().decode(CursorComposerData.self, from: data)
                else {
                    continue
                }

                let status = composer.status?.lowercased() ?? ""
                let isRunning = composer.generatingBubbleIds?.isEmpty == false
                    || ["generating", "running", "pending", "in_progress"].contains(status)
                let isComplete = status == "completed"
                guard isRunning || isComplete || status == "aborted" else { continue }

                let trimmedTitle = header.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let composerName = composer.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail: String = {
                    if let trimmedTitle, !trimmedTitle.isEmpty { return trimmedTitle }
                    if let composerName, !composerName.isEmpty { return composerName }
                    return "任务"
                }()
                let state = ExternalTaskState(
                    source: .cursor,
                    sessionID: header.composerId,
                    title: ExternalTokenSource.noticeTitle(brand: "Cursor", detail: detail),
                    isRunning: isRunning,
                    isComplete: isComplete,
                    updatedAt: Date(
                        timeIntervalSince1970: (composer.lastUpdatedAt ?? header.lastUpdatedAt ?? 0) / 1000
                    )
                )
                // Transcript state for the same composer already won; never queue it twice.
                guard statesByID[state.sessionID] == nil else { continue }
                statesByID[state.sessionID] = state
            }
        }
        return statesByID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func transcriptTaskStates(in databaseURL: URL) -> [ExternalTaskState] {
        let projectsRoot: URL
#if LUMA_APP_STORE
        guard let root = SecurityScopedBookmarks.resolvedURL(for: .cursorProjects) else { return [] }
        if !keptProjectsAccess {
            keptProjectsAccess = root.startAccessingSecurityScopedResource()
        }
        guard keptProjectsAccess else { return [] }
        projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
#else
        projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/projects", isDirectory: true)
#endif
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var transcripts: [(url: URL, modifiedAt: Date, agentID: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let agentID = url.deletingPathExtension().lastPathComponent
            guard url.deletingLastPathComponent().lastPathComponent == agentID else { continue }
            guard
                let values = try? url.resourceValues(forKeys: resourceKeys),
                values.isRegularFile == true,
                let modifiedAt = values.contentModificationDate
            else {
                continue
            }
            transcripts.append((url, modifiedAt, agentID))
        }

        return transcripts
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(24)
            .compactMap {
                transcriptTaskState(
                    url: $0.url,
                    modifiedAt: $0.modifiedAt,
                    agentID: $0.agentID,
                    databaseURL: databaseURL
                )
            }
    }

    private static func transcriptTaskState(
        url: URL,
        modifiedAt: Date,
        agentID: String,
        databaseURL: URL
    ) -> ExternalTaskState? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let fileSize = try? handle.seekToEnd()
        else {
            return nil
        }
        defer { try? handle.close() }
        let readSize = min(UInt64(128 * 1_024), fileSize)
        try? handle.seek(toOffset: fileSize - readSize)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        guard let event = text.split(separator: "\n").reversed().compactMap({ line -> CursorTranscriptEvent? in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(CursorTranscriptEvent.self, from: data)
        }).first else {
            return nil
        }

        let isTurnEnded = event.type == "turn_ended"
        let detail = selectedComposerName(agentID: agentID, in: databaseURL)
            ?? projectName(fromTranscriptURL: url)
            ?? "任务"
        // Use the composer/agent ID as the canonical identity so transcript and
        // composer-derived states for the same task never notify twice.
        return ExternalTaskState(
            source: .cursor,
            sessionID: agentID,
            title: ExternalTokenSource.noticeTitle(brand: "Cursor", detail: detail),
            isRunning: !isTurnEnded,
            isComplete: isTurnEnded && event.status == "success",
            updatedAt: modifiedAt
        )
    }

    private static func projectName(fromTranscriptURL url: URL) -> String? {
        // ~/.cursor/projects/<encoded-path>/<agentID>/<agentID>.jsonl
        let projectsRootName = "projects"
        let parts = url.pathComponents
        guard let projectsIndex = parts.lastIndex(of: projectsRootName),
              projectsIndex + 1 < parts.count
        else {
            return nil
        }
        let encoded = parts[projectsIndex + 1]
        let decoded = encoded
            .replacingOccurrences(of: "%2F", with: "/")
            .replacingOccurrences(of: "%3A", with: ":")
        let name = URL(fileURLWithPath: decoded).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func selectedComposerName(agentID: String, in databaseURL: URL) -> String? {
        let escapedID = agentID.replacingOccurrences(of: "'", with: "''")
        guard let json = queryText(
            databaseURL: databaseURL,
            sql: "SELECT value FROM cursorDiskKV WHERE key = 'composerData:\(escapedID)' LIMIT 1;"
        ),
              let data = json.data(using: .utf8),
              let composer = try? JSONDecoder().decode(CursorComposerData.self, from: data),
              let name = composer.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else {
            return nil
        }
        return name
    }

    private static func databaseURLs() -> [URL] {
        #if LUMA_APP_STORE
        guard let support = SecurityScopedBookmarks.resolvedURL(for: .cursorApplicationSupport) else {
            return []
        }
        if !keptSupportAccess {
            keptSupportAccess = support.startAccessingSecurityScopedResource()
        }
        guard keptSupportAccess else { return [] }
        return [
            support.appendingPathComponent("User/globalStorage/state.vscdb")
        ]
        #else
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let applicationSupportNames = [
            "Cursor",
            "Cursor - Insiders",
            "Cursor Beta",
            "Cursor Nightly"
        ]
        return applicationSupportNames.map {
            support
                .appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("User/globalStorage/state.vscdb")
        }
        #endif
    }

    private static func latestSnapshot(
        in databaseURL: URL,
        previous: CodexTokenUsageSnapshot?
    ) -> CodexTokenUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var candidates = headerComposers(in: databaseURL)
        guard !candidates.isEmpty else { return nil }
        if let selectedAgentID = selectedAgentID(in: databaseURL),
           !candidates.contains(where: { $0.composerId == selectedAgentID }) {
            candidates.insert(
                CursorComposerHeaders.Composer(
                    composerId: selectedAgentID,
                    name: nil,
                    lastUpdatedAt: .greatestFiniteMagnitude,
                    contextUsagePercent: nil
                ),
                at: 0
            )
        } else if let selectedAgentID = selectedAgentID(in: databaseURL),
                  let selectedIndex = candidates.firstIndex(where: { $0.composerId == selectedAgentID }) {
            candidates.insert(candidates.remove(at: selectedIndex), at: 0)
        }

        for header in candidates.prefix(12) {
            if let percent = header.contextUsagePercent {
                let contextWindow = max(
                    1_000,
                    previousContextWindow(previous, composerId: header.composerId) ?? defaultContextWindow
                )
                let totalTokens = max(0, Int((percent / 100.0 * Double(contextWindow)).rounded()))
                let trimmedName = header.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return CodexTokenUsageSnapshot(
                    source: .cursor,
                    usage: AgentTokenUsage(
                        inputTokens: totalTokens,
                        outputTokens: 0,
                        totalTokens: totalTokens
                    ),
                    contextWindow: contextWindow,
                    model: trimmedName.isEmpty ? "Composer" : trimmedName,
                    sessionURL: databaseURL.appendingPathComponent(header.composerId),
                    updatedAt: Date(timeIntervalSince1970: (header.lastUpdatedAt ?? 0) / 1000)
                )
            }

            let composerKey = "composerData:\(header.composerId)"
            let escapedKey = composerKey.replacingOccurrences(of: "'", with: "''")
            let composerJSON = queryText(
                databaseURL: databaseURL,
                sql: "SELECT value FROM cursorDiskKV WHERE key = '\(escapedKey)' LIMIT 1;"
            )

            let breakdown: CursorComposerData.PromptTokenBreakdown?
            let modelName: String?
            let dataPercent: Double?
            let composerUpdatedAt: Double?
            if
                let composerJSON,
                let composerData = composerJSON.data(using: .utf8),
                let composer = try? JSONDecoder().decode(CursorComposerData.self, from: composerData)
            {
                breakdown = composer.promptTokenBreakdown
                modelName = composer.modelConfig?.modelName
                dataPercent = composer.contextUsagePercent
                composerUpdatedAt = composer.lastUpdatedAt
            } else {
                breakdown = nil
                modelName = previous?.sessionURL.path.contains(header.composerId) == true
                    ? previous?.model
                    : nil
                dataPercent = nil
                composerUpdatedAt = nil
            }

            let contextWindow = max(
                1_000,
                breakdown?.maxTokens ?? previousContextWindow(previous, composerId: header.composerId) ?? defaultContextWindow
            )
            let totalTokens: Int
            if let used = breakdown?.totalUsedTokens {
                totalTokens = max(0, used)
            } else if let percent = dataPercent ?? header.contextUsagePercent {
                totalTokens = max(0, Int((percent / 100.0 * Double(contextWindow)).rounded()))
            } else {
                continue
            }

            let updatedAt = Date(
                timeIntervalSince1970: (composerUpdatedAt ?? header.lastUpdatedAt ?? 0) / 1000.0
            )
            let sessionURL = databaseURL
                .appendingPathComponent(header.composerId, isDirectory: false)
            let normalizedModel: String?
            if let modelName {
                let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                normalizedModel = trimmed.isEmpty || trimmed.lowercased() == "default"
                    ? "Composer"
                    : trimmed
            } else {
                normalizedModel = "Composer"
            }

            return CodexTokenUsageSnapshot(
                source: .cursor,
                usage: AgentTokenUsage(
                    inputTokens: totalTokens,
                    outputTokens: 0,
                    totalTokens: totalTokens
                ),
                contextWindow: contextWindow,
                model: normalizedModel,
                sessionURL: sessionURL,
                updatedAt: updatedAt
            )
        }

        return nil
    }

    private static func headerComposers(in databaseURL: URL) -> [CursorComposerHeaders.Composer] {
        let rows = queryTexts(
            databaseURL: databaseURL,
            sql: """
            SELECT value FROM composerHeaders
            WHERE IFNULL(isSubagent, 0) = 0 AND IFNULL(isArchived, 0) = 0
            ORDER BY lastUpdatedAt DESC
            LIMIT 16
            """
        )
        let decoded = rows.compactMap { json -> CursorComposerHeaders.Composer? in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(CursorComposerHeaders.Composer.self, from: data)
        }
        if !decoded.isEmpty {
            return decoded
        }

        guard let headersJSON = queryText(
            databaseURL: databaseURL,
            sql: "SELECT value FROM ItemTable WHERE key = 'composer.composerHeaders' LIMIT 1;"
        ),
              let headersData = headersJSON.data(using: .utf8),
              let headers = try? JSONDecoder().decode(CursorComposerHeaders.self, from: headersData)
        else {
            return []
        }
        return headers.allComposers
            .filter { ($0.lastUpdatedAt ?? 0) > 0 }
            .sorted { ($0.lastUpdatedAt ?? 0) > ($1.lastUpdatedAt ?? 0) }
    }

    private static func previousContextWindow(
        _ previous: CodexTokenUsageSnapshot?,
        composerId: String
    ) -> Int? {
        guard let previous, previous.source == .cursor,
              previous.sessionURL.lastPathComponent == composerId
        else {
            return nil
        }
        return previous.contextWindow
    }

    private static func selectedAgentID(in databaseURL: URL) -> String? {
        queryText(
            databaseURL: databaseURL,
            sql: "SELECT value FROM ItemTable WHERE key = 'cursor/glass.selectedAgent' LIMIT 1;"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func queryText(databaseURL: URL, sql: String) -> String? {
        queryTexts(databaseURL: databaseURL, sql: sql).first
    }

    private static func queryTexts(databaseURL: URL, sql: String) -> [String] {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if database != nil {
                sqlite3_close(database)
            }
            return []
        }
        sqlite3_busy_timeout(database, 800)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            rows.append(String(cString: cString))
            if rows.count >= 24 { break }
        }
        return rows
    }
}

enum KiroSessionUsageReader {
    private static let syntheticContextWindow = 100_000

    static func latestSnapshot(previous: CodexTokenUsageSnapshot?) -> CodexTokenUsageSnapshot? {
        let sessions = sessionDirectories()
            .compactMap { directory -> (url: URL, modifiedAt: Date, session: KiroSessionFile)? in
                let sessionURL = directory.appendingPathComponent("session.json")
                let messagesURL = directory.appendingPathComponent("messages.jsonl")
                guard
                    let values = try? messagesURL.resourceValues(forKeys: [.contentModificationDateKey]),
                    let modifiedAt = values.contentModificationDate,
                    let session = readSession(at: sessionURL)
                else {
                    return nil
                }
                return (messagesURL, modifiedAt, session)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }

        guard let latest = sessions.first else {
            guard let credits = latestCredits() else { return nil }
            let sessionURL: URL
#if LUMA_APP_STORE
            sessionURL = databaseURLs().first
                ?? SecurityScopedBookmarks.resolvedURL(for: .kiroHome)
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("kiro-unavailable")
#else
            sessionURL = databaseURLs().first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro")
#endif
            if let previous,
               previous.source == .kiro,
               previous.kiroCredits == credits,
               previous.usage.totalTokens == 0
            {
                return previous
            }
            return CodexTokenUsageSnapshot(
                source: .kiro,
                usage: AgentTokenUsage(),
                contextWindow: syntheticContextWindow,
                model: "Kiro",
                sessionURL: sessionURL,
                updatedAt: Date(),
                kiroCredits: credits
            )
        }
        let percentage = latestContextUsagePercentage(in: latest.url) ?? 0
        let totalTokens = max(
            0,
            min(
                syntheticContextWindow,
                Int((percentage / 100.0 * Double(syntheticContextWindow)).rounded())
            )
        )
        let usage = AgentTokenUsage(
            inputTokens: totalTokens,
            outputTokens: 0,
            totalTokens: totalTokens
        )
        let credits = latestCredits()
        if let previous,
           previous.source == .kiro,
           previous.sessionURL == latest.url,
           previous.usage == usage,
           previous.model == latest.session.modelId,
           previous.kiroCredits == credits
        {
            return previous
        }
        return CodexTokenUsageSnapshot(
            source: .kiro,
            usage: usage,
            contextWindow: syntheticContextWindow,
            model: latest.session.modelId,
            sessionURL: latest.url,
            updatedAt: latest.modifiedAt,
            kiroCredits: credits
        )
    }

    static func latestCredits() -> KiroCreditsUsage? {
        for databaseURL in databaseURLs() {
            guard FileManager.default.fileExists(atPath: databaseURL.path),
                  let json = queryText(
                    databaseURL: databaseURL,
                    sql: "SELECT value FROM ItemTable WHERE key = 'kiro.kiroAgent' LIMIT 1;"
                  ),
                  let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usageState = root["kiro.resourceNotifications.usageState"] as? [String: Any],
                  let breakdowns = usageState["usageBreakdowns"] as? [[String: Any]]
            else {
                continue
            }

            guard let credit = breakdowns.first(where: {
                (($0["type"] as? String) ?? "").uppercased() == "CREDIT"
            }) else {
                continue
            }

            let used = doubleValue(credit["currentUsage"]) ?? 0
            let limit = doubleValue(credit["usageLimit"]) ?? 0
            let percentage = doubleValue(credit["percentageUsed"]) ?? 0
            let displayName = (credit["displayNamePlural"] as? String)
                ?? (credit["displayName"] as? String)
                ?? "Credits"
            let unit = (credit["unit"] as? String) ?? "INVOCATIONS"
            let resetDate: Date?
            if let resetString = credit["resetDate"] as? String {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let basic = ISO8601DateFormatter()
                basic.formatOptions = [.withInternetDateTime]
                resetDate = fractional.date(from: resetString) ?? basic.date(from: resetString)
            } else {
                resetDate = nil
            }

            return KiroCreditsUsage(
                used: used,
                limit: max(limit, 0),
                percentageUsed: percentage,
                resetDate: resetDate,
                displayName: displayName,
                unit: unit
            )
        }
        return nil
    }

    private static func databaseURLs() -> [URL] {
#if LUMA_APP_STORE
        guard let root = SecurityScopedBookmarks.retainedURL(for: .kiroApplicationSupport) else {
            return []
        }
        let url = root.appendingPathComponent("User/globalStorage/state.vscdb")
        return FileManager.default.fileExists(atPath: url.path) ? [url] : []
#else
        let supportRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return ["Kiro"].compactMap { name in
            let url = supportRoot
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("User/globalStorage/state.vscdb")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
#endif
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private static func queryText(databaseURL: URL, sql: String) -> String? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            if database != nil {
                sqlite3_close(database)
            }
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: cString)
    }

    static func taskStates() -> [ExternalTaskState] {
        sessionDirectories().compactMap { directory in
            let sessionURL = directory.appendingPathComponent("session.json")
            let messagesURL = directory.appendingPathComponent("messages.jsonl")
            guard
                let session = readSession(at: sessionURL),
                let values = try? messagesURL.resourceValues(forKeys: [.contentModificationDateKey]),
                let modifiedAt = values.contentModificationDate
            else {
                return nil
            }

            let lifecycle = latestLifecycle(in: messagesURL)
            let isRunning = lifecycle.isRunning
                || session.status?.lowercased() == "in_progress"
            let isComplete = lifecycle.isComplete
            guard isRunning || isComplete else { return nil }

            let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (title?.isEmpty == false) ? title! : "任务"
            return ExternalTaskState(
                source: .kiro,
                sessionID: session.id ?? directory.lastPathComponent,
                title: ExternalTokenSource.noticeTitle(brand: "Kiro", detail: detail),
                isRunning: isRunning,
                isComplete: isComplete,
                updatedAt: modifiedAt
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func sessionDirectories() -> [URL] {
#if LUMA_APP_STORE
        guard let home = SecurityScopedBookmarks.retainedURL(for: .kiroHome) else {
            return []
        }
        let root = home.appendingPathComponent("sessions", isDirectory: true)
#else
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kiro/sessions", isDirectory: true)
#endif
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("sess_"),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  FileManager.default.fileExists(
                    atPath: url.appendingPathComponent("messages.jsonl").path
                  )
            else {
                continue
            }
            directories.append(url)
        }
        return directories
    }

    private static func readSession(at url: URL) -> KiroSessionFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KiroSessionFile.self, from: data)
    }

    private static func latestContextUsagePercentage(in messagesURL: URL) -> Double? {
        guard let text = tailText(of: messagesURL) else { return nil }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(KiroMessageEnvelope.self, from: data),
                  event.payload.type == "session_metadata",
                  event.payload.key == "contextUsage"
            else {
                continue
            }
            return event.payload.value?.usagePercentage
        }
        return nil
    }

    private static func latestLifecycle(in messagesURL: URL) -> (isRunning: Bool, isComplete: Bool) {
        guard let text = tailText(of: messagesURL) else {
            return (false, false)
        }
        let decoder = JSONDecoder()
        var sawTurnStart = false
        for line in text.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(KiroMessageEnvelope.self, from: data)
            else {
                continue
            }
            switch event.payload.type {
            case "turn_start":
                return (true, false)
            case "usage_summary":
                if event.payload.status?.lowercased() == "success" {
                    return (false, true)
                }
                return (false, false)
            case "session_event":
                if event.payload.category == "session_pause",
                   event.payload.context?.status?.lowercased() == "success"
                {
                    return (false, true)
                }
                if event.payload.category == "session_pause" {
                    return (false, false)
                }
            default:
                if event.payload.type == "assistant" || event.payload.type == "user" {
                    sawTurnStart = false
                }
                continue
            }
            _ = sawTurnStart
        }
        return (false, false)
    }

    private static func tailText(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let fileSize = try? handle.seekToEnd()
        else {
            return nil
        }
        defer { try? handle.close() }
        let readSize = min(UInt64(512 * 1_024), fileSize)
        try? handle.seek(toOffset: fileSize - readSize)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}

/// Official ChatGPT macOS app shares `com.openai.codex` / `~/.codex/sessions` with Codex Desktop.
/// Sessions classified as desktop/chat are exposed here so reminders say "ChatGPT · …".
enum ChatGPTSessionUsageReader {
    static func taskStates() -> [ExternalTaskState] {
        CodexSessionUsageReader.openAITaskStates().filter { $0.source == .chatgpt }
    }
}

/// Cherry Studio stores agent sessions in `Data/agents.db`, and newer chat topics in `cherrystudio.sqlite`.
enum CherryStudioSessionUsageReader {
    static func taskStates() -> [ExternalTaskState] {
#if LUMA_APP_STORE
        guard let root = SecurityScopedBookmarks.retainedURL(for: .cherryStudioSupport) else {
            return []
        }
        return collectTaskStates(supportRoot: root)
#else
        return collectTaskStates(supportRoot: defaultSupportRoot())
#endif
    }

    private static func collectTaskStates(supportRoot: URL) -> [ExternalTaskState] {
        var statesByID: [String: ExternalTaskState] = [:]
        for state in chatTopicTaskStates(supportRoot: supportRoot) {
            statesByID[state.sessionID] = state
        }
        for state in agentSessionTaskStates(supportRoot: supportRoot) {
            statesByID[state.sessionID] = state
        }
        return statesByID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func defaultSupportRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CherryStudio", isDirectory: true)
    }

    private static func chatTopicTaskStates(supportRoot: URL) -> [ExternalTaskState] {
        let dbURL = supportRoot.appendingPathComponent("cherrystudio.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        let sql = """
        SELECT t.id,
               COALESCE(NULLIF(t.name, ''), '话题'),
               COALESCE(t.updated_at, 0),
               (
                 SELECT COUNT(*) FROM message m
                 WHERE m.topicId = t.id
                   AND m.role = 'assistant'
                   AND lower(m.status) = 'pending'
               ) AS pending_count,
               (
                 SELECT lower(m.status) FROM message m
                 WHERE m.topicId = t.id AND m.role = 'assistant'
                 ORDER BY m.created_at DESC
                 LIMIT 1
               ) AS last_status
        FROM topic t
        ORDER BY COALESCE(t.updated_at, 0) DESC
        LIMIT 24;
        """

        return queryRows(databaseURL: dbURL, sql: sql).compactMap { row in
            guard row.count >= 5 else { return nil }
            let topicID = row[0]
            let name = row[1]
            let updatedRaw = Double(row[2]) ?? 0
            let pendingCount = Int(row[3]) ?? 0
            let lastStatus = row[4]
            let isRunning = pendingCount > 0 || lastStatus == "pending"
            let isComplete = !isRunning && lastStatus == "success"
            guard isRunning || isComplete else { return nil }
            let updatedAt: Date = {
                if updatedRaw > 1_000_000_000_000 {
                    return Date(timeIntervalSince1970: updatedRaw / 1000)
                }
                if updatedRaw > 0 {
                    return Date(timeIntervalSince1970: updatedRaw)
                }
                return Date()
            }()
            return ExternalTaskState(
                source: .cherryStudio,
                sessionID: "cherry-topic:\(topicID)",
                title: ExternalTokenSource.noticeTitle(brand: "Cherry Studio", detail: name),
                isRunning: isRunning,
                isComplete: isComplete,
                updatedAt: updatedAt
            )
        }
    }

    private static func agentSessionTaskStates(supportRoot: URL) -> [ExternalTaskState] {
        let dbURL = supportRoot.appendingPathComponent("Data/agents.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        let sql = """
        SELECT s.id,
               COALESCE(NULLIF(s.name, ''), 'Agent'),
               s.updated_at,
               (
                 SELECT m.role FROM session_messages m
                 WHERE m.session_id = s.id
                 ORDER BY m.id DESC
                 LIMIT 1
               ) AS last_role,
               (
                 SELECT m.metadata FROM session_messages m
                 WHERE m.session_id = s.id
                 ORDER BY m.id DESC
                 LIMIT 1
               ) AS last_metadata,
               (
                 SELECT COUNT(*) FROM session_messages m
                 WHERE m.session_id = s.id
               ) AS message_count
        FROM sessions s
        ORDER BY s.updated_at DESC
        LIMIT 24;
        """

        return queryRows(databaseURL: dbURL, sql: sql).compactMap { row in
            guard row.count >= 6 else { return nil }
            let sessionID = row[0]
            let name = row[1]
            let updatedAt = parseFlexibleDate(row[2]) ?? Date()
            let lastRole = row[3].lowercased()
            let metadata = row[4]
            let messageCount = Int(row[5]) ?? 0
            guard messageCount > 0 else { return nil }

            let metadataStatus = metadataStatus(from: metadata)
            let isRunning = lastRole == "user"
                || metadataStatus == "pending"
                || metadataStatus == "streaming"
                || metadataStatus == "running"
                || metadataStatus == "in_progress"
            let isComplete = !isRunning
                && lastRole == "assistant"
                && (metadataStatus.isEmpty
                    || metadataStatus == "success"
                    || metadataStatus == "completed"
                    || metadataStatus == "done")
            guard isRunning || isComplete else { return nil }

            return ExternalTaskState(
                source: .cherryStudio,
                sessionID: "cherry-agent:\(sessionID)",
                title: ExternalTokenSource.noticeTitle(brand: "Cherry Studio", detail: name),
                isRunning: isRunning,
                isComplete: isComplete,
                updatedAt: updatedAt
            )
        }
    }

    private static func metadataStatus(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ""
        }
        for key in ["status", "state", "phase"] {
            if let value = json[key] as? String {
                return value.lowercased()
            }
        }
        return ""
    }

    private static func parseFlexibleDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(trimmed) {
            if value > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: value / 1000)
            }
            if value > 1_000_000_000 {
                return Date(timeIntervalSince1970: value)
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: trimmed)
    }

    private static func queryRows(databaseURL: URL, sql: String) -> [[String]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
              let database
        else {
            return []
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columnCount = sqlite3_column_count(statement)
            var row: [String] = []
            row.reserveCapacity(Int(columnCount))
            for index in 0..<columnCount {
                if let cString = sqlite3_column_text(statement, index) {
                    row.append(String(cString: cString))
                } else {
                    row.append("")
                }
            }
            rows.append(row)
        }
        return rows
    }
}

struct KiroSessionFile: Decodable {
    let id: String?
    let title: String?
    let modelId: String?
    let status: String?
}

struct KiroMessageEnvelope: Decodable {
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let key: String?
        let value: ContextUsage?
        let status: String?
        let category: String?
        let context: Context?

        struct ContextUsage: Decodable {
            let usagePercentage: Double?
        }

        struct Context: Decodable {
            let status: String?
        }
    }
}

struct CursorComposerHeaders: Decodable {
    let allComposers: [Composer]

    struct Composer: Decodable {
        let composerId: String
        let name: String?
        let lastUpdatedAt: Double?
        let contextUsagePercent: Double?
    }
}

struct CursorComposerData: Decodable {
    let name: String?
    let lastUpdatedAt: Double?
    let status: String?
    let generatingBubbleIds: [String]?
    let contextUsagePercent: Double?
    let modelConfig: ModelConfig?
    let promptTokenBreakdown: PromptTokenBreakdown?

    struct ModelConfig: Decodable {
        let modelName: String?
    }

    struct PromptTokenBreakdown: Decodable {
        let totalUsedTokens: Int?
        let maxTokens: Int?
    }
}

struct CursorTranscriptEvent: Decodable {
    let type: String?
    let status: String?
}

struct CodexRolloutEvent: Decodable {
    let payload: Payload

    struct Payload: Decodable {
        let info: TokenInfo?
        let model: String?
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case info
            case model
            case rateLimits = "rate_limits"
        }
    }

    struct TokenInfo: Decodable {
        let totalTokenUsage: Usage?
        let lastTokenUsage: Usage?
        let modelContextWindow: Int

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
            case lastTokenUsage = "last_token_usage"
            case modelContextWindow = "model_context_window"
        }
    }

    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case totalTokens = "total_tokens"
        }
    }

    struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
        let planType: String?

        enum CodingKeys: String, CodingKey {
            case primary
            case secondary
            case planType = "plan_type"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double?
        let windowMinutes: Int?
        let resetsAt: Double?
        let resetsInSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
            case resetsInSeconds = "resets_in_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = Self.decodeFlexibleDouble(container, forKey: .usedPercent)
            windowMinutes = Self.decodeFlexibleInt(container, forKey: .windowMinutes)
            resetsAt = Self.decodeFlexibleDouble(container, forKey: .resetsAt)
            resetsInSeconds = Self.decodeFlexibleDouble(container, forKey: .resetsInSeconds)
        }

        private static func decodeFlexibleDouble(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Double? {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Double(value)
            }
            return nil
        }

        private static func decodeFlexibleInt(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int(value.rounded())
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(value)
            }
            return nil
        }
    }
}


/// DeepSeek Harness (com.deepseek.dsh) writes a plain-JSON mirror of each session's state
/// to ~/.dsh/storages/session_projcache/sessions/<session-uuid>.json. The turn boundary
/// flips between {"kind":"start"} (agent working) and {"kind":"end"} (agent finished),
/// so completion detection needs no private API and no subprocess — just a file read.
enum DeepSeekHarnessTaskReader {
    private static let freshnessWindow: TimeInterval = 24 * 3600

    static func taskStates() -> [ExternalTaskState] {
        guard let sessionsRoot = sessionsRoot() else { return [] }
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard
                let values = try? url.resourceValues(forKeys: resourceKeys),
                values.isRegularFile == true,
                let modifiedAt = values.contentModificationDate
            else {
                continue
            }
            files.append((url, modifiedAt))
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(12)
            .compactMap { taskState(from: $0.url, modifiedAt: $0.modifiedAt) }
    }

    private static func sessionsRoot() -> URL? {
#if LUMA_APP_STORE
        guard let home = SecurityScopedBookmarks.retainedURL(for: .deepSeekHarnessHome) else {
            return nil
        }
        return home
            .appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
#else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/storages/session_projcache/sessions", isDirectory: true)
#endif
    }

    private static func taskState(from url: URL, modifiedAt: Date) -> ExternalTaskState? {
        // Skip ancient mirrors so long-finished sessions never cost a parse or a toast.
        guard Date().timeIntervalSince(modifiedAt) < freshnessWindow else { return nil }

        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let record = root["record"] as? [String: Any]
        else {
            return nil
        }

        let rows = record["rows"] as? [String: Any]
        let boundary = (rows?["turnBoundary"] as? [String: Any])?["val"] as? [String: Any]
        let lastBoundary = boundary?["lastStepBoundary"] as? [String: Any]
        let boundaryKind = lastBoundary?["kind"] as? String ?? ""
        let hasOpenTurn = boundary?["openTurnStartSeq"] is Int

        let isRunning = hasOpenTurn && boundaryKind == "start"
        let isComplete = boundaryKind == "end"
        guard isRunning || isComplete else { return nil }

        let identity = record["identity"] as? [String: Any]
        let cwd = identity?["cwd"] as? String ?? ""
        let projectName = URL(fileURLWithPath: cwd)
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var title = ((rows?["title"] as? [String: Any])?["val"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Some mirrors store the workspace path as the title ("@/Users/..."). Show its folder.
        if title.hasPrefix("@") {
            title = URL(fileURLWithPath: String(title.dropFirst()))
                .lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let detail: String
        if !title.isEmpty, title.caseInsensitiveCompare("session") != .orderedSame {
            detail = title
        } else if !projectName.isEmpty, projectName != "/" {
            detail = projectName
        } else {
            detail = "任务"
        }

        let sessionID = url.deletingPathExtension().lastPathComponent
        return ExternalTaskState(
            source: .deepSeekHarness,
            sessionID: sessionID,
            title: ExternalTokenSource.noticeTitle(brand: "DeepSeek Harness", detail: detail),
            isRunning: isRunning,
            isComplete: isComplete,
            updatedAt: modifiedAt
        )
    }
}
