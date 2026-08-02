import Foundation

enum NetEaseFavoriteError: LocalizedError {
    case notLoggedIn
    case missingSongID
    case missingPlaylist
    case apiFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "请先打开并登录网易云客户端。"
        case .missingSongID:
            return "无法识别这首网易云歌曲。"
        case .missingPlaylist:
            return "找不到可写入的网易云歌单。"
        case .apiFailed(let message):
            return message
        }
    }
}

enum NetEaseFavoriteController {
    private static let likedPlaylistDefaultsKey = "luma.netEase.likedPlaylistID"
    private static let cookieBundleCandidates = [
        "com.netease.163music",
        "com.netease.uumac"
    ]

    struct SessionCookies {
        let musicU: String
        let csrf: String

        var headerValue: String {
            var parts = ["MUSIC_U=\(musicU)"]
            if !csrf.isEmpty {
                parts.append("__csrf=\(csrf)")
            }
            return parts.joined(separator: "; ")
        }
    }

    static func loadSessionCookies() -> SessionCookies? {
#if LUMA_APP_STORE
        // Sandbox: do not probe other apps' HTTPStorages / cookie jars.
        return nil
#else
        for bundleID in cookieBundleCandidates {
            let path = binaryCookiesURL(bundleID: bundleID)
            guard FileManager.default.fileExists(atPath: path.path),
                  let cookies = parseBinaryCookies(at: path)
            else {
                continue
            }
            guard let musicU = cookies["MUSIC_U"], !musicU.isEmpty else { continue }
            return SessionCookies(musicU: musicU, csrf: cookies["__csrf"] ?? "")
        }
        return nil
#endif
    }

    /// Add song to `playlistID`, or to「我喜欢的音乐」when `playlistID` is nil.
    static func addSong(songID: String, playlistID: String?) async throws -> String {
        let trimmedSong = songID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSong.isEmpty else { throw NetEaseFavoriteError.missingSongID }
        guard let session = loadSessionCookies() else { throw NetEaseFavoriteError.notLoggedIn }

        let targetPlaylistID: String
        let playlistLabel: String
        if let playlistID, !playlistID.isEmpty {
            targetPlaylistID = playlistID
            playlistLabel = "当前歌单"
        } else {
            let liked = try await resolveLikedPlaylistID(session: session)
            targetPlaylistID = liked.id
            playlistLabel = liked.name
        }

        try await manipulatePlaylistTracks(
            op: "add",
            playlistID: targetPlaylistID,
            songID: trimmedSong,
            session: session
        )
        return playlistLabel
    }

    static func removeSong(songID: String, playlistID: String?) async throws {
        let trimmedSong = songID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSong.isEmpty else { throw NetEaseFavoriteError.missingSongID }
        guard let session = loadSessionCookies() else { throw NetEaseFavoriteError.notLoggedIn }

        let targetPlaylistID: String
        if let playlistID, !playlistID.isEmpty {
            targetPlaylistID = playlistID
        } else {
            targetPlaylistID = try await resolveLikedPlaylistID(session: session).id
        }

        try await manipulatePlaylistTracks(
            op: "del",
            playlistID: targetPlaylistID,
            songID: trimmedSong,
            session: session
        )
    }

    private static func resolveLikedPlaylistID(session: SessionCookies) async throws -> (id: String, name: String) {
        if let cached = UserDefaults.standard.string(forKey: likedPlaylistDefaultsKey), !cached.isEmpty {
            return (cached, "我喜欢的音乐")
        }

        let accountURL = URL(string: "https://music.163.com/api/nuser/account/get?csrf_token=\(session.csrf)")!
        let accountData = try await performRequest(url: accountURL, method: "GET", body: nil, session: session)
        guard let accountRoot = try JSONSerialization.jsonObject(with: accountData) as? [String: Any] else {
            throw NetEaseFavoriteError.apiFailed("读取网易云账号失败。")
        }
        let uid: Int? = {
            if let account = accountRoot["account"] as? [String: Any], let id = account["id"] as? Int {
                return id
            }
            if let profile = accountRoot["profile"] as? [String: Any], let id = profile["userId"] as? Int {
                return id
            }
            return nil
        }()
        guard let uid else { throw NetEaseFavoriteError.notLoggedIn }

        var components = URLComponents(string: "https://music.163.com/api/user/playlist")!
        components.queryItems = [
            URLQueryItem(name: "uid", value: "\(uid)"),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "csrf_token", value: session.csrf)
        ]
        let playlistData = try await performRequest(url: components.url!, method: "GET", body: nil, session: session)
        guard let root = try JSONSerialization.jsonObject(with: playlistData) as? [String: Any],
              let playlists = root["playlist"] as? [[String: Any]]
        else {
            throw NetEaseFavoriteError.missingPlaylist
        }

