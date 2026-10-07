import AppKit
import Foundation

/// Security-scoped bookmarks for Mac App Store sandbox (user-granted folders only).
enum SecurityScopedBookmarks {
    enum Key: String, CaseIterable {
        case cursorApplicationSupport
        case cursorProjects
        case codexHome
        case kiroHome
        case kiroApplicationSupport
        case cherryStudioSupport
        case musicLibrary
        case netEaseStorage

        var panelMessage: String {
            switch self {
            case .cursorApplicationSupport:
                return "窗口已打开到 Cursor 的数据文件夹。直接点「授权访问」，用来显示上下文用量。"
            case .cursorProjects:
                return "窗口已打开到 Cursor 的 .cursor 文件夹。直接点「授权访问」，用来同步当前任务。"
            case .codexHome:
                return "窗口已打开到 Codex 的 .codex 文件夹。直接点「授权访问」，用来同步会话。"
            case .kiroHome:
                return "窗口已打开到 Kiro 的 .kiro 文件夹。直接点「授权访问」，用来同步当前任务。"
            case .kiroApplicationSupport:
                return "窗口已打开到 Kiro 的数据文件夹。直接点「授权访问」，用来显示额度。"
            case .cherryStudioSupport:
                return "窗口已打开到 Cherry Studio 的数据文件夹。直接点「授权访问」，用来同步当前任务。"
            case .musicLibrary:
                return "窗口已打开到音乐文件夹。直接点「授权访问」，用来扫描本地歌曲，以及播放网易云已下载的 mp3 / m4a / flac。"
            case .netEaseStorage:
                return "窗口已打开到网易云的 storage 文件夹。直接点「授权访问」，用来显示正在播放的歌曲和歌单。"
            }
        }

        var defaultsSuggestedPath: String? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .cursorApplicationSupport:
                return home
                    .appendingPathComponent("Library/Application Support/Cursor")
                    .path
            case .cursorProjects:
                return home.appendingPathComponent(".cursor").path
            case .codexHome:
                return home.appendingPathComponent(".codex").path
            case .kiroHome:
                return home.appendingPathComponent(".kiro").path
            case .kiroApplicationSupport:
                return home
                    .appendingPathComponent("Library/Application Support/Kiro")
                    .path
            case .cherryStudioSupport:
                return home
                    .appendingPathComponent("Library/Application Support/CherryStudio")
                    .path
            case .musicLibrary:
                return home.appendingPathComponent("Music").path
            case .netEaseStorage:
                return home
                    .appendingPathComponent("Library/Application Support/com.netease.163music/Documents/storage")
                    .path
            }
        }
    }

    private static let defaultsPrefix = "LumaBar.scopedBookmark."

    static func hasBookmark(for key: Key) -> Bool {
        UserDefaults.standard.data(forKey: defaultsPrefix + key.rawValue) != nil
    }

    static func clearBookmark(for key: Key) {
        UserDefaults.standard.removeObject(forKey: defaultsPrefix + key.rawValue)
    }

    @MainActor
    @discardableResult
    static func promptAndStore(for key: Key) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "授权访问"
        panel.message = key.panelMessage
        panel.showsHiddenFiles = true
        if let suggested = key.defaultsSuggestedPath {
            panel.directoryURL = URL(fileURLWithPath: suggested)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        store(url: url, for: key)
        return url
    }

    static func store(url: URL, for key: Key) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: defaultsPrefix + key.rawValue)
        } catch {
            NSLog("LumaBar bookmark store failed: \(error.localizedDescription)")
        }
    }

    /// Resolve bookmark and begin security-scoped access. Caller must end access when done
    /// if using the returning URL for extended work — prefer `withAccess`.
    static func resolvedURL(for key: Key) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsPrefix + key.rawValue) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale {
            store(url: url, for: key)
        }
        return url
    }

    private static let retainLock = NSLock()
    nonisolated(unsafe) private static var retainedURLs: [String: URL] = [:]

    /// Keep the security scope for the process lifetime. Stopping it before a later
    /// file or SQLite read makes the sandbox deny access to the returned URL.
    static func retainedURL(for key: Key) -> URL? {
        retainLock.lock()
        if let existing = retainedURLs[key.rawValue] {
            retainLock.unlock()
            return existing
        }
        retainLock.unlock()

        guard let url = resolvedURL(for: key) else {
            if hasBookmark(for: key) { clearBookmark(for: key) }
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            clearBookmark(for: key)
            return nil
        }

        retainLock.lock()
        retainedURLs[key.rawValue] = url
        retainLock.unlock()
        return url
    }

    static func withAccess<T>(to key: Key, _ body: (URL) -> T?) -> T? {
        guard let url = resolvedURL(for: key) else {
            if hasBookmark(for: key) { clearBookmark(for: key) }
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            clearBookmark(for: key)
            return nil
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return body(url)
    }
}
