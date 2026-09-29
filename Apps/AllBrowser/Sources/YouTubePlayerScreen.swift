import SwiftUI
import DesignSystem
import YouTubeKit
import MediaKit
import PlaylistKit
import StorageKit

struct YouTubePlayerScreen: View {
    let videoID: String
    @EnvironmentObject private var youtube: YouTubePlaybackService
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var info: YouTubeVideoInfo?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if youtube.isResolving {
                    ProgressView("解析中…")
                        .tint(ABColor.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let info {
                    Group {
                        if info.usesEmbedFallback || info.streamURL == nil {
                            YouTubeEmbedView(videoID: info.videoID)
                                .frame(minHeight: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            PlayerLayerView(player: playback.player) { layer in
                                playback.enablePictureInPicture(with: layer)
                            }
                            .frame(minHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onAppear {
                                youtube.play(info: info, using: playback)
                            }
                        }
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(info.title)
                            .font(ABFont.title(18))
                            .foregroundStyle(ABColor.textPrimary)
                        Text(info.author)
                            .font(ABFont.body(14))
                            .foregroundStyle(ABColor.textSecondary)
                        Text(info.usesEmbedFallback
                             ? "当前为官方嵌入播放（可降级 / 无直链时）"
                             : "增强播放 · 临时缓存可用")
                            .font(ABFont.body(12))
                            .foregroundStyle(ABColor.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                    if let playlist = playlists.playlists.first {
                        Button("加入歌单「\(playlist.name)」") {
                            playlists.addEntry(
                                playlistID: playlist.id,
                                title: info.title,
                                artist: info.author,
                                sourceURLString: "https://www.youtube.com/watch?v=\(info.videoID)",
                                youtubeVideoID: info.videoID,
                                artworkURLString: info.thumbnailURL?.absoluteString
                            )
                        }
                        .buttonStyle(ABPrimaryButtonStyle())
                        .padding(.horizontal)
                    }

                    Spacer()
                } else {
                    EmptyStateView(
                        title: "无法打开视频",
                        subtitle: youtube.errorMessage ?? "请稍后重试",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            .background(ABColor.background)
            .navigationTitle("YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                info = await youtube.prepare(videoID: videoID)
            }
        }
    }
}