        let liked = playlists.first {
            ($0["specialType"] as? Int) == 5
                || (($0["name"] as? String)?.contains("喜欢的音乐") == true)
        }
        guard let liked,
              let idValue = liked["id"],
              let name = liked["name"] as? String
        else {
            throw NetEaseFavoriteError.missingPlaylist
        }
        let id = "\(idValue)"
        UserDefaults.standard.set(id, forKey: likedPlaylistDefaultsKey)
        return (id, name)
    }

    private static func manipulatePlaylistTracks(
        op: String,
        playlistID: String,
        songID: String,
        session: SessionCookies
    ) async throws {
        var components = URLComponents(string: "https://music.163.com/api/playlist/manipulate/tracks")!
        components.queryItems = [URLQueryItem(name: "csrf_token", value: session.csrf)]
        guard let url = components.url else {
            throw NetEaseFavoriteError.apiFailed("无法构造网易云请求。")
        }

        let bodyItems: [URLQueryItem] = [
            URLQueryItem(name: "op", value: op),
            URLQueryItem(name: "pid", value: playlistID),
            URLQueryItem(name: "trackIds", value: "[\(songID)]"),
            URLQueryItem(name: "imme", value: "true"),
            URLQueryItem(name: "csrf_token", value: session.csrf)
        ]
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = bodyItems
        let body = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let data = try await performRequest(url: url, method: "POST", body: body, session: session)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetEaseFavoriteError.apiFailed("网易云返回异常。")
        }
        let code = root["code"] as? Int ?? -1
        guard code == 200 else {
            let message = (root["message"] as? String)
                ?? (root["msg"] as? String)
                ?? "网易云收藏失败（\(code)）"
            throw NetEaseFavoriteError.apiFailed(message)
        }
    }

    private static func performRequest(
        url: URL,
        method: String,
        body: Data?,
        session: SessionCookies
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.httpBody = body
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(session.headerValue, forHTTPHeaderField: "Cookie")
        if body != nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NetEaseFavoriteError.apiFailed("网易云网络异常。")
        }
        guard (200..<300).contains(http.statusCode) || !data.isEmpty else {
            throw NetEaseFavoriteError.apiFailed("网易云请求失败（\(http.statusCode)）")
        }
        return data
    }

    private static func binaryCookiesURL(bundleID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("HTTPStorages", isDirectory: true)
            .appendingPathComponent("\(bundleID).binarycookies", isDirectory: false)
    }

    /// Parse Apple/Netscape binarycookies and return name→value map (last write wins).
    private static func parseBinaryCookies(at url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url), data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        guard String(bytes: bytes.prefix(4), encoding: .ascii) == "cook" else { return nil }

        func beInt32(_ offset: Int) -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            return (Int(bytes[offset]) << 24)
                | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8)
                | Int(bytes[offset + 3])
        }

        func leInt32(_ slice: ArraySlice<UInt8>, _ offset: Int) -> Int? {
            let i = slice.startIndex + offset
            guard i + 3 < slice.endIndex else { return nil }
            return Int(slice[i])
                | (Int(slice[i + 1]) << 8)
                | (Int(slice[i + 2]) << 16)
                | (Int(slice[i + 3]) << 24)
        }

        func cString(_ slice: ArraySlice<UInt8>, _ offset: Int) -> String? {
            let start = slice.startIndex + offset
            guard start < slice.endIndex else { return nil }
            var end = start
            while end < slice.endIndex, slice[end] != 0 {
                end += 1
            }
            return String(bytes: slice[start..<end], encoding: .utf8)
        }

        guard let pageCount = beInt32(4), pageCount > 0 else { return nil }
        var pageSizes: [Int] = []
        pageSizes.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            guard let size = beInt32(8 + index * 4), size > 0 else { return nil }
            pageSizes.append(size)
        }

        var cursor = 8 + pageCount * 4
        var cookies: [String: String] = [:]
        for pageSize in pageSizes {
            guard cursor + pageSize <= bytes.count else { break }
            let page = bytes[cursor..<(cursor + pageSize)]
            cursor += pageSize
            guard page.count >= 8,
                  page[page.startIndex] == 0,
                  page[page.startIndex + 1] == 0,
                  page[page.startIndex + 2] == 1,
                  page[page.startIndex + 3] == 0,
                  let cookieCount = leInt32(page, 4),
                  cookieCount > 0
            else {
                continue
            }

            var offsets: [Int] = []
            offsets.reserveCapacity(cookieCount)
            for index in 0..<cookieCount {
                guard let offset = leInt32(page, 8 + index * 4) else { break }
                offsets.append(offset)
            }

            for offset in offsets {
                guard offset >= 0, page.startIndex + offset < page.endIndex else { continue }
                let cookie = page[(page.startIndex + offset)...]
                guard let nameOffset = leInt32(cookie, 20),
                      let valueOffset = leInt32(cookie, 28),
                      let name = cString(cookie, nameOffset),
                      let value = cString(cookie, valueOffset),
                      !name.isEmpty
                else {
                    continue
                }
                cookies[name] = value
            }
        }
        return cookies.isEmpty ? nil : cookies
    }
}
