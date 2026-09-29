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
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "trash")
                                if photos.pendingDeleteCount > 0 {
                                    Text("\(photos.pendingDeleteCount)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(Circle().fill(ABColor.danger))
                                        .offset(x: 8, y: -8)
                                }
                            }
                        }
                        .accessibilityLabel("Delete basket")
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
                                        Image(systemName: "square.and.arrow.down")
                                            .foregroundStyle(ABColor.accent)
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
        let kind: PhotoQueueKind = photos.count(for: .recentUnreviewed) > 0 ? .recentUnreviewed : .all
        guard photos.count(for: kind) > 0 || photos.count(for: .all) > 0 else {
            errorMessage = "No photos available to organize."
            return
        }
        let startKind = photos.count(for: kind) > 0 ? kind : .all
        organize.start(kind: startKind, focusedAlbumID: album.id)
        showSession = true
    }
}
