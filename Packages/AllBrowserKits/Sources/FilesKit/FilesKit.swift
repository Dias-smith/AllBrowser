import Foundation
import StorageKit
import UniformTypeIdentifiers

public struct LocalFileItem: Identifiable, Equatable, Hashable {
    public var id: String { url.path }
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    public var fileSize: Int64
    public var modifiedAt: Date
    public var category: FileCategory

    public enum FileCategory: String, CaseIterable {
        case audio, video, image, document, other

        public var title: String {
            switch self {
            case .audio: return "音频"
            case .video: return "视频"
            case .image: return "图片"
            case .document: return "文档"
            case .other: return "其他"
            }
        }
    }
}

@MainActor
public final class FilesService: ObservableObject {
    @Published public private(set) var items: [LocalFileItem] = []
    @Published public var currentDirectory: URL
    @Published public var filter: LocalFileItem.FileCategory? = nil
    @Published public private(set) var totalBytes: Int64 = 0

    public init(root: URL = AppPaths.importedFiles) {
        currentDirectory = root
        refresh()
    }

    public func refresh() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: currentDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            items = []
            totalBytes = 0
            return
        }

        var total: Int64 = 0
        let mapped: [LocalFileItem] = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = values?.isDirectory ?? false
            let size = Int64(values?.fileSize ?? 0)
            if !isDir { total += size }
            let category = Self.category(for: url, isDirectory: isDir)
            return LocalFileItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDir,
                fileSize: size,
                modifiedAt: values?.contentModificationDate ?? Date(),
                category: category
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        totalBytes = total
        if let filter {
            items = mapped.filter { $0.isDirectory || $0.category == filter }
        } else {
            items = mapped
        }
    }

    public func openDirectory(_ url: URL) {
        currentDirectory = url
        refresh()
    }

    public func goUp() {
        let root = AppPaths.importedFiles.path
        let parent = currentDirectory.deletingLastPathComponent()
        if parent.path.hasPrefix(root) || parent.path == root {
            currentDirectory = parent.path.count < root.count ? AppPaths.importedFiles : parent
        } else {
            currentDirectory = AppPaths.importedFiles
        }
        refresh()
    }

    public func rename(item: LocalFileItem, to newName: String) throws {
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: item.url, to: dest)
        refresh()
    }

    public func delete(item: LocalFileItem) throws {
        try FileManager.default.removeItem(at: item.url)
        refresh()
    }

    public func importFile(from url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let dest = AppPaths.importedFiles.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        currentDirectory = AppPaths.importedFiles
        refresh()
    }

    public func createFolder(named name: String) throws {
        let dest = currentDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        refresh()
    }

    private static func category(for url: URL, isDirectory: Bool) -> LocalFileItem.FileCategory {
        if isDirectory { return .other }
        let ext = url.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "wav", "flac", "aiff"].contains(ext) { return .audio }
        if ["mp4", "mov", "m4v", "mkv", "webm"].contains(ext) { return .video }
        if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) { return .image }
        if ["pdf", "txt", "doc", "docx", "pages", "rtf"].contains(ext) { return .document }
        return .other
    }
}
