import AppKit
import Foundation

/// Security-scoped bookmarks for Mac App Store sandbox (user-granted folders only).
enum SecurityScopedBookmarks {
    enum Key: String, CaseIterable {
        case cursorApplicationSupport
        case codexHome
        case kiroHome
        case cherryStudioSupport
        case musicLibrary

        var panelMessage: String {
            switch self {
            case .cursorApplicationSupport:
                return "选择 Cursor 的 Application Support 文件夹（通常在 Library/Application Support/Cursor）"
            case .codexHome:
                return "选择 Codex 主目录（通常是 ~/.codex）"
            case .kiroHome:
                return "选择 Kiro 数据目录（通常是 ~/.kiro）"
            case .cherryStudioSupport:
                return "选择 Cherry Studio 的 Application Support 文件夹"
            case .musicLibrary:
                return "选择本地音乐文件夹"
            }
        }

        var defaultsSuggestedPath: String? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .cursorApplicationSupport:
                return home
                    .appendingPathComponent("Library/Application Support/Cursor")
                    .path
            case .codexHome:
                return home.appendingPathComponent(".codex").path
            case .kiroHome:
                return home.appendingPathComponent(".kiro").path
            case .cherryStudioSupport:
                return home
                    .appendingPathComponent("Library/Application Support/CherryStudio")
                    .path
            case .musicLibrary:
                return home.appendingPathComponent("Music").path
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

    static func withAccess<T>(to key: Key, _ body: (URL) -> T?) -> T? {
        guard let url = resolvedURL(for: key) else { return nil }
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return body(url)
    }
}
