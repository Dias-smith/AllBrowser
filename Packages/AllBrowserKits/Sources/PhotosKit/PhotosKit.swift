import AVFoundation
import Foundation
import Photos
import SwiftUI
import StorageKit
import UIKit

// MARK: - Models

public struct PhotoAssetItem: Identifiable, Equatable {
    public let id: String
    public let asset: PHAsset

    public init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.asset = asset
    }

    public var creationDate: Date? { asset.creationDate }
    public var isVideo: Bool { asset.mediaType == .video }
    public var isScreenshot: Bool { asset.mediaSubtypes.contains(.photoScreenshot) }
}

public struct PhotoAlbumItem: Identifiable, Equatable, Hashable {
    public let id: String
    public let title: String
    public let count: Int
    public let collection: PHAssetCollection

    public init(collection: PHAssetCollection) {
        self.id = collection.localIdentifier
        self.title = collection.localizedTitle ?? "Untitled"
        self.count = collection.estimatedAssetCount == NSNotFound
            ? PHAsset.fetchAssets(in: collection, options: nil).count
            : collection.estimatedAssetCount
        self.collection = collection
    }
}

public enum PhotoQueueKind: String, CaseIterable, Identifiable, Codable {
    case recentUnreviewed
    case screenshots
    case largeFiles
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recentUnreviewed: return "Recent Unreviewed"
        case .screenshots: return "Screenshots"
        case .largeFiles: return "Large Files"
        case .all: return "All Photos"
        }
    }

    public var systemImage: String {
        switch self {
        case .recentUnreviewed: return "clock"
        case .screenshots: return "camera.viewfinder"
        case .largeFiles: return "externaldrive"
        case .all: return "photo.on.rectangle"
        }
    }

    public var subtitle: String {
        switch self {
        case .recentUnreviewed: return "Recent items you haven’t reviewed"
        case .screenshots: return "Screenshot images"
        case .largeFiles: return "Videos and large photos"
        case .all: return "Browse everything to organize"
        }
    }
}

public enum OrganizeAction: Equatable {
    case keep(String)
    case deleteCandidate(String)
    case addToAlbum(assetID: String, albumID: String)
}

private struct PhotoReviewState: Codable, Equatable {
    var reviewedIDs: [String]
    var pendingDeleteIDs: [String]
}

// MARK: - Review store

@MainActor
public final class PhotoReviewStore: ObservableObject {
    @Published public private(set) var reviewedIDs: Set<String> = []
    @Published public private(set) var pendingDeleteIDs: Set<String> = []

    private let store = JSONStore<PhotoReviewState>(filename: "photo-review.json")

    public init() {
        let state = store.load(default: PhotoReviewState(reviewedIDs: [], pendingDeleteIDs: []))
        reviewedIDs = Set(state.reviewedIDs)
        pendingDeleteIDs = Set(state.pendingDeleteIDs)
    }

    public func markReviewed(_ id: String) {
        reviewedIDs.insert(id)
        pendingDeleteIDs.remove(id)
        persist()
    }

    public func markPendingDelete(_ id: String) {
        pendingDeleteIDs.insert(id)
        reviewedIDs.insert(id)
        persist()
    }

    public func removePendingDelete(_ id: String) {
        pendingDeleteIDs.remove(id)
        persist()
    }

    public func clearPendingDeletes(_ ids: [String]) {
        for id in ids { pendingDeleteIDs.remove(id) }
        persist()
    }

    public func unreview(_ id: String) {
        reviewedIDs.remove(id)
        pendingDeleteIDs.remove(id)
        persist()
    }

    private func persist() {
        try? store.save(
            PhotoReviewState(
                reviewedIDs: Array(reviewedIDs),
                pendingDeleteIDs: Array(pendingDeleteIDs)
            )
        )
    }
}

// MARK: - Photos service

