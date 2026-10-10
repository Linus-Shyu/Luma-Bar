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

struct NetEaseAgentSearchResponse: Decodable {
    let result: NetEaseAgentSearchResult?
}

struct NetEaseAgentSearchResult: Decodable {
    let songs: [NetEaseAgentSearchSong]?
}

struct NetEaseAgentSearchSong: Decodable {
    let id: Int64
    let name: String
    let artists: [NetEaseAgentSearchArtist]
}

struct NetEaseAgentSearchArtist: Decodable {
    let name: String
}

enum NetEaseAgentSearchClient {
    static func firstSong(matching query: String) async throws -> (id: String, title: String, artist: String)? {
        let songs = try await songs(matching: query, limit: 5)
        guard let song = songs.first else { return nil }
        let artist = song.artists.map(\.name).joined(separator: "/")
        return (String(song.id), song.name, artist)
    }

    static func bestSong(
        title: String,
        artist: String
    ) async throws -> (id: String, title: String, artist: String)? {
        let normalizedRawArtist = normalizedLookupKey(artist)
        let effectiveArtist = ["neteasecloudmusic", "网易云音乐"].contains(normalizedRawArtist)
            ? ""
            : artist
        let query = [title, effectiveArtist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let requestedTitle = normalizedLookupKey(title)
        let requestedArtist = normalizedLookupKey(effectiveArtist)
        guard !requestedTitle.isEmpty else { return nil }

        let candidates = try await songs(matching: query, limit: 12)
        let best = candidates.compactMap { song -> (song: NetEaseAgentSearchSong, score: Int)? in
            let titleKey = normalizedLookupKey(song.name)
            var score: Int
            if titleKey == requestedTitle {
                score = 150
            } else if titleKey.contains(requestedTitle) || requestedTitle.contains(titleKey) {
                score = 85
            } else {
                return nil
            }

            let candidateArtist = song.artists.map(\.name).joined(separator: "/")
            let artistKey = normalizedLookupKey(candidateArtist)
            if !requestedArtist.isEmpty, !artistKey.isEmpty {
                if artistKey == requestedArtist {
                    score += 50
                } else if artistKey.contains(requestedArtist) || requestedArtist.contains(artistKey) {
                    score += 28
                } else {
                    score -= 35
                }
            }
            return (song, score)
        }
        .max { $0.score < $1.score }

        guard let best, best.score >= 100 else { return nil }
        let matchedArtist = best.song.artists.map(\.name).joined(separator: "/")
        return (String(best.song.id), best.song.name, matchedArtist)
    }

    private static func songs(
        matching query: String,
        limit: Int
    ) async throws -> [NetEaseAgentSearchSong] {
        var components = URLComponents(string: "https://music.163.com/api/search/get")
        components?.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            return []
        }

        return try JSONDecoder().decode(NetEaseAgentSearchResponse.self, from: data)
            .result?.songs ?? []
    }

    private static func normalizedLookupKey(_ value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        return String(folded.filter { $0.isLetter || $0.isNumber })
    }
}

struct LocalAppLaunchResult {
    let displayName: String
    let bundleIdentifier: String?
    let wasAlreadyRunning: Bool
}

struct PendingMessageAction: Equatable {
    let recipient: String
    let content: String
}

struct AgentMemoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date
}

enum AgentMemoryStore {
    private static let defaultsKey = "LumaBar.agentLongTermMemory.v1"
    private static let maximumEntries = 50
    private static let maximumContextCharacters = 8_000

    static var entries: [AgentMemoryEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([AgentMemoryEntry].self, from: data)
        else {
            return []
        }
        return decoded
    }

