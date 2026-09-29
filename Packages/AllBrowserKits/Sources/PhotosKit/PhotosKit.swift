import AVFoundation
import Foundation
import Photos
import SwiftUI

public struct PhotoAssetItem: Identifiable, Equatable {
    public let id: String
    public let asset: PHAsset

    public init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.asset = asset
    }
}

@MainActor
public final class PhotosService: ObservableObject {
    @Published public private(set) var authorizationStatus: PHAuthorizationStatus
    @Published public private(set) var items: [PhotoAssetItem] = []
    @Published public var mediaTypeFilter: PHAssetMediaType? = nil

    public init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public func requestAccessAndLoad() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        guard status == .authorized || status == .limited else { return }
        loadAssets()
    }

    public func loadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 300
        let result: PHFetchResult<PHAsset>
        if let mediaTypeFilter {
            result = PHAsset.fetchAssets(with: mediaTypeFilter, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        var list: [PhotoAssetItem] = []
        result.enumerateObjects { asset, _, _ in
            list.append(PhotoAssetItem(asset: asset))
        }
        items = list
    }

    public func requestImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded {
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
}

public struct PhotoThumbnailView: View {
    let asset: PHAsset
    @State private var image: UIImage?
    private let service = PhotosService()

    public init(asset: PHAsset) {
        self.asset = asset
    }

    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.gray.opacity(0.2))
            }
        }
        .task {
            image = await service.requestImage(for: asset, targetSize: CGSize(width: 200, height: 200))
        }
    }
}
