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
                    Text("Library").tag(0)
                    Text("Cached Photos").tag(1)
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
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
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
                title: "Photo Access Required",
                subtitle: "Allow AllBrowser to access Photos in Settings",
                systemImage: "photo.badge.exclamationmark"
            )
        default:
            ProgressView("Requesting access…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var cacheContent: some View {
        List {
            Section {
                HStack {
                    Text("Storage used")
                    Spacer()
                    Text(ByteFormat.string(from: cachePhotos.totalBytes))
                        .foregroundStyle(.secondary)
                }
                Button("Clear Cached Photos", role: .destructive) {
                    try? cachePhotos.deleteAll()
                }
            }
            Section("Cached Items") {
                if cachePhotos.items.isEmpty {
                    Text("No cached photos")
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
                                Label("Delete", systemImage: "trash")
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
                    title: asset.value(forKey: "filename") as? String ?? "Photo Video",
                    artist: "Photos",
                    sourceURL: urlAsset.url
                )
            )
        }
    }
}