    @discardableResult
    static func remember(_ rawText: String) -> AgentMemoryEntry? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var stored = entries.filter {
            $0.text.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        }
        let entry = AgentMemoryEntry(id: UUID(), text: text, createdAt: Date())
        stored.append(entry)
        if stored.count > maximumEntries {
            stored.removeFirst(stored.count - maximumEntries)
        }
        persist(stored)
        return entry
    }

    static func forget(matching rawQuery: String) -> Int {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }
        let stored = entries
        let remaining = stored.filter {
            $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil
        }
        persist(remaining)
        return stored.count - remaining.count
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    static var promptContext: String? {
        let stored = entries
        guard !stored.isEmpty else { return nil }
        var result = ""
        for entry in stored.reversed() {
            let line = "- \(entry.text)\n"
            guard result.count + line.count <= maximumContextCharacters else { break }
            result = line + result
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resolvedRecipientAlias(for rawRecipient: String) -> String {
        var recipient = rawRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        if recipient.hasPrefix("我"), recipient.count > 1 {
            recipient.removeFirst()
        }
        let escaped = NSRegularExpression.escapedPattern(for: recipient)
        let pattern = #"(?:我)?\#(escaped)(?:的)?(?:名字|姓名|联系方式|电话|手机号)?(?:叫|是|为)\s*([^，。,.；;]{2,60})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return recipient
        }
        for entry in entries.reversed() {
            guard
                let match = regex.firstMatch(
                    in: entry.text,
                    range: NSRange(entry.text.startIndex..., in: entry.text)
                ),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: entry.text)
            else {
                continue
            }
            let alias = String(entry.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty {
                return alias
            }
        }
        return recipient
    }

    private static func persist(_ entries: [AgentMemoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

struct AgentActivityEntry: Codable, Sendable {
    let id: UUID
    let summary: String
    let filePaths: [String]
    let createdAt: Date
}

enum AgentActivityMemoryStore {
    private static let defaultsKey = "LumaBar.agentActivityMemory.v1"
    private static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumEntries = 30
    private static let maximumContextCharacters = 4_000

    static var entries: [AgentActivityEntry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([AgentActivityEntry].self, from: data)
        else {
            return []
        }
        return decoded.filter { Date().timeIntervalSince($0.createdAt) <= retentionInterval }
    }

    static func record(summary rawSummary: String, filePaths rawPaths: [String] = []) {
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let filePaths = rawPaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !summary.isEmpty || !filePaths.isEmpty else { return }

        var stored = entries
        stored.append(
            AgentActivityEntry(
                id: UUID(),
                summary: String(summary.prefix(600)),
                filePaths: Array(filePaths.prefix(8)),
                createdAt: Date()
            )
        )
        if stored.count > maximumEntries {
            stored.removeFirst(stored.count - maximumEntries)
        }
        persist(stored)
    }

    static var promptContext: String? {
        var result = ""
        for entry in entries.suffix(12).reversed() {
            let paths = entry.filePaths.isEmpty
                ? ""
                : " | files: \(entry.filePaths.joined(separator: ", "))"
            let line = "- \(entry.summary)\(paths)\n"
            guard result.count + line.count <= maximumContextCharacters else { break }
            result = line + result
        }
        let context = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return context.isEmpty ? nil : context
    }

    static func referencesRecentArtifact(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let phrases = [
            "你帮我下载", "你下载", "刚下载", "刚才下载",
            "你帮我做", "你做的", "你创建", "刚创建", "刚生成",
            "刚才那个", "上一个文件", "那个文件", "这个文件",
            "what you downloaded", "the file you made", "that file", "last file"
        ]
        return phrases.contains { normalized.contains($0) }
    }

    static func mostRecentArtifactURL() -> URL? {
        for entry in entries.reversed() {
            for path in entry.filePaths.reversed()
            where FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return fallbackRecentArtifactURL()
    }

    static func filesModified(since date: Date) -> [String] {
        artifactDirectories()
            .flatMap { recentContents(of: $0, modifiedSince: date) }
            .sorted { $0.date > $1.date }
            .prefix(8)
            .map(\.url.path)
    }

    private static func fallbackRecentArtifactURL() -> URL? {
        artifactDirectories()
            .flatMap { recentContents(of: $0, modifiedSince: Date().addingTimeInterval(-retentionInterval)) }
            .sorted { $0.date > $1.date }
            .first?
            .url
    }

    private static func artifactDirectories() -> [URL] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        return [
            manager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            manager.urls(for: .desktopDirectory, in: .userDomainMask).first,
            manager.urls(for: .documentDirectory, in: .userDomainMask).first,
            home.appendingPathComponent("Downloads")
        ]
        .compactMap { $0 }
        .reduce(into: [URL]()) { result, url in
            if !result.contains(url) {
                result.append(url)
            }
        }
    }

    private static func recentContents(
        of directory: URL,
        modifiedSince date: Date
    ) -> [(url: URL, date: Date)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= date,
                  url.pathExtension.lowercased() != "download"
            else {
                return nil
            }
            return (url, modifiedAt)
        }
    }

    private static func persist(_ entries: [AgentActivityEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

enum LocalMessageParser {
    static func action(from prompt: String) -> PendingMessageAction? {
        let patterns = [
            #"(?i)^(?:请|帮我|麻烦你|让\s*(?:ai|agent))?\s*(?:给|向)\s*(.+?)\s*(?:用\s*)?(?:发|发送)(?:一条|一个|个)?(?:信息|消息|短信|imessage|imassage)\s*(?:(?:就)?说|告诉(?:他|她|他们)?|内容(?:是|为)?|[，,:：])?\s*(.+)$"#,
            #"(?i)^(?:请|帮我|麻烦你|让\s*(?:ai|agent))?\s*(?:用\s*)?(?:imessage|imassage\s*)?(?:发|发送)(?:一条|一个|个)?(?:信息|消息|短信)?\s*(?:给|向)\s*(.+?)\s*(?:(?:就)?说|告诉(?:他|她|他们)?|内容(?:是|为)?|[，,:：])\s*(.+)$"#,
            #"^(?:请|帮我|麻烦你)?\s*(?:跟|对)\s*(.+?)\s*说\s*[，,:：]?\s*(.+)$"#,
            #"(?i)^(?:please\s+)?(?:message|text)\s+(.+?)\s+(?:and\s+say|saying|:)\s*(.+)$"#
        ]

        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
                match.numberOfRanges >= 3,
                let recipientRange = Range(match.range(at: 1), in: prompt),
                let contentRange = Range(match.range(at: 2), in: prompt)
            else {
                continue
            }
            var recipient = String(prompt[recipientRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(prompt[contentRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if recipient.hasPrefix("我"), recipient.count > 1 {
                recipient.removeFirst()
            }
            guard !recipient.isEmpty, !content.isEmpty else { continue }
            return PendingMessageAction(
                recipient: AgentMemoryStore.resolvedRecipientAlias(for: recipient),
                content: content
            )
        }
        return nil
    }

    static func looksLikeMessageRequest(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let hasMessageVerb = normalized.contains("发消息")
            || normalized.contains("发信息")
            || normalized.contains("发短信")
            || normalized.contains("发送消息")
            || normalized.contains("发送信息")
            || normalized.contains("imessage")
            || normalized.contains("imassage")
            || normalized.contains("text ")
            || normalized.contains("message ")
        return hasMessageVerb && (
            normalized.contains("给")
                || normalized.contains("向")
                || normalized.contains("妈妈")
                || normalized.contains("爸爸")
                || normalized.contains(" to ")
        )
    }
}

enum MessagesAgentBridge {
    enum BridgeError: LocalizedError {
        case contactsDenied
        case contactNotFound(String)
        case noMessageHandle(String)
        case sendFailed(String)

        var errorDescription: String? {
            switch self {
            case .contactsDenied:
                return "需要通讯录权限才能按姓名查找联系人。"
            case .contactNotFound(let name):
                return "通讯录里没有找到“\(name)”，请使用完整姓名、手机号或邮箱。"
            case .noMessageHandle(let name):
                return "“\(name)”没有可用于信息 App 的手机号或邮箱。"
            case .sendFailed(let detail):
                return "信息发送失败：\(detail)"
            }
        }
    }

    static func send(_ action: PendingMessageAction) async throws {
        let handle = try await resolveHandle(for: action.recipient)
        let script = """
        tell application id "com.apple.MobileSMS"
            set targetService to first service whose service type is iMessage
            set targetBuddy to buddy \(appleScriptString(handle)) of targetService
            send \(appleScriptString(action.content)) to targetBuddy
        end tell
        """
        let ok = await Task.detached(priority: .userInitiated) {
            ExclusiveAudioFocus.runAppleScript(script)
        }.value
        guard ok else {
            throw BridgeError.sendFailed("Messages automation error")
        }
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func resolveHandle(for recipient: String) async throws -> String {
        let compact = recipient.replacingOccurrences(of: " ", with: "")
        if compact.contains("@") || compact.range(of: #"^\+?[0-9()\-\s]{6,}$"#, options: .regularExpression) != nil {
            return recipient
        }

        let store = CNContactStore()
        let granted = try await store.requestAccess(for: .contacts)
        guard granted else { throw BridgeError.contactsDenied }
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactNicknameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        let query = recipient.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var matchedContact: CNContact?
        try store.enumerateContacts(with: request) { contact, stop in
            let names = [
                contact.nickname,
                contact.givenName,
                contact.familyName,
                "\(contact.familyName)\(contact.givenName)",
                "\(contact.givenName) \(contact.familyName)",
                contact.organizationName
            ]
            if names.contains(where: {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == query
            }) {
                matchedContact = contact
                stop.pointee = true
            }
        }
        guard let contact = matchedContact else {
            throw BridgeError.contactNotFound(recipient)
        }
        if let phone = contact.phoneNumbers.first?.value.stringValue, !phone.isEmpty {
            return phone
        }
        if let email = contact.emailAddresses.first?.value as String?, !email.isEmpty {
            return email
        }
        throw BridgeError.noMessageHandle(recipient)
    }
}


struct LocalAppAlias {
    let keys: [String]
    let bundleIdentifiers: [String]
    let fallbackNames: [String]
}

enum LocalAppLaunchError: LocalizedError {
    case missingAppName
    case notFound(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAppName:
            return "请告诉我要打开哪个应用，例如：打开 Safari / 打开微信 / open VS Code。"
        case .notFound(let appName):
            return "这台 Mac 上没有找到应用「\(appName)」。可以试试系统英文名，或确认已经安装。"
        case .launchFailed(let appName):
            return "找到了「\(appName)」，但 macOS 没有成功启动它。"
        }
    }
}

enum LocalAppLauncher {
    static func commandTarget(from prompt: String) -> String? {
        let patterns = [
            #"(?i)\b(?:open|launch|start|run)\s+(?:the\s+)?(?:app(?:lication)?\s+)?([A-Za-z0-9][A-Za-z0-9\s+._-]{0,80})"#,
            #"(?:帮我|给我|请|麻烦你)?\s*(?:打开|启动|开启|运行)\s*(?:一下|下)?\s*(?:软件|应用|app|程序)?\s*([\p{Han}A-Za-z0-9][\p{Han}A-Za-z0-9\s+._-]{0,80})"#,
            #"(?:帮我|给我|请|麻烦你)?\s*开\s*(?:一下|下)?\s*(?:软件|应用|app|程序)?\s*([\p{Han}A-Za-z0-9][\p{Han}A-Za-z0-9\s+._-]{0,80})"#
        ]

        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: prompt)
            else {
                continue
            }

            if let appName = cleanedCommandTarget(String(prompt[range])) {
                return appName
            }
        }

        return nil
    }

    static func looksLikeLaunchRequest(_ prompt: String) -> Bool {
        let lowercased = prompt.lowercased()
        return prompt.contains("打开")
            || prompt.contains("启动")
            || prompt.contains("开启")
            || prompt.contains("运行")
            || lowercased.contains("open ")
            || lowercased.contains("launch ")
            || lowercased.contains("start ")
            || lowercased.contains("run ")
    }

    static func isLikelyApplicationName(_ rawName: String) -> Bool {
        guard let appName = cleanedCommandTarget(rawName) else { return false }
        let normalizedQuery = normalized(appName)
        if aliases.contains(where: { alias in
            (alias.keys + alias.fallbackNames).contains { normalized($0) == normalizedQuery }
        }) {
            return true
        }
        return installedApplications().contains { $0.normalizedNames.contains(normalizedQuery) }
    }

    static func launchApplication(
        named rawName: String,
        willActivate: ((String) -> Void)? = nil
    ) throws -> LocalAppLaunchResult {
        guard let appName = cleanedCommandTarget(rawName) else {
            throw LocalAppLaunchError.missingAppName
        }

        if let result = try launchPathIfNeeded(appName, willActivate: willActivate) {
            return result
        }

        let normalizedQuery = normalized(appName)

        if let alias = aliases.first(where: { alias in
            (alias.keys + alias.fallbackNames).contains { normalized($0) == normalizedQuery }
        }) {
            if let result = launchBundleIdentifiers(
                alias.bundleIdentifiers,
                displayName: alias.fallbackNames.first ?? appName,
                willActivate: willActivate
            ) {
                return result
            }

            if let result = try launchBestInstalledApp(
                matchingAny: alias.fallbackNames + alias.keys,
                willActivate: willActivate
            ) {
                return result
            }
        }

        if let result = try launchBestInstalledApp(matchingAny: [appName], willActivate: willActivate) {
            return result
        }

        throw LocalAppLaunchError.notFound(appName)
    }

    private static let aliases: [LocalAppAlias] = [
        LocalAppAlias(
            keys: ["finder", "访达"],
            bundleIdentifiers: ["com.apple.finder"],
            fallbackNames: ["Finder", "访达"]
        ),
        LocalAppAlias(
            keys: ["safari", "浏览器", "苹果浏览器"],
            bundleIdentifiers: ["com.apple.Safari"],
            fallbackNames: ["Safari"]
        ),
        LocalAppAlias(
            keys: ["chrome", "google chrome", "谷歌浏览器"],
            bundleIdentifiers: ["com.google.Chrome"],
            fallbackNames: ["Google Chrome", "Chrome"]
        ),
        LocalAppAlias(
            keys: ["system settings", "system preferences", "settings", "系统设置", "设置"],
            bundleIdentifiers: ["com.apple.systempreferences"],
            fallbackNames: ["System Settings", "System Preferences"]
        ),
        LocalAppAlias(
            keys: ["terminal", "终端"],
            bundleIdentifiers: ["com.apple.Terminal"],
            fallbackNames: ["Terminal", "终端"]
        ),
        LocalAppAlias(
            keys: ["iterm", "iterm2"],
            bundleIdentifiers: ["com.googlecode.iterm2"],
            fallbackNames: ["iTerm", "iTerm2"]
        ),
        LocalAppAlias(
            keys: ["activity monitor", "活动监视器"],
            bundleIdentifiers: ["com.apple.ActivityMonitor"],
            fallbackNames: ["Activity Monitor", "活动监视器"]
        ),
        LocalAppAlias(
            keys: ["music", "apple music", "音乐"],
            bundleIdentifiers: ["com.apple.Music"],
            fallbackNames: ["Music", "音乐"]
        ),
        LocalAppAlias(
            keys: ["netease", "netease cloud music", "neteasemusic", "netease music", "网易云", "网易云音乐"],
            bundleIdentifiers: [netEaseMusicBundleIdentifier],
            fallbackNames: ["NeteaseMusic", "NetEaseMusic", "NetEase Cloud Music", "网易云音乐", "网易云"]
        ),
        LocalAppAlias(
            keys: ["wechat", "微信", "weixin"],
            bundleIdentifiers: ["com.tencent.xinWeChat", "com.tencent.WeChat"],
            fallbackNames: ["WeChat", "微信"]
        ),
        LocalAppAlias(
            keys: ["wecom", "企业微信", "wework"],
            bundleIdentifiers: ["com.tencent.WeWorkMac"],
            fallbackNames: ["WeCom", "企业微信", "WXWork"]
        ),
        LocalAppAlias(
            keys: ["feishu", "飞书", "lark"],
            bundleIdentifiers: [
                "com.electron.lark",
                "com.larksuite.Lark",
                "com.bytedance.ee.lark"
            ],
            fallbackNames: ["Lark", "Feishu", "飞书"]
        ),
        LocalAppAlias(
            keys: ["tencent meeting", "tencentmeeting", "腾讯会议"],
            bundleIdentifiers: ["com.tencent.meeting"],
            fallbackNames: ["TencentMeeting", "Tencent Meeting", "腾讯会议"]
        ),
        LocalAppAlias(
            keys: ["jianying", "capcut", "剪映", "videofusion"],
            bundleIdentifiers: ["com.lemon.lvpro", "com.bytedance.videocut"],
            fallbackNames: ["VideoFusion-macOS", "CapCut", "剪映"]
        ),
        LocalAppAlias(
            keys: ["seewo", "希沃白板", "希沃", "easinote"],
            bundleIdentifiers: ["com.seewo.easinote5.mac", "cn.seewo.board"],
            fallbackNames: ["希沃白板", "EasiNote"]
        ),
        LocalAppAlias(
            keys: ["vscode", "vs code", "visual studio code", "code"],
            bundleIdentifiers: ["com.microsoft.VSCode"],
            fallbackNames: ["Visual Studio Code", "VS Code", "Code"]
        ),
        LocalAppAlias(
            keys: ["cursor"],
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            fallbackNames: ["Cursor"]
        ),
        LocalAppAlias(
            keys: ["xcode"],
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            fallbackNames: ["Xcode"]
        ),
        LocalAppAlias(
            keys: ["codex"],
            bundleIdentifiers: ["com.openai.codex"],
            fallbackNames: ["Codex"]
        ),
        LocalAppAlias(
            keys: ["kiro"],
            bundleIdentifiers: ["dev.kiro.desktop"],
            fallbackNames: ["Kiro"]
        ),
        LocalAppAlias(
            keys: ["chatgpt", "chat gpt"],
            bundleIdentifiers: ["com.openai.chat", "com.openai.codex"],
            fallbackNames: ["ChatGPT", "ChatGPT Classic"]
        ),
        LocalAppAlias(
            keys: ["cherry studio", "cherrystudio", "cherry"],
            bundleIdentifiers: ["com.kangfenmao.CherryStudio"],
            fallbackNames: ["Cherry Studio"]
        ),
        LocalAppAlias(
            keys: ["notes", "备忘录"],
            bundleIdentifiers: ["com.apple.Notes"],
            fallbackNames: ["Notes", "备忘录"]
        ),
        LocalAppAlias(
            keys: ["calendar", "日历"],
            bundleIdentifiers: ["com.apple.iCal"],
            fallbackNames: ["Calendar", "日历"]
        ),
        LocalAppAlias(
            keys: ["mail", "邮件"],
            bundleIdentifiers: ["com.apple.mail"],
            fallbackNames: ["Mail", "邮件"]
        ),
        LocalAppAlias(
            keys: ["reminders", "提醒事项"],
            bundleIdentifiers: ["com.apple.reminders"],
            fallbackNames: ["Reminders", "提醒事项"]
        ),
        LocalAppAlias(
            keys: ["photos", "照片", "图片", "相册", "图库"],
            bundleIdentifiers: ["com.apple.Photos"],
            fallbackNames: ["Photos", "照片"]
        ),
        LocalAppAlias(
            keys: ["preview", "预览", "看图"],
            bundleIdentifiers: ["com.apple.Preview"],
            fallbackNames: ["Preview", "预览"]
        ),
        LocalAppAlias(
            keys: ["textedit", "文本编辑"],
            bundleIdentifiers: ["com.apple.TextEdit"],
            fallbackNames: ["TextEdit", "文本编辑"]
        ),
        LocalAppAlias(
            keys: ["calculator", "计算器"],
            bundleIdentifiers: ["com.apple.calculator"],
            fallbackNames: ["Calculator", "计算器"]
        ),
        LocalAppAlias(
            keys: ["maps", "地图"],
            bundleIdentifiers: ["com.apple.Maps"],
            fallbackNames: ["Maps", "地图"]
        ),
        LocalAppAlias(
            keys: ["weather", "天气"],
            bundleIdentifiers: ["com.apple.weather"],
            fallbackNames: ["Weather", "天气"]
        ),
        LocalAppAlias(
            keys: ["messages", "信息", "短信"],
            bundleIdentifiers: ["com.apple.MobileSMS"],
            fallbackNames: ["Messages", "信息"]
        ),
        LocalAppAlias(
            keys: ["facetime"],
            bundleIdentifiers: ["com.apple.FaceTime"],
            fallbackNames: ["FaceTime"]
        ),
        LocalAppAlias(
            keys: ["spotify"],
            bundleIdentifiers: ["com.spotify.client"],
            fallbackNames: ["Spotify"]
        ),
        LocalAppAlias(
            keys: ["discord"],
            bundleIdentifiers: ["com.hnc.Discord"],
            fallbackNames: ["Discord"]
        ),
        LocalAppAlias(
            keys: ["slack"],
            bundleIdentifiers: ["com.tinyspeck.slackmacgap"],
            fallbackNames: ["Slack"]
        ),
        LocalAppAlias(
            keys: ["notion"],
            bundleIdentifiers: ["notion.id"],
            fallbackNames: ["Notion"]
        ),
        LocalAppAlias(
            keys: ["obsidian"],
            bundleIdentifiers: ["md.obsidian"],
            fallbackNames: ["Obsidian"]
        ),
        LocalAppAlias(
            keys: ["zoom"],
            bundleIdentifiers: ["us.zoom.xos"],
            fallbackNames: ["zoom.us", "Zoom"]
        ),
        LocalAppAlias(
            keys: ["figma"],
            bundleIdentifiers: ["com.figma.Desktop"],
            fallbackNames: ["Figma"]
        ),
        LocalAppAlias(
            keys: ["word", "microsoft word"],
            bundleIdentifiers: ["com.microsoft.Word"],
            fallbackNames: ["Microsoft Word", "Word"]
        ),
        LocalAppAlias(
            keys: ["excel", "microsoft excel"],
            bundleIdentifiers: ["com.microsoft.Excel"],
            fallbackNames: ["Microsoft Excel", "Excel"]
        ),
        LocalAppAlias(
            keys: ["powerpoint", "ppt", "microsoft powerpoint"],
            bundleIdentifiers: ["com.microsoft.Powerpoint"],
            fallbackNames: ["Microsoft PowerPoint", "PowerPoint"]
        )
    ]

    private static func launchBundleIdentifiers(
        _ bundleIdentifiers: [String],
        displayName: String,
        willActivate: ((String) -> Void)?
    ) -> LocalAppLaunchResult? {
        for bundleIdentifier in bundleIdentifiers {
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            if let runningApplication = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first {
                return showRunningApplication(
                    runningApplication,
                    appURL: appURL,
                    fallbackName: displayName,
                    bundleIdentifier: bundleIdentifier,
                    willActivate: willActivate
                )
            }

            guard let appURL else {
                continue
            }

            if let result = try? launchApp(at: appURL, fallbackName: displayName, willActivate: willActivate) {
                return result
            }
        }

        return nil
    }

    private static func launchPathIfNeeded(
        _ appName: String,
        willActivate: ((String) -> Void)?
    ) throws -> LocalAppLaunchResult? {
        let expandedPath: String
        if appName.hasPrefix("~/") {
            expandedPath = FileManager.default.homeDirectoryForCurrentUser.path
                + String(appName.dropFirst())
        } else {
            expandedPath = appName
        }

        guard expandedPath.hasPrefix("/") else {
            return nil
        }

        let appURL = URL(fileURLWithPath: expandedPath)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw LocalAppLaunchError.notFound(appName)
        }

        return try launchApp(at: appURL, fallbackName: appURL.deletingPathExtension().lastPathComponent, willActivate: willActivate)
    }

    private static func launchBestInstalledApp(
        matchingAny queries: [String],
        willActivate: ((String) -> Void)?
    ) throws -> LocalAppLaunchResult? {
        let normalizedQueries = queries
            .map(normalized)
            .filter { !$0.isEmpty }

        guard !normalizedQueries.isEmpty else {
            return nil
        }

        let apps = installedApplications()

        if let exact = apps.first(where: { app in
            !Set(app.normalizedNames).isDisjoint(with: normalizedQueries)
                || app.bundleIdentifier.map { normalizedQueries.contains(normalized($0)) } == true
        }) {
            return try launchApp(at: exact.url, fallbackName: exact.displayName, willActivate: willActivate)
        }

        if let prefix = apps.first(where: { app in
            normalizedQueries.contains { query in
                app.normalizedNames.contains { name in
                    name.hasPrefix(query) || query.hasPrefix(name)
                }
            }
        }) {
            return try launchApp(at: prefix.url, fallbackName: prefix.displayName, willActivate: willActivate)
        }

        if let contains = apps.first(where: { app in
            normalizedQueries.contains { query in
                app.normalizedNames.contains { name in
                    name.contains(query) || query.contains(name)
                }
            }
        }) {
            return try launchApp(at: contains.url, fallbackName: contains.displayName, willActivate: willActivate)
        }

        return nil
    }

    private static func launchApp(
        at appURL: URL,
        fallbackName: String,
        willActivate: ((String) -> Void)?
    ) throws -> LocalAppLaunchResult {
        let bundle = Bundle(url: appURL)
        let bundleIdentifier = bundle?.bundleIdentifier
        let displayName = appDisplayName(from: appURL, bundle: bundle) ?? fallbackName

        if let bundleIdentifier,
           let runningApplication = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
           ).first
        {
            return showRunningApplication(
                runningApplication,
                appURL: appURL,
                fallbackName: displayName,
                bundleIdentifier: bundleIdentifier,
                willActivate: willActivate
            )
        }

        if let bundleIdentifier {
            willActivate?(bundleIdentifier)
        }

        guard NSWorkspace.shared.open(appURL) else {
            throw LocalAppLaunchError.launchFailed(displayName)
        }

        return LocalAppLaunchResult(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            wasAlreadyRunning: false
        )
    }

    private static func showRunningApplication(
        _ runningApplication: NSRunningApplication,
        appURL: URL?,
        fallbackName: String,
        bundleIdentifier: String,
        willActivate: ((String) -> Void)?
    ) -> LocalAppLaunchResult {
        willActivate?(bundleIdentifier)
        runningApplication.unhide()
        runningApplication.activate(options: [.activateAllWindows])

        if let appURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
        }

        return LocalAppLaunchResult(
            displayName: runningApplication.localizedName ?? fallbackName,
            bundleIdentifier: bundleIdentifier,
            wasAlreadyRunning: true
        )
    }

    private struct InstalledApplication {
        let url: URL
        let displayName: String
        let normalizedNames: [String]
        let bundleIdentifier: String?
    }

    private static func installedApplications() -> [InstalledApplication] {
        let directories = [
            "/Applications",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",
            "/System/Library/CoreServices/Applications"
        ]

        var seenPaths = Set<String>()
        var apps: [InstalledApplication] = []

        for path in directories {
            let directoryURL = URL(fileURLWithPath: path)
            guard let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let appURL as URL in enumerator where appURL.pathExtension == "app" {
                guard !seenPaths.contains(appURL.path) else { continue }
                seenPaths.insert(appURL.path)

                let bundle = Bundle(url: appURL)
                let names = localizedAppNames(from: appURL, bundle: bundle)
                let displayName = names.first
                    ?? appURL.deletingPathExtension().lastPathComponent
                let normalizedNames = Array(
                    Set(names.map(normalized).filter { !$0.isEmpty })
                )
                apps.append(
                    InstalledApplication(
                        url: appURL,
                        displayName: displayName,
                        normalizedNames: normalizedNames,
                        bundleIdentifier: bundle?.bundleIdentifier
                    )
                )
            }
        }

        return apps.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func localizedAppNames(from appURL: URL, bundle: Bundle?) -> [String] {
        var names: [String] = []
        names.append(appURL.deletingPathExtension().lastPathComponent)

        if let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            names.append(displayName)
        }
        if let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String {
            names.append(bundleName)
        }

        let resourceRoot = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let locales = ["zh-Hans", "zh_CN", "zh-Hant", "zh_TW", "en", "Base"]
        for locale in locales {
            let stringsURL = resourceRoot
                .appendingPathComponent("\(locale).lproj", isDirectory: true)
                .appendingPathComponent("InfoPlist.strings")
            guard let dictionary = NSDictionary(contentsOf: stringsURL) as? [String: Any] else {
                continue
            }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = dictionary[key] as? String {
                    names.append(value)
                }
            }
        }

        var seen = Set<String>()
        return names.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = normalized(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    private static func appDisplayName(from appURL: URL, bundle: Bundle?) -> String? {
        localizedAppNames(from: appURL, bundle: bundle).first
    }

    private static func cleanedCommandTarget(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t。.!！?？,，"))
        guard !value.isEmpty else { return nil }

        if value.lowercased().hasPrefix("the ") {
            value = String(value.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let englishSuffixes = [" application", " software", " program", " please", " pls", " app"]
        for suffix in englishSuffixes where value.lowercased().hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if value.lowercased().hasSuffix("app"),
           value.range(of: #"[\p{Han}]\s*app$"#, options: .regularExpression) != nil
        {
            value = String(value.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let chineseSuffixes = ["一下", "下", "吧", "谢谢", "这个软件", "这个应用", "软件", "应用", "程序"]
        for suffix in chineseSuffixes where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let genericTargets = Set([
            "app",
            "application",
            "program",
            "software",
            "软件",
            "应用",
            "程序",
            "一个软件",
            "一个应用"
        ])

        let normalizedValue = normalized(value)
        guard !normalizedValue.isEmpty else { return nil }
        guard !genericTargets.contains(value.lowercased()) && !genericTargets.contains(normalizedValue) else {
            return nil
        }

        return value
    }

    private static func normalized(_ value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        return String(folded.filter { character in
            character.isLetter || character.isNumber
        })
    }
}

