import Foundation
import StorageKit
import UIKit

public struct CachedPhotoItem: Identifiable, Equatable, Hashable {
    public var id: String { url.path }
    public var url: URL
    public var name: String
    public var fileSize: Int64
    public var modifiedAt: Date
    public var source: CacheSource

    public enum CacheSource: String, Codable {
        case webImage
        case mediaArtwork
        case other
    }
}

@MainActor
public final class CachePhotosService: ObservableObject {
    @Published public private(set) var items: [CachedPhotoItem] = []
    @Published public private(set) var totalBytes: Int64 = 0

    public init() {
        refresh()
    }

    public func refresh() {
        let roots: [(URL, CachedPhotoItem.CacheSource)] = [
            (AppPaths.webImageCache, .webImage),
            (AppPaths.caches.appendingPathComponent("MediaArtwork", isDirectory: true), .mediaArtwork),
        ]
        var collected: [CachedPhotoItem] = []
        var total: Int64 = 0
        let fm = FileManager.default
        for (root, source) in roots {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            guard let urls = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls {
                let ext = url.pathExtension.lowercased()
                guard ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) else { continue }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                total += size
                collected.append(
                    CachedPhotoItem(
                        url: url,
                        name: url.lastPathComponent,
                        fileSize: size,
                        modifiedAt: values?.contentModificationDate ?? Date(),
                        source: source
                    )
                )
            }
        }
        items = collected.sorted { $0.modifiedAt > $1.modifiedAt }
        totalBytes = total
    }

    public func delete(item: CachedPhotoItem) throws {
        try FileManager.default.removeItem(at: item.url)
        refresh()
    }

    public func deleteAll() throws {
        for item in items {
            try? FileManager.default.removeItem(at: item.url)
        }
        refresh()
    }

    @discardableResult
    public func storeWebImage(data: Data, suggestedName: String) throws -> URL {
        let name = suggestedName.isEmpty ? UUID().uuidString + ".jpg" : suggestedName
        let url = AppPaths.webImageCache.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic])
        refresh()
        return url
    }

    public func loadThumbnail(url: URL) -> UIImage? {
        UIImage(contentsOfFile: url.path)
    }
}
