import Foundation
import StorageKit
import UniformTypeIdentifiers

public enum DownloadBlockReason: Equatable {
    case audioVideoContent
    case protectedMediaHost

    public var userMessage: String {
        switch self {
        case .audioVideoContent:
            return "不支持下载音视频内容，以避免侵犯版权。"
        case .protectedMediaHost:
            return "该来源的媒体内容不可下载。"
        }
    }
}

public enum DownloadPolicy {
    private static let blockedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "wma", "ogg", "opus", "oga",
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "mpeg", "mpg", "ts", "m2ts",
        "m3u8", "m3u", "mpd",
    ]

    private static let protectedHosts: [String] = [
        "youtube.com", "youtu.be", "youtube-nocookie.com",
        "googlevideo.com", "ytimg.com",
        "vimeo.com", "player.vimeo.com",
        "netflix.com", "spotify.com", "music.apple.com", "itunes.apple.com",
        "bilibili.com", "bilivideo.com", "iqiyi.com", "youku.com",
        "tiktok.com", "douyin.com",
    ]

    public static func evaluate(url: URL?, mimeType: String?, suggestedFilename: String?) -> DownloadBlockReason? {
        if let host = url?.host?.lowercased(), isProtectedHost(host) {
            return .protectedMediaHost
        }

        let mime = (mimeType ?? "").lowercased()
        if mime.hasPrefix("audio/") || mime.hasPrefix("video/") {
            return .audioVideoContent
        }
        if mime.contains("mpegurl") || mime == "application/vnd.apple.mpegurl" || mime == "application/x-mpegurl" {
            return .audioVideoContent
        }

        let name = (suggestedFilename ?? url?.lastPathComponent ?? "").lowercased()
        let ext = (name as NSString).pathExtension
        if blockedExtensions.contains(ext) {
            return .audioVideoContent
        }

        return nil
    }

    public static func isProtectedHost(_ host: String) -> Bool {
        protectedHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

public enum DownloadState: String, Codable, Equatable {
    case downloading
    case completed
    case failed
    case blocked
}

public struct DownloadItem: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var filename: String
    public var sourceURLString: String
    public var mimeType: String?
    public var localPath: String?
    public var byteCount: Int64
    public var state: DownloadState
    public var createdAt: Date
    public var finishedAt: Date?
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        filename: String,
        sourceURLString: String,
        mimeType: String? = nil,
        localPath: String? = nil,
        byteCount: Int64 = 0,
        state: DownloadState,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.sourceURLString = sourceURLString
        self.mimeType = mimeType
        self.localPath = localPath
        self.byteCount = byteCount
        self.state = state
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
    }

    public var fileURL: URL? {
        guard let localPath else { return nil }
        return URL(fileURLWithPath: localPath)
    }
}

@MainActor
public final class DownloadService: ObservableObject {
    @Published public private(set) var items: [DownloadItem] = []
    @Published public var lastBlockedMessage: String?

    private let store = JSONStore<[DownloadItem]>(filename: "downloads.json")
    private var activeDestinationURLs: [UUID: URL] = [:]

    public init() {
        try? FileManager.default.createDirectory(at: AppPaths.downloads, withIntermediateDirectories: true)
        items = store.load(default: []).sorted { $0.createdAt > $1.createdAt }
    }

    public var completedItems: [DownloadItem] {
        items.filter { $0.state == .completed }
    }

    public func destinationURL(forSuggestedName name: String) -> URL {
        uniqueURL(in: AppPaths.downloads, preferredName: sanitizeFilename(name))
    }

    /// Returns nil and records a blocked item when policy rejects the download.
    public func beginDownload(
        sourceURL: URL?,
        mimeType: String?,
        suggestedFilename: String?
    ) -> (itemID: UUID, destinationURL: URL)? {
        let filename = sanitizeFilename(suggestedFilename ?? sourceURL?.lastPathComponent ?? "download")
        if let reason = DownloadPolicy.evaluate(url: sourceURL, mimeType: mimeType, suggestedFilename: filename) {
            recordBlocked(
                filename: filename,
                sourceURLString: sourceURL?.absoluteString ?? "",
                mimeType: mimeType,
                message: reason.userMessage
            )
            lastBlockedMessage = reason.userMessage
            return nil
        }

        let id = UUID()
        let dest = destinationURL(forSuggestedName: filename)
        activeDestinationURLs[id] = dest
        let item = DownloadItem(
            id: id,
            filename: dest.lastPathComponent,
            sourceURLString: sourceURL?.absoluteString ?? "",
            mimeType: mimeType,
            localPath: dest.path,
            byteCount: 0,
            state: .downloading
        )
        items.insert(item, at: 0)
        persist()
        lastBlockedMessage = nil
        return (id, dest)
    }

    public func completeDownload(id: UUID, byteCount: Int64? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .completed
        items[index].finishedAt = Date()
        if let byteCount {
            items[index].byteCount = byteCount
        } else if let path = items[index].localPath {
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey])
            items[index].byteCount = Int64(values?.fileSize ?? 0)
        }
        activeDestinationURLs[id] = nil
        persist()
    }

    public func failDownload(id: UUID, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .failed
        items[index].errorMessage = message
        items[index].finishedAt = Date()
        if let url = activeDestinationURLs[id] {
            try? FileManager.default.removeItem(at: url)
        }
        items[index].localPath = nil
        activeDestinationURLs[id] = nil
        persist()
    }

    public func delete(_ item: DownloadItem) {
        if let path = item.localPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        items.removeAll { $0.id == item.id }
        persist()
    }

    public func clearCompleted() {
        let completed = items.filter { $0.state == .completed || $0.state == .blocked || $0.state == .failed }
        for item in completed {
            if let path = item.localPath {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            }
        }
        items.removeAll { $0.state != .downloading }
        persist()
    }

    public func clearBlockedBanner() {
        lastBlockedMessage = nil
    }

    private func recordBlocked(filename: String, sourceURLString: String, mimeType: String?, message: String) {
        let item = DownloadItem(
            filename: filename,
            sourceURLString: sourceURLString,
            mimeType: mimeType,
            state: .blocked,
            finishedAt: Date(),
            errorMessage: message
        )
        items.insert(item, at: 0)
        persist()
    }

    private func persist() {
        try? store.save(items)
    }

    private func sanitizeFilename(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }

    private func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let ns = preferredName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var candidate = directory.appendingPathComponent(preferredName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}
