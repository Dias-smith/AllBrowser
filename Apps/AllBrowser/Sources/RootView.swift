import SwiftUI
import DesignSystem
import MediaKit
import AppLockKit

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var appLock: AppLockService
    @EnvironmentObject private var playback: PlaybackController
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            ABColor.background.ignoresSafeArea()

            TabView(selection: $selectedTab) {
                BrowserScreen()
                    .tabItem { Label("浏览", systemImage: "globe") }
                    .tag(0)

                MediaLibraryScreen()
                    .tabItem { Label("媒体", systemImage: "play.square.stack") }
                    .tag(1)

                FilesScreen()
                    .tabItem { Label("文件", systemImage: "folder") }
                    .tag(2)

                PhotosScreen()
                    .tabItem { Label("照片", systemImage: "photo.on.rectangle") }
                    .tag(3)

                SettingsScreen()
                    .tabItem { Label("我的", systemImage: "person.crop.circle") }
                    .tag(4)
            }
            .tint(ABColor.accent)

            VStack {
                Spacer()
                MiniPlayerBar(playback: playback)
                    .padding(.bottom, 49)
            }
            .allowsHitTesting(playback.currentItem != nil)

            if appLock.isLocked {
                AppLockScreen()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .sheet(isPresented: $playback.isPlayerPresented) {
            FullPlayerScreen()
        }
    }
}
