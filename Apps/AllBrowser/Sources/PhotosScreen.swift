import AVFoundation
import SwiftUI
import Photos
import DesignSystem
import PhotosKit
import CachePhotosKit
import MediaKit
import StorageKit

struct PhotosScreen: View {
    @EnvironmentObject private var photos: PhotosService
    @EnvironmentObject private var cachePhotos: CachePhotosService
    @EnvironmentObject private var playback: PlaybackController
    @State private var segment = 0

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text("系统相册").tag(0)
                    Text("缓存照片").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if segment == 0 {
                    albumContent
                } else {
                    cacheContent
                }
            }
            .background(ABColor.background)
            .navigationTitle("照片")
            .task {
                await photos.requestAccessAndLoad()
            }
        }
    }

    @ViewBuilder
    private var albumContent: some View {
        switch photos.authorizationStatus {
        case .authorized, .limited:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(photos.items) { item in
                        PhotoThumbnailView(asset: item.asset)
                            .frame(height: 110)
                            .clipped()
                            .onTapGesture {
                                Task { await playIfVideo(item.asset) }
                            }
                    }
                }
                .padding(4)
            }
        case .denied, .restricted:
            EmptyStateView(
                title: "需要相册权限",
                subtitle: "请在系统设置中允许 AllBrowser 访问照片",
                systemImage: "photo.badge.exclamationmark"
            )
        default:
            ProgressView("请求权限中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var cacheContent: some View {
        List {
            Section {
                HStack {
                    Text("占用空间")
                    Spacer()
                    Text(ByteFormat.string(from: cachePhotos.totalBytes))
                        .foregroundStyle(.secondary)
                }
                Button("清空缓存照片", role: .destructive) {
                    try? cachePhotos.deleteAll()
                }
            }
            Section("缓存项") {
                if cachePhotos.items.isEmpty {
                    Text("暂无缓存照片")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(cachePhotos.items) { item in
                        HStack {
                            if let image = cachePhotos.loadThumbnail(url: item.url) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            VStack(alignment: .leading) {
                                Text(item.name).lineLimit(1)
                                Text("\(item.source.rawValue) · \(ByteFormat.string(from: item.fileSize))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                try? cachePhotos.delete(item: item)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .onAppear { cachePhotos.refresh() }
    }

    private func playIfVideo(_ asset: PHAsset) async {
        guard asset.mediaType == .video else { return }
        guard let avAsset = await photos.requestAVAsset(for: asset) else { return }
        if let urlAsset = avAsset as? AVURLAsset {
            playback.play(
                .init(
                    title: asset.value(forKey: "filename") as? String ?? "相册视频",
                    artist: "相册",
                    sourceURL: urlAsset.url
                )
            )
        }
    }
}
