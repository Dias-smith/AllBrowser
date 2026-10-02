import SwiftUI
import Photos
import DesignSystem
import PhotosKit
import CachePhotosKit
import StorageKit

struct PhotosScreen: View {
    @EnvironmentObject private var photos: PhotosService
    @EnvironmentObject private var organize: PhotoOrganizeSession
    @EnvironmentObject private var cachePhotos: CachePhotosService

    @State private var segment = 0
    @State private var showSession = false
    @State private var showBasket = false
    @State private var showNewAlbum = false
    @State private var newAlbumName = ""
    @State private var errorMessage: String?
    @State private var albumByteCounts: [String: Int64] = [:]
    @State private var basketByteCount: Int64 = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text("Organize").tag(0)
                    Text("Cached").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if segment == 0 {
                    organizeHub
                } else {
                    cacheContent
                }
            }
            .background(ABColor.background)
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if segment == 0 {
                        Button {
                            showBasket = true
                        } label: {
                            HStack(spacing: 6) {
                                if photos.pendingDeleteCount > 0 {
                                    Text(ByteFormat.string(from: basketByteCount))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(ABColor.textSecondary)
                                        .monospacedDigit()
                                }
                                Image(systemName: "trash")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(ABColor.accent)
                                    .frame(width: 22, height: 22)
                                    .overlay(alignment: .topTrailing) {
                                        if photos.pendingDeleteCount > 0 {
                                            Text("\(photos.pendingDeleteCount)")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(ABColor.danger))
                                                .offset(x: 10, y: -8)
                                        }
                                    }
                            }
                            // Keep badge inside toolbar clip bounds.
                            .padding(.top, 8)
                            .padding(.trailing, 10)
                            .padding(.bottom, 2)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel(
                            photos.pendingDeleteCount > 0
                                ? "Delete basket, \(photos.pendingDeleteCount) items, \(ByteFormat.string(from: basketByteCount))"
                                : "Delete basket"
                        )
                    }
                }
            }
            .navigationDestination(isPresented: $showSession) {
                PhotoSwipeSessionView()
            }
            .navigationDestination(isPresented: $showBasket) {
                PhotoDeleteBasketView()
            }
            .alert("New Album", isPresented: $showNewAlbum) {
                TextField("Album name", text: $newAlbumName)
                Button("Create") {
                    Task { await createAlbum() }
                }
                Button("Cancel", role: .cancel) { newAlbumName = "" }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                await photos.requestAccessAndLoad()
                refreshSizeLabels()
            }
            .onChange(of: photos.albums) { _, _ in
                refreshSizeLabels()
            }
            .onReceive(photos.reviewStore.$pendingDeleteIDs) { _ in
                refreshSizeLabels()
            }
            .onAppear {
                refreshSizeLabels()
            }
        }
    }

    @ViewBuilder
    private var organizeHub: some View {
        switch photos.authorizationStatus {
        case .authorized, .limited:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if photos.authorizationStatus == .limited {
                        Text("Limited photo access is on. Choose more photos in Settings for full organize.")
                            .font(ABFont.body(13))
                            .foregroundStyle(ABColor.textSecondary)
                            .padding(.horizontal, 16)
                    }

                    Text("Clean & Sort")
                        .font(ABFont.title(16))
                        .foregroundStyle(ABColor.textPrimary)
                        .padding(.horizontal, 16)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(PhotoQueueKind.allCases) { kind in
                            categoryCard(kind)
                        }
                    }
                    .padding(.horizontal, 16)

                    HStack {
                        Text("Albums")
                            .font(ABFont.title(16))
                            .foregroundStyle(ABColor.textPrimary)
                        Spacer()
                        Button {
                            showNewAlbum = true
                        } label: {
                            Label("New", systemImage: "plus")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 16)

                    if photos.albums.isEmpty {
                        Text("No albums yet. Create one to start organizing.")
                            .font(ABFont.body(13))
                            .foregroundStyle(ABColor.textSecondary)
                            .padding(.horizontal, 16)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(photos.albums) { album in
                                Button {
                                    startOrganize(into: album)
                                } label: {
                                    HStack {
                                        Image(systemName: "folder.fill")
                                            .foregroundStyle(.blue)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(album.title)
                                                .foregroundStyle(ABColor.textPrimary)
                                            Text("\(album.count) items")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(ByteFormat.string(from: albumByteCounts[album.id] ?? 0))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(ABColor.accent)
                                            .monospacedDigit()
                                    }
                                    .padding(12)
                                    .background(ABColor.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 24)
            }
        case .denied, .restricted:
            EmptyStateView(
                title: "Photo Access Required",
                subtitle: "Allow AllBrowser to access Photos in Settings to clean and organize.",
                systemImage: "photo.badge.exclamationmark"
            )
        default:
            ProgressView("Requesting access…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func categoryCard(_ kind: PhotoQueueKind) -> some View {
        let count = photos.count(for: kind)
        return Button {
            organize.start(kind: kind)
            showSession = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(ABColor.accent)
                Text(kind.title)
                    .font(ABFont.title(15))
                    .foregroundStyle(ABColor.textPrimary)
                    .multilineTextAlignment(.leading)
                Text("\(count) items")
                    .font(.caption)
                    .foregroundStyle(ABColor.textSecondary)
                Text(kind.subtitle)
                    .font(.caption2)
                    .foregroundStyle(ABColor.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding(14)
            .background(ABColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(count == 0)
        .opacity(count == 0 ? 0.45 : 1)
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
        .listStyle(.plain)
        .onAppear { cachePhotos.refresh() }
    }

    private func createAlbum() async {
        do {
            _ = try await photos.createAlbum(named: newAlbumName)
            newAlbumName = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startOrganize(into album: PhotoAlbumItem) {
        let albumPhotos = photos.assets(in: album)
        guard !albumPhotos.isEmpty else {
            errorMessage = "This album has no photos to organize."
            return
        }
        organize.start(album: album)
        showSession = true
    }

    private func refreshSizeLabels() {
        var map: [String: Int64] = [:]
        for album in photos.albums {
            map[album.id] = photos.totalByteCount(in: album)
        }
        albumByteCounts = map
        basketByteCount = photos.pendingDeleteByteCount
    }
}
