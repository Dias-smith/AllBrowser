import SwiftUI
import StorageKit
import AppLockKit
import AdBlockKit
import BrowserKit
import MediaKit
import PlaylistKit
import DownloadsKit
import PhotosKit
import CachePhotosKit
import StreamKit

@MainActor
final class AppEnvironment: ObservableObject {
    let settings: SettingsStore
    let bookmarks: BookmarkStore
    let history: HistoryStore
    let adBlock: AdBlockService
    let appLock: AppLockService
    let browser: BrowserController
    let playback: PlaybackController
    let playlists: PlaylistStore
    let downloads: DownloadService
    let photos: PhotosService
    let organize: PhotoOrganizeSession
    let cachePhotos: CachePhotosService
    let youtube: StreamPlaybackService

    init() {
        let settings = SettingsStore()
        let bookmarks = BookmarkStore()
        let history = HistoryStore()
        let adBlock = AdBlockService()
        let appLock = AppLockService(settings: { settings.settings })
        let downloads = DownloadService()
        let browser = BrowserController(
            bookmarks: bookmarks,
            history: history,
            adBlock: adBlock,
            settings: settings,
            downloads: downloads
        )
        let playback = PlaybackController.shared
        let playlists = PlaylistStore()
        let photos = PhotosService(reviewStore: PhotoReviewStore())
        let organize = PhotoOrganizeSession(photos: photos)
        let cachePhotos = CachePhotosService()
        let youtube = StreamPlaybackService(settings: { settings.settings })

        self.settings = settings
        self.bookmarks = bookmarks
        self.history = history
        self.adBlock = adBlock
        self.appLock = appLock
        self.browser = browser
        self.playback = playback
        self.playlists = playlists
        self.downloads = downloads
        self.photos = photos
        self.organize = organize
        self.cachePhotos = cachePhotos
        self.youtube = youtube
    }
}

@main
struct AllBrowserApp: App {
    @StateObject private var env = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .environmentObject(env.settings)
                .environmentObject(env.appLock)
                .environmentObject(env.browser)
                .environmentObject(env.playback)
                .environmentObject(env.playlists)
                .environmentObject(env.downloads)
                .environmentObject(env.photos)
                .environmentObject(env.organize)
                .environmentObject(env.cachePhotos)
                .environmentObject(env.youtube)
                .environmentObject(env.adBlock)
                .preferredColorScheme(.dark)
                .task {
                    await env.browser.refreshContentRules()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        env.appLock.handleDidEnterBackground()
                    case .active:
                        env.appLock.handleWillEnterForeground()
                    default:
                        break
                    }
                }
        }
    }
}
