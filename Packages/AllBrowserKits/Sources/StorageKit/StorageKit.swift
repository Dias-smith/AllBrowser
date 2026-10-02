import Foundation

public enum AppPaths {
    public static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    public static var appSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AllBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var webImageCache: URL {
        let url = caches.appendingPathComponent("WebImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var youtubeTemp: URL {
        let url = caches.appendingPathComponent("StreamTemp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var downloads: URL {
        let url = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var importedFiles: URL {
        let url = documents.appendingPathComponent("Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public final class JSONStore<T: Codable> {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public init(filename: String, directory: URL = AppPaths.appSupport) {
        self.fileURL = directory.appendingPathComponent(filename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load(default defaultValue: T) -> T {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return defaultValue
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(T.self, from: data)
        } catch {
            return defaultValue
        }
    }

    public func save(_ value: T) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: [.atomic])
    }
}

public struct AppSettings: Codable, Equatable {
    public var adBlockEnabled: Bool
    public var appLockEnabled: Bool
    public var lockOnBackground: Bool
    public var lockGraceSeconds: Int
    public var youtubeEnhancedPlayback: Bool
    /// When true, opening a watch/shorts URL launches the local player.
    public var youtubeOpenInLocalPlayer: Bool
    public var youtubeCacheTTLHours: Int
    public var youtubeCacheMaxBytes: Int64
    public var searchEngineURLTemplate: String
    public var desktopModeDefault: Bool

    public static let `default` = AppSettings(
        adBlockEnabled: true,
        appLockEnabled: false,
        lockOnBackground: true,
        lockGraceSeconds: 0,
        youtubeEnhancedPlayback: true,
        youtubeOpenInLocalPlayer: false,
        youtubeCacheTTLHours: 48,
        youtubeCacheMaxBytes: 1_073_741_824,
        searchEngineURLTemplate: "https://duckduckgo.com/?q=%@",
        desktopModeDefault: false
    )

    public init(
        adBlockEnabled: Bool,
        appLockEnabled: Bool,
        lockOnBackground: Bool,
        lockGraceSeconds: Int,
        youtubeEnhancedPlayback: Bool,
        youtubeOpenInLocalPlayer: Bool = false,
        youtubeCacheTTLHours: Int,
        youtubeCacheMaxBytes: Int64,
        searchEngineURLTemplate: String,
        desktopModeDefault: Bool
    ) {
        self.adBlockEnabled = adBlockEnabled
        self.appLockEnabled = appLockEnabled
        self.lockOnBackground = lockOnBackground
        self.lockGraceSeconds = lockGraceSeconds
        self.youtubeEnhancedPlayback = youtubeEnhancedPlayback
        self.youtubeOpenInLocalPlayer = youtubeOpenInLocalPlayer
        self.youtubeCacheTTLHours = youtubeCacheTTLHours
        self.youtubeCacheMaxBytes = youtubeCacheMaxBytes
        self.searchEngineURLTemplate = searchEngineURLTemplate
        self.desktopModeDefault = desktopModeDefault
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        adBlockEnabled = try c.decodeIfPresent(Bool.self, forKey: .adBlockEnabled) ?? d.adBlockEnabled
        appLockEnabled = try c.decodeIfPresent(Bool.self, forKey: .appLockEnabled) ?? d.appLockEnabled
        lockOnBackground = try c.decodeIfPresent(Bool.self, forKey: .lockOnBackground) ?? d.lockOnBackground
        lockGraceSeconds = try c.decodeIfPresent(Int.self, forKey: .lockGraceSeconds) ?? d.lockGraceSeconds
        youtubeEnhancedPlayback = try c.decodeIfPresent(Bool.self, forKey: .youtubeEnhancedPlayback) ?? d.youtubeEnhancedPlayback
        youtubeOpenInLocalPlayer = try c.decodeIfPresent(Bool.self, forKey: .youtubeOpenInLocalPlayer) ?? d.youtubeOpenInLocalPlayer
        youtubeCacheTTLHours = try c.decodeIfPresent(Int.self, forKey: .youtubeCacheTTLHours) ?? d.youtubeCacheTTLHours
        youtubeCacheMaxBytes = try c.decodeIfPresent(Int64.self, forKey: .youtubeCacheMaxBytes) ?? d.youtubeCacheMaxBytes
        searchEngineURLTemplate = try c.decodeIfPresent(String.self, forKey: .searchEngineURLTemplate) ?? d.searchEngineURLTemplate
        desktopModeDefault = try c.decodeIfPresent(Bool.self, forKey: .desktopModeDefault) ?? d.desktopModeDefault
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public private(set) var settings: AppSettings
    private let store = JSONStore<AppSettings>(filename: "settings.json")

    public init() {
        settings = store.load(default: .default)
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
        try? store.save(copy)
    }
}

public struct BookmarkItem: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    public var urlString: String
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, urlString: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.createdAt = createdAt
    }
}

public struct HistoryItem: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    public var urlString: String
    public var visitedAt: Date

    public init(id: UUID = UUID(), title: String, urlString: String, visitedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.visitedAt = visitedAt
    }
}

@MainActor
public final class BookmarkStore: ObservableObject {
    @Published public private(set) var items: [BookmarkItem] = []
    private let store = JSONStore<[BookmarkItem]>(filename: "bookmarks.json")

    public init() {
        items = store.load(default: [])
    }

    public func add(title: String, urlString: String) {
        let item = BookmarkItem(title: title, urlString: urlString)
        items.insert(item, at: 0)
        try? store.save(items)
    }

    public func remove(id: UUID) {
        items.removeAll { $0.id == id }
        try? store.save(items)
    }
}

@MainActor
public final class HistoryStore: ObservableObject {
    @Published public private(set) var items: [HistoryItem] = []
    private let store = JSONStore<[HistoryItem]>(filename: "history.json")
    private let maxCount = 500

    public init() {
        items = store.load(default: [])
    }

    public func record(title: String, urlString: String) {
        items.removeAll { $0.urlString == urlString }
        items.insert(HistoryItem(title: title, urlString: urlString), at: 0)
        if items.count > maxCount {
            items = Array(items.prefix(maxCount))
        }
        try? store.save(items)
    }

    public func clear() {
        items = []
        try? store.save(items)
    }
}

public enum ByteFormat {
    public static func string(from bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