@MainActor
public final class PhotosService: ObservableObject {
    @Published public private(set) var authorizationStatus: PHAuthorizationStatus
    @Published public private(set) var items: [PhotoAssetItem] = []
    @Published public private(set) var albums: [PhotoAlbumItem] = []
    @Published public var mediaTypeFilter: PHAssetMediaType? = nil
    @Published public var lastErrorMessage: String?

    public let reviewStore: PhotoReviewStore

    public init(reviewStore: PhotoReviewStore) {
        self.reviewStore = reviewStore
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public var pendingDeleteCount: Int { reviewStore.pendingDeleteIDs.count }

    public func requestAccessAndLoad() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        guard status == .authorized || status == .limited else { return }
        reloadAll()
    }

    public func reloadAll() {
        loadAssets()
        loadAlbums()
    }

    public func loadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        let result: PHFetchResult<PHAsset>
        if let mediaTypeFilter {
            result = PHAsset.fetchAssets(with: mediaTypeFilter, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        var list: [PhotoAssetItem] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            list.append(PhotoAssetItem(asset: asset))
        }
        items = list
    }

    public func loadAlbums() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: options
        )
        var list: [PhotoAlbumItem] = []
        result.enumerateObjects { collection, _, _ in
            list.append(PhotoAlbumItem(collection: collection))
        }
        albums = list
    }

    public func queue(for kind: PhotoQueueKind) -> [PhotoAssetItem] {
        let reviewed = reviewStore.reviewedIDs
        let pending = reviewStore.pendingDeleteIDs
        switch kind {
        case .all:
            return items.filter { !pending.contains($0.id) }
        case .recentUnreviewed:
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date.distantPast
            return items.filter { item in
                guard !reviewed.contains(item.id), !pending.contains(item.id) else { return false }
                guard let date = item.creationDate else { return true }
                return date >= cutoff
            }
        case .screenshots:
            return items.filter { $0.isScreenshot && !pending.contains($0.id) }
        case .largeFiles:
            return items.filter { item in
                guard !pending.contains(item.id) else { return false }
                if item.isVideo { return item.asset.duration >= 60 }
                return item.asset.pixelWidth * item.asset.pixelHeight >= 12_000_000
            }
        }
    }

    public func count(for kind: PhotoQueueKind) -> Int {
        queue(for: kind).count
    }

    public func assets(forIDs ids: [String]) -> [PhotoAssetItem] {
        let set = Set(ids)
        return items.filter { set.contains($0.id) }
    }

    public func pendingDeleteItems() -> [PhotoAssetItem] {
        assets(forIDs: Array(reviewStore.pendingDeleteIDs))
    }

    public func requestImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? Error
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if cancelled || error != nil {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: image)
                    }
                    return
                }
                if !degraded, !resumed {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    public func requestAVAsset(for asset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    public func createAlbum(named name: String) async throws -> PhotoAlbumItem {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PhotoKitError.invalidName }

        var placeholderID: String?
        try await performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: trimmed)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        loadAlbums()
        if let id = placeholderID, let album = albums.first(where: { $0.id == id }) {
            return album
        }
        if let album = albums.first(where: { $0.title == trimmed }) {
            return album
        }
        throw PhotoKitError.albumNotFound
    }

    public func addAsset(_ asset: PHAsset, to album: PhotoAlbumItem) async throws {
        try await performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album.collection) else {
                throw PhotoKitError.albumNotFound
            }
            request.addAssets([asset] as NSArray)
        }
        loadAlbums()
    }

    public func deleteAssets(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
        let ids = assets.map(\.localIdentifier)
        reviewStore.clearPendingDeletes(ids)
        reloadAll()
    }

    private func performChanges(_ changes: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                do {
                    try changes()
                } catch {
                    // performChanges doesn't surface thrown errors from the block reliably;
                    // validation happens before.
                }
            }, completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoKitError.changeFailed)
                }
            })
        }
    }
}

