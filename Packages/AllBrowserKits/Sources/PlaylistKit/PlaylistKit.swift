import Foundation
import MediaKit
import StorageKit

public struct Playlist: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var coverURL: URL?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        coverURL: URL? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PlaylistEntry: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var playlistID: UUID
    public var title: String
    public var artist: String
    public var sourceURLString: String
    public var youtubeVideoID: String?
    public var artworkURLString: String?
    public var duration: TimeInterval?
    public var sortIndex: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        playlistID: UUID,
        title: String,
        artist: String = "",
        sourceURLString: String,
        youtubeVideoID: String? = nil,
        artworkURLString: String? = nil,
        duration: TimeInterval? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.playlistID = playlistID
        self.title = title
        self.artist = artist
        self.sourceURLString = sourceURLString
        self.youtubeVideoID = youtubeVideoID
        self.artworkURLString = artworkURLString
        self.duration = duration
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }

    public func asMediaItem() -> MediaItem? {
        guard let url = URL(string: sourceURLString) else { return nil }
        return MediaItem(
            id: id,
            title: title,
            artist: artist,
            artworkURL: artworkURLString.flatMap(URL.init(string:)),
            sourceURL: url,
            duration: duration
        )
    }
}

private struct PlaylistDatabase: Codable, Equatable {
    var playlists: [Playlist]
    var entries: [PlaylistEntry]
}

@MainActor
public final class PlaylistStore: ObservableObject {
    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var entries: [PlaylistEntry] = []

    private let store = JSONStore<PlaylistDatabase>(filename: "playlists.json")

    public init() {
        let db = store.load(default: PlaylistDatabase(playlists: [], entries: []))
        playlists = db.playlists
        entries = db.entries
        if playlists.isEmpty {
            _ = createPlaylist(name: "我喜欢")
        }
    }

    public func createPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        playlists.insert(playlist, at: 0)
        persist()
        return playlist
    }

    public func renamePlaylist(id: UUID, name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
        playlists[index].updatedAt = Date()
        persist()
    }

    public func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
        entries.removeAll { $0.playlistID == id }
        persist()
    }

    public func entries(in playlistID: UUID) -> [PlaylistEntry] {
        entries.filter { $0.playlistID == playlistID }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public func addEntry(
        playlistID: UUID,
        title: String,
        artist: String = "",
        sourceURLString: String,
        youtubeVideoID: String? = nil,
        artworkURLString: String? = nil,
        duration: TimeInterval? = nil
    ) {
        let sortIndex = entries(in: playlistID).count
        let entry = PlaylistEntry(
            playlistID: playlistID,
            title: title,
            artist: artist,
            sourceURLString: sourceURLString,
            youtubeVideoID: youtubeVideoID,
            artworkURLString: artworkURLString,
            duration: duration,
            sortIndex: sortIndex
        )
        entries.append(entry)
        if let index = playlists.firstIndex(where: { $0.id == playlistID }) {
            playlists[index].updatedAt = Date()
        }
        persist()
    }

    public func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        try? store.save(PlaylistDatabase(playlists: playlists, entries: entries))
    }
}
