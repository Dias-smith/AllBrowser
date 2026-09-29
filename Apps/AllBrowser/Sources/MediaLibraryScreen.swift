import SwiftUI
import DesignSystem
import MediaKit
import PlaylistKit
import YouTubeKit
import UniformTypeIdentifiers

struct MediaLibraryScreen: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var youtube: YouTubePlaybackService
    @State private var newPlaylistName = ""
    @State private var showCreatePlaylist = false

    var body: some View {
        NavigationStack {
            List {
                Section("歌单") {
                    ForEach(playlists.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailScreen(playlist: playlist)
                        } label: {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(ABColor.accent)
                                VStack(alignment: .leading) {
                                    Text(playlist.name)
                                    Text("\(playlists.entries(in: playlist.id).count) 首")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            playlists.deletePlaylist(id: playlists.playlists[index].id)
                        }
                    }
                }
            }
            .navigationTitle("媒体库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreatePlaylist = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("新建歌单", isPresented: $showCreatePlaylist) {
                TextField("名称", text: $newPlaylistName)
                Button("创建") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        _ = playlists.createPlaylist(name: name)
                    }
                    newPlaylistName = ""
                }
                Button("取消", role: .cancel) { newPlaylistName = "" }
            }
        }
    }
}

struct PlaylistDetailScreen: View {
    let playlist: Playlist
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var youtube: YouTubePlaybackService
    @State private var showYouTube: String?

    var body: some View {
        List {
            let entries = playlists.entries(in: playlist.id)
            if entries.isEmpty {
                EmptyStateView(
                    title: "暂无曲目",
                    subtitle: "从浏览器 YouTube 增强播放加入，或添加本地条目",
                    systemImage: "music.note"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(entries) { entry in
                    Button {
                        Task { await play(entry: entry) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).foregroundStyle(ABColor.textPrimary)
                            Text(entry.artist.isEmpty ? (entry.youtubeVideoID != nil ? "YouTube" : "本地") : entry.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        playlists.removeEntry(id: entries[index].id)
                    }
                }
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(
            get: { showYouTube.map { IdentifiedString(id: $0) } },
            set: { showYouTube = $0?.id }
        )) { item in
            YouTubePlayerScreen(videoID: item.id)
        }
    }

    private func play(entry: PlaylistEntry) async {
        if let videoID = entry.youtubeVideoID {
            showYouTube = videoID
            return
        }
        if let item = entry.asMediaItem() {
            playback.play(item)
        }
    }
}

private struct IdentifiedString: Identifiable {
    var id: String
}

struct FullPlayerScreen: View {
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                PlayerLayerView(player: playback.player) { layer in
                    playback.enablePictureInPicture(with: layer)
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)

                Text(playback.currentItem?.title ?? "未在播放")
                    .font(ABFont.title(22))
                    .foregroundStyle(ABColor.textPrimary)
                Text(playback.currentItem?.artist ?? "")
                    .foregroundStyle(ABColor.textSecondary)

                VStack {
                    Slider(
                        value: Binding(
                            get: { playback.currentTime },
                            set: { playback.seek(to: $0) }
                        ),
                        in: 0...max(playback.duration, 1)
                    )
                    .tint(ABColor.accent)
                    HStack {
                        Text(timeString(playback.currentTime))
                        Spacer()
                        Text(timeString(playback.duration))
                    }
                    .font(ABFont.mono(12))
                    .foregroundStyle(ABColor.textSecondary)
                }
                .padding(.horizontal)

                HStack(spacing: 36) {
                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(ABColor.accent)
                    }
                    Button {
                        playback.startPictureInPicture()
                    } label: {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 28))
                    }
                }

                Picker("倍数", selection: $playback.rate) {
                    Text("0.5x").tag(Float(0.5))
                    Text("1x").tag(Float(1.0))
                    Text("1.25x").tag(Float(1.25))
                    Text("1.5x").tag(Float(1.5))
                    Text("2x").tag(Float(2.0))
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Spacer()
            }
            .background(ABColor.background)
            .navigationTitle("播放器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func timeString(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "0:00" }
        let total = Int(value)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
