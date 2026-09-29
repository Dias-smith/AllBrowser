import Foundation
import AVFoundation
import MediaKit
import StorageKit
import WebKit
import SwiftUI

public enum YouTubeURLDetector {
    public static func videoID(from rawURL: URL) -> String? {
        videoID(from: rawURL.absoluteString)
    }

    public static func videoID(from string: String) -> String? {
        guard let url = URL(string: string) else {
            return matchShortPatterns(string)
        }
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtu.be") {
            let id = url.pathTrimmingSlashes
            return sanitize(id)
        }
        if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value {
                return sanitize(v)
            }
            let parts = url.path.split(separator: "/").map(String.init)
            if let idx = parts.firstIndex(of: "embed"), parts.indices.contains(idx + 1) {
                return sanitize(parts[idx + 1])
            }
            if let idx = parts.firstIndex(of: "shorts"), parts.indices.contains(idx + 1) {
                return sanitize(parts[idx + 1])
            }
            if let idx = parts.firstIndex(of: "live"), parts.indices.contains(idx + 1) {
                return sanitize(parts[idx + 1])
            }
        }
        return matchShortPatterns(string)
    }

    private static func matchShortPatterns(_ string: String) -> String? {
        let pattern = #"(?:youtu\.be/|v=|/embed/|/shorts/)([A-Za-z0-9_-]{6,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let idRange = Range(match.range(at: 1), in: string) else { return nil }
        return sanitize(String(string[idRange]))
    }

    private static func sanitize(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: CharacterSet(charactersIn: "/?&"))
        guard trimmed.count >= 6, trimmed.count <= 20 else { return nil }
        return trimmed
    }
}

private extension URL {
    var pathTrimmingSlashes: String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public struct YouTubeVideoInfo: Equatable, Identifiable {
    public var id: String { videoID }
    public var videoID: String
    public var title: String
    public var author: String
    public var thumbnailURL: URL?
    public var streamURL: URL?
    public var usesEmbedFallback: Bool

    public init(
        videoID: String,
        title: String,
        author: String,
        thumbnailURL: URL? = nil,
        streamURL: URL? = nil,
        usesEmbedFallback: Bool = false
    ) {
        self.videoID = videoID
        self.title = title
        self.author = author
        self.thumbnailURL = thumbnailURL
        self.streamURL = streamURL
        self.usesEmbedFallback = usesEmbedFallback
    }
}

public struct YouTubeTempCacheEntry: Codable, Equatable, Identifiable {
    public var id: String
    public var videoID: String
    public var quality: String
    public var fileName: String
    public var byteCount: Int64
    public var createdAt: Date
    public var expiresAt: Date
    public var lastAccessedAt: Date
}

public protocol TemporaryCaching: AnyObject {
    func cachedFileURL(videoID: String, quality: String) -> URL?
    func store(data: Data, videoID: String, quality: String, ttlHours: Int) throws -> URL
    func touch(videoID: String, quality: String)
    func purgeExpired()
    func enforceCapacity(maxBytes: Int64)
    func purgeAll()
    var usageBytes: Int64 { get }
    var entries: [YouTubeTempCacheEntry] { get }
}

public final class TemporaryCacheStore: TemporaryCaching {
    private let indexStore = JSONStore<[YouTubeTempCacheEntry]>(filename: "youtube_temp_index.json")
    private var index: [YouTubeTempCacheEntry]
    private let fileManager = FileManager.default

    public init() {
        index = indexStore.load(default: [])
        purgeExpired()
    }

    public var entries: [YouTubeTempCacheEntry] { index }

    public var usageBytes: Int64 {
        index.reduce(0) { $0 + $1.byteCount }
    }

    public func cachedFileURL(videoID: String, quality: String) -> URL? {
        purgeExpired()
        guard let entry = index.first(where: { $0.videoID == videoID && $0.quality == quality }) else {
            return nil
        }
        let url = AppPaths.youtubeTemp.appendingPathComponent(entry.fileName)
        guard fileManager.fileExists(atPath: url.path) else {
            index.removeAll { $0.id == entry.id }
            persist()
            return nil
        }
        touch(videoID: videoID, quality: quality)
        return url
    }

    public func store(data: Data, videoID: String, quality: String, ttlHours: Int) throws -> URL {
        let fileName = "\(videoID)_\(quality)_\(UUID().uuidString.prefix(8)).tmp"
        let url = AppPaths.youtubeTemp.appendingPathComponent(fileName)
        try data.write(to: url, options: [.atomic])
        index.removeAll { $0.videoID == videoID && $0.quality == quality }
        let now = Date()
        let entry = YouTubeTempCacheEntry(
            id: UUID().uuidString,
            videoID: videoID,
            quality: quality,
            fileName: fileName,
            byteCount: Int64(data.count),
            createdAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(ttlHours * 3600)),
            lastAccessedAt: now
        )
        index.append(entry)
        persist()
        return url
    }

    public func touch(videoID: String, quality: String) {
        guard let idx = index.firstIndex(where: { $0.videoID == videoID && $0.quality == quality }) else { return }
        index[idx].lastAccessedAt = Date()
        persist()
    }

    public func purgeExpired() {
        let now = Date()
        let expired = index.filter { $0.expiresAt < now }
        for entry in expired {
            let url = AppPaths.youtubeTemp.appendingPathComponent(entry.fileName)
            try? fileManager.removeItem(at: url)
        }
        index.removeAll { $0.expiresAt < now }
        persist()
    }

