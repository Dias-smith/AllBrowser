import Foundation

/// YTLite-style ANDROID Innertube player fallback.
/// Uses `signatureTimestamp` so the player returns plain `url` formats (no signatureCipher / nsig).
public struct AndroidPlayerResolver: StreamResolving {
    /// Match YTLite `ResolverRemoteConfig.defaults`.
    public static let defaultClientVersion = "20.10.38"
    public static let defaultSignatureTimestamp = 20_646

    private let clientVersion: String
    private let fallbackSTS: Int

    public init(
        clientVersion: String = AndroidPlayerResolver.defaultClientVersion,
        signatureTimestamp: Int = AndroidPlayerResolver.defaultSignatureTimestamp
    ) {
        self.clientVersion = clientVersion
        self.fallbackSTS = signatureTimestamp
    }

    public func resolve(videoID: String) async throws -> StreamVideoInfo {
        StreamLog.info("AndroidPlayerResolver start \(videoID) ver=\(clientVersion)")
        var sts = fallbackSTS
        if let scraped = await Self.scrapeSignatureTimestamp(videoID: videoID) {
            sts = scraped
            StreamLog.info("AndroidPlayerResolver scraped STS=\(sts)")
        } else {
            StreamLog.info("AndroidPlayerResolver using default STS=\(sts)")
        }

        if let info = try await fetchAndroidPlayer(videoID: videoID, signatureTimestamp: sts) {
            StreamLog.info(
                "AndroidPlayerResolver OK title=\(info.title) url=\(StreamLog.truncate(info.streamURL?.absoluteString))"
            )
            return info
        }
        throw StreamJSExtractorError.message("ANDROID player returned no playable URL")
    }

    private func fetchAndroidPlayer(
        videoID: String,
        signatureTimestamp: Int
    ) async throws -> StreamVideoInfo? {
        let androidUA =
            "com.google.android.youtube/\(clientVersion) (Linux; U; Android 11) gzip"

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": clientVersion,
                    "androidSdkVersion": 30,
                    "userAgent": androidUA,
                    "osName": "Android",
                    "osVersion": "11",
                    "hl": "en",
                    "timeZone": "UTC",
                    "utcOffsetMinutes": 0,
                ],
            ],
            "videoId": videoID,
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                    "signatureTimestamp": signatureTimestamp,
                ],
            ],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]

        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body)
        else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(androidUA, forHTTPHeaderField: "User-Agent")
        request.setValue("3", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        // Ephemeral session like YTLite — ANDROID client does not need browser cookies.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate"]
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        let bot = text.localizedCaseInsensitiveContains("Sign in to confirm")
            || text.localizedCaseInsensitiveContains("not a bot")
        StreamLog.info(
            "AndroidPlayerResolver HTTP \(status) bytes=\(data.count) bot=\(bot) sts=\(signatureTimestamp)"
        )
        guard (200..<300).contains(status) else { return nil }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let playability = root["playabilityStatus"] as? [String: Any]
        if let statusText = (playability?["status"] as? String)?.uppercased(),
           statusText != "OK", !statusText.isEmpty {
            let reason = (playability?["reason"] as? String) ?? statusText
            StreamLog.error("AndroidPlayerResolver playability=\(statusText) reason=\(reason)")
            throw StreamJSExtractorError.message(reason)
        }

        return try StreamPlayerResponseMapper.videoInfo(videoID: videoID, player: root)
    }

    /// Pull STS from the watch HTML when possible (keeps ANDROID player in sync with the site).
    private static func scrapeSignatureTimestamp(videoID: String) async -> Int? {
        let urls = [
            "https://www.youtube.com/watch?v=\(videoID)",
            "https://m.youtube.com/watch?v=\(videoID)",
        ]
        let ua =
            "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<400).contains(status),
                      let html = String(data: data, encoding: .utf8)
                else { continue }
                if let sts = extractSignatureTimestamp(from: html) {
                    return sts
                }
            } catch {
                continue
            }
        }
        return nil
    }

    static func extractSignatureTimestamp(from html: String) -> Int? {
        let patterns = [
            #"\"STS\"\s*:\s*(\d+)"#,
            #"signatureTimestamp[=:]\s*(\d+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: html),
                  let value = Int(html[r])
            else { continue }
            return value
        }
        return nil
    }
}

/// Secondary Innertube clients (IOS / ANDROID_VR) used after ANDROID+STS fails.
public struct StreamInnertubeResolver: StreamResolving {
    public init() {}

