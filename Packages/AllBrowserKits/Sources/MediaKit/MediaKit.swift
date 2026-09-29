import AVFoundation
import AVKit
import Combine
import MediaPlayer
import SwiftUI

public struct MediaItem: Identifiable, Equatable, Hashable, Codable {
    public var id: UUID
    public var title: String
    public var artist: String
    public var artworkURL: URL?
    public var sourceURL: URL
    public var duration: TimeInterval?

    public init(
        id: UUID = UUID(),
        title: String,
        artist: String = "",
        artworkURL: URL? = nil,
        sourceURL: URL,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.sourceURL = sourceURL
        self.duration = duration
    }
}

@MainActor
public final class PlaybackController: ObservableObject {
    public static let shared = PlaybackController()

    @Published public private(set) var currentItem: MediaItem?
    @Published public private(set) var isPlaying = false
    @Published public var rate: Float = 1.0 {
        didSet { applyRate() }
    }
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public var isPlayerPresented = false

    public let player = AVPlayer()
    private var timeObserver: Any?
    private var pipController: AVPictureInPictureController?
    private var cancellables = Set<AnyCancellable>()

    public init() {
        configureAudioSession()
        configureRemoteCommands()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds
                if let item = self?.player.currentItem {
                    self?.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
    }

    public func play(_ item: MediaItem) {
        currentItem = item
        let playerItem = AVPlayerItem(url: item.sourceURL)
        player.replaceCurrentItem(with: playerItem)
        applyRate()
        player.play()
        isPlaying = true
        isPlayerPresented = true
        updateNowPlaying()
    }

    public func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            applyRate()
            isPlaying = true
        }
        updateNowPlaying()
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentItem = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    public func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time)
    }

    public func enablePictureInPicture(with layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        pipController = AVPictureInPictureController(playerLayer: layer)
    }

    public func startPictureInPicture() {
        pipController?.startPictureInPicture()
    }

    private func applyRate() {
        if isPlaying {
            player.rate = rate
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try session.setActive(true)
        } catch {}
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player.play()
                self?.isPlaying = true
                self?.updateNowPlaying()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player.pause()
                self?.isPlaying = false
                self?.updateNowPlaying()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayPause()
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                self?.seek(to: event.positionTime)
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let item = currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

public struct PlayerLayerView: UIViewRepresentable {
    public let player: AVPlayer
    public var onLayer: ((AVPlayerLayer) -> Void)?

    public init(player: AVPlayer, onLayer: ((AVPlayerLayer) -> Void)? = nil) {
        self.player = player
        self.onLayer = onLayer
    }

    public func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        onLayer?(view.playerLayer)
        return view
    }

    public func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    public final class PlayerUIView: UIView {
        override public class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

public struct MiniPlayerBar: View {
    @ObservedObject var playback: PlaybackController

    public init(playback: PlaybackController) {
        self.playback = playback
    }

    public var body: some View {
        if let item = playback.currentItem {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(item.artist.isEmpty ? "正在播放" : item.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
                Button {
                    playback.isPlayerPresented = true
                } label: {
                    Image(systemName: "chevron.up")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }
}
