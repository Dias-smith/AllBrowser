import SwiftUI
import DesignSystem
import StreamKit
import MediaKit
import PlaylistKit
import StorageKit

struct LocalPlayerScreen: View {
    let videoID: String
    var preloaded: StreamVideoInfo? = nil
    /// Called once when local resolve/play settles. `true` = playing locally.
    var onSettled: ((Bool) -> Void)? = nil

    @EnvironmentObject private var youtube: StreamPlaybackService
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var info: StreamVideoInfo?
    @State private var didReportSettled = false

    private var hasLocalStream: Bool {
        guard let info else { return false }
        return info.streamURL != nil && !info.usesEmbedFallback
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if youtube.isResolving {
                    ProgressView("Resolving stream…")
                        .tint(ABColor.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let info, hasLocalStream {
                    PlayerLayerView(player: playback.player) { layer in
                        playback.enablePictureInPicture(with: layer)
                    }
                    .frame(minHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal)
                    .onAppear {
                        youtube.play(info: info, using: playback)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(info.title)
                            .font(ABFont.title(18))
                            .foregroundStyle(ABColor.textPrimary)
                        Text(info.author)
                            .font(ABFont.body(14))
                            .foregroundStyle(ABColor.textSecondary)
                        Text("Local player · Direct stream · Background audio")
                            .font(ABFont.body(12))
                            .foregroundStyle(ABColor.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                    if let playlist = playlists.playlists.first {
                        Button("Add to playlist “\(playlist.name)”") {
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
                        title: "Stream unavailable",
                        subtitle: youtube.errorMessage
                            ?? "Could not resolve a direct playable URL for this video.",
                        systemImage: "exclamationmark.triangle"
                    )
                    Button("Retry") {
                        Task {
                            await resolveAndPlay(forceNetwork: true)
                        }
                    }
                    .buttonStyle(ABPrimaryButtonStyle())
                    .padding(.horizontal, 40)
                    Spacer()
                }
            }
            .background(ABColor.background)
            .navigationTitle("Local Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await resolveAndPlay(forceNetwork: false)
            }
        }
    }

    private func resolveAndPlay(forceNetwork: Bool) async {
        StreamLog.info("PlayerScreen resolve forceNetwork=\(forceNetwork) videoID=\(videoID) preloaded=\(preloaded?.streamURL != nil)")
        if !forceNetwork,
           let preloaded,
           preloaded.streamURL != nil,
           !preloaded.usesEmbedFallback {
            StreamLog.info("PlayerScreen using preloaded \(StreamLog.truncate(preloaded.streamURL?.absoluteString))")
            info = preloaded
            youtube.play(info: preloaded, using: playback)
            reportSettled(true)
            return
        }

        info = nil
        let resolved = await youtube.prepare(videoID: videoID)
        info = resolved
        if let resolved, resolved.streamURL != nil, !resolved.usesEmbedFallback {
            StreamLog.info("PlayerScreen network resolve OK")
            youtube.play(info: resolved, using: playback)
            reportSettled(true)
        } else {
            StreamLog.error("PlayerScreen unavailable err=\(youtube.errorMessage ?? "nil")")
            reportSettled(false)
        }
    }

    private func reportSettled(_ success: Bool) {
        guard !didReportSettled else { return }
        didReportSettled = true
        onSettled?(success)
    }
}