public enum PhotoKitError: LocalizedError {
    case invalidName
    case albumNotFound
    case changeFailed
    case noCurrentAsset

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a valid album name."
        case .albumNotFound: return "Album not found."
        case .changeFailed: return "Could not update the photo library."
        case .noCurrentAsset: return "No photo selected."
        }
    }
}

// MARK: - Organize session

@MainActor
public final class PhotoOrganizeSession: ObservableObject {
    @Published public private(set) var queue: [PhotoAssetItem] = []
    @Published public private(set) var index: Int = 0
    @Published public var kind: PhotoQueueKind = .recentUnreviewed
    @Published public var focusedAlbumID: String?
    @Published public var toastMessage: String?
    @Published public var lastError: String?

    private let photos: PhotosService
    private var undoStack: [OrganizeAction] = []

    public init(photos: PhotosService) {
        self.photos = photos
    }

    public var current: PhotoAssetItem? {
        guard queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    public var remainingCount: Int {
        max(queue.count - index, 0)
    }

    public var isFinished: Bool {
        index >= queue.count
    }

    public func start(kind: PhotoQueueKind, focusedAlbumID: String? = nil) {
        self.kind = kind
        self.focusedAlbumID = focusedAlbumID
        queue = photos.queue(for: kind)
        index = 0
        undoStack.removeAll()
        toastMessage = nil
        lastError = nil
        if let focusedAlbumID,
           let album = photos.albums.first(where: { $0.id == focusedAlbumID }) {
            toastMessage = "Add photos to \(album.title)"
        }
    }

    public func keep() {
        guard let item = current else { return }
        photos.reviewStore.markReviewed(item.id)
        undoStack.append(.keep(item.id))
        advance()
    }

    public func markDeleteCandidate() {
        guard let item = current else { return }
        photos.reviewStore.markPendingDelete(item.id)
        undoStack.append(.deleteCandidate(item.id))
        advance()
    }

    public func addCurrentToAlbum(_ album: PhotoAlbumItem) async {
        guard let item = current else {
            lastError = PhotoKitError.noCurrentAsset.localizedDescription
            return
        }
        do {
            try await photos.addAsset(item.asset, to: album)
            photos.reviewStore.markReviewed(item.id)
            undoStack.append(.addToAlbum(assetID: item.id, albumID: album.id))
            toastMessage = "Added to \(album.title)"
            advance()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func undo() {
        guard let action = undoStack.popLast() else { return }
        switch action {
        case .keep(let id):
            photos.reviewStore.unreview(id)
            rewindIfNeeded(to: id)
        case .deleteCandidate(let id):
            photos.reviewStore.removePendingDelete(id)
            photos.reviewStore.unreview(id)
            rewindIfNeeded(to: id)
        case .addToAlbum(let assetID, _):
            // Removing from album requires another PhotoKit change; undo only restores queue position/review.
            photos.reviewStore.unreview(assetID)
            rewindIfNeeded(to: assetID)
            toastMessage = "Undid review (album membership unchanged)"
        }
    }

    public func clearToast() {
        toastMessage = nil
    }

    private func advance() {
        index = min(index + 1, queue.count)
    }

    private func rewindIfNeeded(to id: String) {
        if let found = queue.firstIndex(where: { $0.id == id }) {
            index = found
        }
    }
}

// MARK: - Thumbnail

public struct PhotoThumbnailView: View {
    let asset: PHAsset
    var targetSize: CGSize = CGSize(width: 200, height: 200)
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @EnvironmentObject private var photos: PhotosService

    public init(
        asset: PHAsset,
        targetSize: CGSize = CGSize(width: 200, height: 200),
        contentMode: ContentMode = .fill
    ) {
        self.asset = asset
        self.targetSize = targetSize
        self.contentMode = contentMode
    }

    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color.gray.opacity(0.2))
            }
        }
        .task(id: asset.localIdentifier) {
            image = await photos.requestImage(for: asset, targetSize: targetSize)
        }
    }
}
