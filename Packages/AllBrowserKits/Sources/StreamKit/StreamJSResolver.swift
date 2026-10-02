import Foundation

/// Tries JS stream extraction first, then native Innertube, then oEmbed metadata.
public struct YouTubeChainedResolver: StreamResolving {
    private let resolvers: [StreamResolving]

    public init(
        resolvers: [StreamResolving] = [
            // YTLite fast path: ANDROID + signatureTimestamp → plain googlevideo URLs.
            YouTubeAndroidPlayerResolver(),
            YouTubeJSStreamResolver(),
            YouTubeWatchPageResolver(),
            YouTubeInnertubeResolver(),
        ]
    ) {
        self.resolvers = resolvers
    }

    public func resolve(videoID: String) async throws -> YouTubeVideoInfo {
        YouTubeLog.info("ChainedResolver start videoID=\(videoID) resolvers=\(resolvers.count)")
        var lastError: Error = YouTubeJSExtractorError.extractFailed

        for resolver in resolvers {
            let name = String(describing: type(of: resolver))
            do {
                YouTubeLog.info("Trying resolver \(name)")
                let info = try await resolver.resolve(videoID: videoID)
                if let url = info.streamURL {
                    YouTubeLog.info("Resolver \(name) OK title=\(info.title) url=\(YouTubeLog.truncate(url.absoluteString))")
                    return info
                }
                YouTubeLog.info("Resolver \(name) returned no streamURL (embed/fallback)")
            } catch {
                YouTubeLog.error("Resolver \(name) failed", error: error)
                lastError = error
            }
        }

        YouTubeLog.error("ChainedResolver exhausted for \(videoID)", error: lastError)
        throw lastError
    }
}

/// Resolves YouTube watch URLs to progressive stream URLs via bundled `resolution.js`.
public struct YouTubeJSStreamResolver: StreamResolving {
    public init() {}

    public func resolve(videoID: String) async throws -> YouTubeVideoInfo {
        let watchURL = "https://www.youtube.com/watch?v=\(videoID)"
        YouTubeLog.info("JSStreamResolver extract \(watchURL)")
        let payload = try await YouTubeJSExtractor.shared.extract(watchURL: watchURL)
        YouTubeLog.info("JSStreamResolver payload keys=\(Array(payload.keys).sorted())")

        let music = payload["music"] as? [String: Any]
        guard let music else {
            YouTubeLog.error("JSStreamResolver missing music key payload=\(YouTubeLog.truncate(String(describing: payload), limit: 300))")
            throw YouTubeJSExtractorError.extractFailed
        }

        let title = (music["title"] as? String)?.nilIfEmpty ?? "YouTube"
        let author = (music["uploader"] as? String)?.nilIfEmpty
            ?? (music["author"] as? String)?.nilIfEmpty
            ?? ""
        let thumbURL = Self.bestThumbnail(from: music["thumbnails"])
        let formats = (music["formats"] as? [[String: Any]]) ?? []
        YouTubeLog.info("JSStreamResolver music title=\(title) formats=\(formats.count)")

        guard let streamURL = YouTubeFormatPicker.bestPlayableURL(from: formats) else {
            let sample = formats.prefix(3).map { fmt -> String in
                let itag = fmt["itag"] ?? "?"
                let hasURL = (fmt["url"] as? String)?.isEmpty == false
                let cipher = (fmt["signatureCipher"] as? String)?.isEmpty == false
                    || (fmt["cipher"] as? String)?.isEmpty == false
                return "itag=\(itag) url=\(hasURL) cipher=\(cipher)"
            }
            YouTubeLog.error("JSStreamResolver no playable URL sample=\(sample)")
            throw YouTubeJSExtractorError.noPlayableURL
        }

        YouTubeLog.info("JSStreamResolver picked \(YouTubeLog.truncate(streamURL.absoluteString))")
        return YouTubeVideoInfo(
            videoID: videoID,
            title: title,
            author: author,
            thumbnailURL: thumbURL,
            streamURL: streamURL,
            usesEmbedFallback: false
        )
    }

    private static func bestThumbnail(from raw: Any?) -> URL? {
        guard let list = raw as? [[String: Any]] else { return nil }
        let sorted = list.sorted { lhs, rhs in
            let lh = (lhs["height"] as? Int) ?? 0
            let rh = (rhs["height"] as? Int) ?? 0
            return lh > rh
        }
        guard let urlString = sorted.first?["url"] as? String else { return nil }
        return URL(string: urlString)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