    public func enforceCapacity(maxBytes: Int64) {
        purgeExpired()
        var total = usageBytes
        guard total > maxBytes else { return }
        let sorted = index.sorted { $0.lastAccessedAt < $1.lastAccessedAt }
        for entry in sorted {
            if total <= maxBytes { break }
            let url = AppPaths.youtubeTemp.appendingPathComponent(entry.fileName)
            try? fileManager.removeItem(at: url)
            total -= entry.byteCount
            index.removeAll { $0.id == entry.id }
        }
        persist()
    }

    public func purgeAll() {
        for entry in index {
            let url = AppPaths.youtubeTemp.appendingPathComponent(entry.fileName)
            try? fileManager.removeItem(at: url)
        }
        index = []
        persist()
        if let contents = try? fileManager.contentsOfDirectory(at: AppPaths.youtubeTemp, includingPropertiesForKeys: nil) {
            for url in contents {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func persist() {
        try? indexStore.save(index)
    }
}

public protocol StreamResolving {
    func resolve(videoID: String) async throws -> YouTubeVideoInfo
}

/// Resolves metadata via oEmbed. Direct media streams are not always available
/// without violating ToS; enhanced mode uses embed fallback when no stream URL.
public struct YouTubeOEmbedResolver: StreamResolving {
    public init() {}

    public func resolve(videoID: String) async throws -> YouTubeVideoInfo {
        let watchURL = "https://www.youtube.com/watch?v=\(videoID)"
        guard let oembed = URL(string: "https://www.youtube.com/oembed?url=\(watchURL)&format=json") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: oembed)
        struct OEmbed: Decodable {
            let title: String
            let author_name: String
            let thumbnail_url: String?
        }
        let decoded = try JSONDecoder().decode(OEmbed.self, from: data)
        return YouTubeVideoInfo(
            videoID: videoID,
            title: decoded.title,
            author: decoded.author_name,
            thumbnailURL: decoded.thumbnail_url.flatMap(URL.init(string:)),
            streamURL: nil,
            usesEmbedFallback: true
        )
    }
}

@MainActor
public final class YouTubePlaybackService: ObservableObject {
    @Published public private(set) var lastInfo: YouTubeVideoInfo?
    @Published public private(set) var isResolving = false
    @Published public private(set) var errorMessage: String?

    public let cache: TemporaryCaching
    private let resolver: StreamResolving
    private let settings: () -> AppSettings

    public init(
        cache: TemporaryCaching = TemporaryCacheStore(),
        resolver: StreamResolving = YouTubeOEmbedResolver(),
        settings: @escaping () -> AppSettings
    ) {
        self.cache = cache
        self.resolver = resolver
        self.settings = settings
    }

    public var isEnhancedEnabled: Bool {
        settings().youtubeEnhancedPlayback
    }

    public func prepare(videoID: String) async -> YouTubeVideoInfo? {
        isResolving = true
        errorMessage = nil
        defer { isResolving = false }
        do {
            var info = try await resolver.resolve(videoID: videoID)
            cache.purgeExpired()
            cache.enforceCapacity(maxBytes: settings().youtubeCacheMaxBytes)

            if let cached = cache.cachedFileURL(videoID: videoID, quality: "auto") {
                info.streamURL = cached
                info.usesEmbedFallback = false
            }

            // If a remote stream URL exists, warm temporary cache in background for seek resilience.
            if let streamURL = info.streamURL, streamURL.isFileURL == false {
                Task {
                    await warmCache(videoID: videoID, url: streamURL)
                }
            }

            if !isEnhancedEnabled {
                info.streamURL = nil
                info.usesEmbedFallback = true
            }

            lastInfo = info
            return info
        } catch {
            errorMessage = error.localizedDescription
            let fallback = YouTubeVideoInfo(
                videoID: videoID,
                title: "YouTube",
                author: "",
                usesEmbedFallback: true
            )
            lastInfo = fallback
            return fallback
        }
    }

    public func play(info: YouTubeVideoInfo, using playback: PlaybackController) {
        if let streamURL = info.streamURL {
            let item = MediaItem(
                title: info.title,
                artist: info.author,
                artworkURL: info.thumbnailURL,
                sourceURL: streamURL
            )
            playback.play(item)
        }
    }

    public func clearTemporaryCache() {
        cache.purgeAll()
    }

    public var cacheUsageBytes: Int64 { cache.usageBytes }

    private func warmCache(videoID: String, url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Only cache reasonably sized progressive media; skip huge live manifests.
            guard data.count < 80_000_000 else { return }
            _ = try cache.store(
                data: data,
                videoID: videoID,
                quality: "auto",
                ttlHours: settings().youtubeCacheTTLHours
            )
            cache.enforceCapacity(maxBytes: settings().youtubeCacheMaxBytes)
        } catch {}
    }
}

public struct YouTubeEmbedView: UIViewRepresentable {
    public let videoID: String

    public init(videoID: String) {
        self.videoID = videoID
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        load(into: webView)
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        load(into: uiView)
    }

    private func load(into webView: WKWebView) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
          html, body { margin:0; padding:0; background:#000; height:100%; }
          .wrap { position:fixed; inset:0; }
          iframe { width:100%; height:100%; border:0; }
        </style>
        </head>
        <body>
          <div class="wrap">
            <iframe
              src="https://www.youtube.com/embed/\(videoID)?playsinline=1&rel=0&modestbranding=1"
              allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
              allowfullscreen>
            </iframe>
          </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
    }
}
