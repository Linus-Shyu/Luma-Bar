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

struct LocalTrack: Identifiable, Hashable {
    let id: URL
    let url: URL
    let title: String
    let artist: String
    let album: String
    let artworkData: Data?
    let lyrics: String
    let timedLyrics: [TimedLyricLine]
    let playbackSource: TrackPlaybackSource

    var displayArtist: String {
        if artist.isEmpty {
            return LumaBarL10n.libraryLocalFile
        }
        return artist
    }

    var displaySubtitle: String {
        album.isEmpty ? displayArtist : "\(displayArtist) • \(album)"
    }

    var hasLyrics: Bool {
        !timedLyrics.isEmpty || !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func == (lhs: LocalTrack, rhs: LocalTrack) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct NetEasePlaylistRow: Decodable {
    let id: String
    let name: String
    let coverImgUrl: String?
    let trackCount: Int?
    let playtime: Int64?
}

struct NetEasePlaylistTrackRow: Decodable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let coverImgUrl: String?
    let localFilePath: String?
}

struct NetEaseOfflineTrackRow: Decodable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let localFilePath: String?
}

struct NetEaseLocalFileRow: Decodable {
    let id: String
    let localFilePath: String?
}

struct NetEaseOnlinePlaylistResponse: Decodable {
    let playlist: NetEaseOnlinePlaylist?
    let result: NetEaseOnlinePlaylist?

    var tracks: [NetEaseOnlineTrack] {
        playlist?.tracks ?? result?.tracks ?? []
    }
}

struct NetEaseOnlinePlaylist: Decodable {
    let tracks: [NetEaseOnlineTrack]?
}

struct NetEaseOnlineTrack: Decodable {
    let id: String
    let name: String?
    let artists: [NetEaseOnlineArtist]?
    let ar: [NetEaseOnlineArtist]?
    let album: NetEaseOnlineAlbum?
    let al: NetEaseOnlineAlbum?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case artists
        case ar
        case album
        case al
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else if let intID = try? container.decode(Int64.self, forKey: .id) {
            id = String(intID)
        } else {
            id = ""
        }
        name = try? container.decode(String.self, forKey: .name)
        artists = try? container.decode([NetEaseOnlineArtist].self, forKey: .artists)
        ar = try? container.decode([NetEaseOnlineArtist].self, forKey: .ar)
        album = try? container.decode(NetEaseOnlineAlbum.self, forKey: .album)
        al = try? container.decode(NetEaseOnlineAlbum.self, forKey: .al)
    }
}

struct NetEaseOnlineArtist: Decodable {
    let name: String?
}

struct NetEaseOnlineAlbum: Decodable {
    let name: String?
    let picUrl: String?
    let cover: String?
}

final class NetEaseResponseDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    func store(_ data: Data?) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func load() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Thread-safe cover URL memory for NetEase playlist rows (including never-played songs).
final class NetEaseTrackCoverURLCache: @unchecked Sendable {
    static let shared = NetEaseTrackCoverURLCache()
    private let lock = NSLock()
    private var urls: [String: URL] = [:]

    func store(_ url: URL, for id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        urls[trimmed] = url
        lock.unlock()
    }

    func url(for id: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return urls[id]
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [self[...]] }
        return stride(from: 0, to: count, by: size).map { startIndex in
            self[startIndex..<Swift.min(startIndex + size, count)]
        }
    }
}

struct NetEaseResolvedTrackRow: Decodable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let coverImgUrl: String?
}

struct NetEaseTrackMetadata: Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let coverURL: URL?
}
