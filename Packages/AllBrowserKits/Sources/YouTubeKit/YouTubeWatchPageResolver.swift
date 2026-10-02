import Foundation
import WebKit

/// Shared helpers for turning a YouTube player response JSON object into `YouTubeVideoInfo`.
public enum YouTubePlayerResponseMapper {
    /// Parses a JSON string of `ytInitialPlayerResponse` into playable video info.
    public static func videoInfo(videoID: String, playerJSON: String) throws -> YouTubeVideoInfo {
        guard let player = parseJSONObject(playerJSON) else {
            throw YouTubeJSExtractorError.invalidPayload
        }
        return try videoInfo(videoID: videoID, player: player)
    }

    public static func videoInfo(
        videoID: String,
        title: String = "YouTube",
        author: String = "",
        thumbnailURL: URL? = nil,
        streamURL: URL
    ) -> YouTubeVideoInfo {
        YouTubeVideoInfo(
            videoID: videoID,
            title: title,
            author: author,
            thumbnailURL: thumbnailURL,
            streamURL: streamURL,
            usesEmbedFallback: false
        )
    }

    static func videoInfo(videoID: String, player: [String: Any]) throws -> YouTubeVideoInfo {
        let playability = player["playabilityStatus"] as? [String: Any]
        if let st = playability?["status"] as? String, st != "OK" {
            let reason = (playability?["reason"] as? String) ?? st
            YouTubeLog.info("PlayerResponse status=\(st) reason=\(reason)")
            // Still allow HLS / formats if present (some challenge pages keep partial data).
            let streaming = player["streamingData"] as? [String: Any] ?? [:]
            let hasStream = streaming["hlsManifestUrl"] != nil
                || ((streaming["formats"] as? [Any])?.isEmpty == false)
                || ((streaming["adaptiveFormats"] as? [Any])?.isEmpty == false)
            if !hasStream {
                throw YouTubeJSExtractorError.message(reason)
            }
        }

        let details = player["videoDetails"] as? [String: Any]
        let title = (details?["title"] as? String) ?? "YouTube"
        let author = (details?["author"] as? String) ?? ""
        let thumbs = ((details?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
        let thumbURL = thumbs.compactMap { $0["url"] as? String }.last.flatMap(URL.init(string:))

        let streaming = player["streamingData"] as? [String: Any] ?? [:]
        if let hls = streaming["hlsManifestUrl"] as? String, let hlsURL = URL(string: hls) {
            return YouTubeVideoInfo(
                videoID: videoID,
                title: title,
                author: author,
                thumbnailURL: thumbURL,
                streamURL: hlsURL,
                usesEmbedFallback: false
            )
        }

        var formats = (streaming["formats"] as? [[String: Any]]) ?? []
        formats += (streaming["adaptiveFormats"] as? [[String: Any]]) ?? []

        guard let streamURL = YouTubeFormatPicker.bestPlayableURL(from: formats) else {
            let withURL = formats.filter { ($0["url"] as? String)?.isEmpty == false }.count
            let withCipher = formats.filter {
                ($0["signatureCipher"] as? String)?.isEmpty == false || ($0["cipher"] as? String)?.isEmpty == false
            }.count
            YouTubeLog.error(
                "PlayerResponse no playable URL formats=\(formats.count) withURL=\(withURL) withCipher=\(withCipher) hls=\(streaming["hlsManifestUrl"] != nil)"
            )
            throw YouTubeJSExtractorError.noPlayableURL
        }

        return YouTubeVideoInfo(
            videoID: videoID,
            title: title,
            author: author,
            thumbnailURL: thumbURL,
            streamURL: streamURL,
            usesEmbedFallback: false
        )
    }

    static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Fetches watch HTML via URLSession. Secondary path when the live browser tab
/// did not already expose a stream URL.
public struct YouTubeWatchPageResolver: StreamResolving {
    public init() {}

    public func resolve(videoID: String) async throws -> YouTubeVideoInfo {
        YouTubeLog.info("WatchPageResolver start \(videoID)")
        let urls = [
            "https://m.youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1",
            "https://www.youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1",
        ]
        var lastError: Error = YouTubeJSExtractorError.extractFailed

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            do {
                YouTubeLog.info("WatchPageResolver fetch \(url.host ?? "")")
                if let info = try await fetchWatchPage(url: url, videoID: videoID) {
                    YouTubeLog.info("WatchPageResolver OK url=\(YouTubeLog.truncate(info.streamURL?.absoluteString))")
                    return info
                }
                YouTubeLog.info("WatchPageResolver empty response \(url.host ?? "")")
            } catch {
                YouTubeLog.error("WatchPageResolver fail \(url.host ?? "")", error: error)
                lastError = error
            }
        }
        throw lastError
    }

    private func fetchWatchPage(url: URL, videoID: String) async throws -> YouTubeVideoInfo? {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<400).contains(status),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        guard let player = Self.extractPlayerResponse(from: html) else {
            let bot = html.localizedCaseInsensitiveContains("Sign in to confirm")
                || html.localizedCaseInsensitiveContains("not a bot")
            YouTubeLog.error("WatchPageResolver no player JSON bytes=\(html.count) bot=\(bot)")
            throw YouTubeJSExtractorError.message("Player response not found in watch page.")
        }
        return try YouTubePlayerResponseMapper.videoInfo(videoID: videoID, player: player)
    }

    static func extractPlayerResponse(from html: String) -> [String: Any]? {
        if let markerRange = html.range(of: "ytInitialPlayerResponse") {
            let after = html[markerRange.upperBound...]
            if let eq = after.firstIndex(of: "="),
               let start = after[eq...].firstIndex(of: "{"),
               let blob = extractJSONObject(from: html, start: start),
               let obj = YouTubePlayerResponseMapper.parseJSONObject(blob),
               obj["streamingData"] != nil || obj["videoDetails"] != nil {
                return obj
            }
        }

        let needle = "\"playabilityStatus\":{\"status\":\"OK\""
        if let hit = html.range(of: needle) {
            return nearestPlayerObject(in: html, around: hit.lowerBound)
        }
        if let any = html.range(of: "\"playabilityStatus\"") {
            return nearestPlayerObject(in: html, around: any.lowerBound)
        }
        return nil
    }

    private static func nearestPlayerObject(in html: String, around index: String.Index) -> [String: Any]? {
        let prefix = html[..<index]
        if let ctx = prefix.range(of: "{\"responseContext\"", options: .backwards)?.lowerBound,
           let blob = extractJSONObject(from: html, start: ctx),
           let obj = YouTubePlayerResponseMapper.parseJSONObject(blob),
           obj["streamingData"] != nil {
            return obj
        }

        var i = index
        var attempts = 0
        while attempts < 40, i > html.startIndex {
            if html[i] == "{" {
                if let blob = extractJSONObject(from: html, start: i),
                   let obj = YouTubePlayerResponseMapper.parseJSONObject(blob),
                   obj["streamingData"] != nil {
                    return obj
                }
                attempts += 1
            }
            i = html.index(before: i)
        }
        return nil
    }

    static func extractJSONObject(from source: String, start: String.Index) -> String? {
        var i = start
        var depth = 0
        var inString = false
        var escaped = false

        while i < source.endIndex {
            let ch = source[i]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(source[start...i])
                    }
                }
            }
            i = source.index(after: i)
        }
        return nil
    }
}