    public func resolve(videoID: String) async throws -> StreamVideoInfo {
        let clients: [(name: String, version: String, clientNameHeader: String, host: String, ua: String, sts: Int?)] = [
            (
                "IOS",
                "19.45.4",
                "5",
                "www.youtube.com",
                "com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)",
                AndroidPlayerResolver.defaultSignatureTimestamp
            ),
            (
                "ANDROID_VR",
                "1.60.19",
                "28",
                "www.youtube.com",
                "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                AndroidPlayerResolver.defaultSignatureTimestamp
            ),
        ]

        var lastError: Error = StreamJSExtractorError.extractFailed
        for client in clients {
            do {
                StreamLog.info("Innertube try client=\(client.name)")
                if let info = try await fetchPlayer(videoID: videoID, client: client) {
                    StreamLog.info("Innertube OK client=\(client.name) url=\(StreamLog.truncate(info.streamURL?.absoluteString))")
                    return info
                }
                StreamLog.info("Innertube empty client=\(client.name)")
            } catch {
                StreamLog.error("Innertube fail client=\(client.name)", error: error)
                lastError = error
            }
        }
        throw lastError
    }

    private func fetchPlayer(
        videoID: String,
        client: (name: String, version: String, clientNameHeader: String, host: String, ua: String, sts: Int?)
    ) async throws -> StreamVideoInfo? {
        let url = URL(string: "https://\(client.host)/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.ua, forHTTPHeaderField: "User-Agent")
        request.setValue(client.clientNameHeader, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://\(client.host)", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")

        var playbackContext: [String: Any] = [
            "html5Preference": "HTML5_PREF_WANTS",
        ]
        if let sts = client.sts {
            playbackContext["signatureTimestamp"] = sts
        }

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": client.name,
                    "clientVersion": client.version,
                    "hl": "en",
                    "timeZone": "UTC",
                    "utcOffsetMinutes": 0,
                    "userAgent": client.ua,
                ],
            ],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": [
                "contentPlaybackContext": playbackContext,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { return nil }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let playability = root["playabilityStatus"] as? [String: Any]
        if let statusText = playability?["status"] as? String,
           statusText != "OK" {
            let reason = (playability?["reason"] as? String) ?? statusText
            throw StreamJSExtractorError.message(reason)
        }

        return try StreamPlayerResponseMapper.videoInfo(videoID: videoID, player: root)
    }
}

enum StreamFormatPicker {
    static func bestPlayableURL(from formats: [[String: Any]]) -> URL? {
        struct Candidate {
            let url: URL
            let itag: Int
            let height: Int
            let hasAudio: Bool
            let hasVideo: Bool
            let isMP4: Bool
            let isHLS: Bool
        }

        var candidates: [Candidate] = []
        for format in formats {
            guard let urlString = format["url"] as? String,
                  let url = URL(string: urlString),
                  !urlString.isEmpty else { continue }

            let itag = (format["itag"] as? Int) ?? Int("\(format["itag"] ?? "")") ?? 0
            let height = (format["height"] as? Int) ?? Int("\(format["height"] ?? "")") ?? 0
            let mime = ((format["type"] as? String) ?? (format["mimeType"] as? String) ?? "").lowercased()
            let acodec = ((format["acodec"] as? String) ?? "").lowercased()
            let vcodec = ((format["vcodec"] as? String) ?? "").lowercased()
            let hasAudio = (!acodec.isEmpty && acodec != "none")
                || mime.contains("audio/")
                || format["audioQuality"] != nil
            let hasVideo = height > 0
                || (!vcodec.isEmpty && vcodec != "none")
                || mime.contains("video/")
            let isMP4 = mime.contains("mp4") || ((format["ext"] as? String)?.lowercased() == "mp4")
            let isHLS = mime.contains("mpegurl") || urlString.contains(".m3u8")

            candidates.append(
                Candidate(
                    url: url,
                    itag: itag,
                    height: height,
                    hasAudio: hasAudio,
                    hasVideo: hasVideo,
                    isMP4: isMP4,
                    isHLS: isHLS
                )
            )
        }

        // Prefer progressive muxed itags (YTLite preferItags).
        let preferredItags: Set<Int> = [18, 22, 37, 59, 78]
        if let hit = candidates.first(where: { preferredItags.contains($0.itag) && $0.hasAudio && $0.hasVideo }) {
            return hit.url
        }
        if let hit = candidates.first(where: { preferredItags.contains($0.itag) }) {
            return hit.url
        }

        let progressive = candidates.filter { $0.hasAudio && $0.hasVideo && !$0.isHLS }
        if let best = progressive.sorted(by: { lhs, rhs in
            if lhs.isMP4 != rhs.isMP4 { return lhs.isMP4 && !rhs.isMP4 }
            return lhs.height > rhs.height
        }).first {
            return best.url
        }

        if let hls = candidates.first(where: \.isHLS) {
            return hls.url
        }

        // Audio-only as last resort (background play still works).
        let preferredAudio: Set<Int> = [140, 141, 139]
        if let hit = candidates.first(where: { preferredAudio.contains($0.itag) }) {
            return hit.url
        }
        return candidates.first(where: { $0.hasAudio && !$0.hasVideo })?.url
            ?? candidates.filter(\.hasVideo).sorted { $0.height > $1.height }.first?.url
    }
}
