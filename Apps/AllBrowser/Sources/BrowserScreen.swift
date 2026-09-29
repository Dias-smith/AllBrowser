import SwiftUI
import DesignSystem
import BrowserKit
import YouTubeKit
import StorageKit

struct BrowserScreen: View {
    @EnvironmentObject private var browser: BrowserController
    @EnvironmentObject private var youtube: YouTubePlaybackService
    @EnvironmentObject private var settings: SettingsStore
    @State private var showBookmarks = false
    @State private var showHistory = false
    @State private var youtubeVideoID: String?
    @State private var showYouTubePlayer = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                if let tab = browser.selectedTab, tab.isLoading {
                    ProgressView(value: tab.estimatedProgress)
                        .tint(ABColor.accent)
                }
                ZStack {
                    if let tabID = browser.tabs.first(where: { $0.id == browser.selectedTabID })?.id {
                        BrowserWebView(tabID: tabID, controller: browser)
                            .id(tabID)
                    }
                    if browser.selectedTab?.urlString.isEmpty != false {
                        startPage
                    }
                }
                toolbar
            }
            .background(ABColor.background)
            .navigationBarHidden(true)
            .sheet(isPresented: $browser.showTabSwitcher) {
                TabSwitcherView()
            }
            .sheet(isPresented: $showBookmarks) {
                BookmarkListView()
            }
            .sheet(isPresented: $showHistory) {
                HistoryListView()
            }
            .sheet(isPresented: $showYouTubePlayer) {
                if let youtubeVideoID {
                    YouTubePlayerScreen(videoID: youtubeVideoID)
                }
            }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 10) {
            TextField("搜索或输入网址", text: $browser.addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .padding(10)
                .background(ABColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onSubmit { browser.submitAddress() }

            Button {
                openYouTubeIfNeeded()
            } label: {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(ABColor.accentSecondary)
            }
            .accessibilityLabel("YouTube 增强播放")

            Button {
                browser.showTabSwitcher = true
            } label: {
                Text("\(browser.tabs.count)")
                    .font(ABFont.mono(13))
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(ABColor.textPrimary, lineWidth: 1.5)
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ABColor.surfaceElevated)
    }

    private var toolbar: some View {
        HStack {
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!(browser.selectedTab?.canGoBack ?? false))
            Spacer()
            Button { browser.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!(browser.selectedTab?.canGoForward ?? false))
            Spacer()
            Button { browser.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            Spacer()
            Button { browser.bookmarkCurrent() } label: {
                Image(systemName: "book")
            }
            Spacer()
            Menu {
                Button("书签") { showBookmarks = true }
                Button("历史") { showHistory = true }
                Button("新标签页") { browser.addTab() }
                Button("YouTube 播放") { openYouTubeIfNeeded() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .foregroundStyle(ABColor.textPrimary)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(ABColor.surfaceElevated)
    }

    private var startPage: some View {
        VStack(spacing: 20) {
            Text("AllBrowser")
                .font(ABFont.display(36))
                .foregroundStyle(ABColor.textPrimary)
            Text("隐私浏览 · 媒体中枢 · 本地管理")
                .font(ABFont.body(14))
                .foregroundStyle(ABColor.textSecondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                quickLink(title: "DuckDuckGo", url: "https://duckduckgo.com")
                quickLink(title: "Wikipedia", url: "https://wikipedia.org")
                quickLink(title: "YouTube", url: "https://m.youtube.com")
                quickLink(title: "Apple", url: "https://www.apple.com")
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ABColor.background.opacity(0.92))
    }

    private func quickLink(title: String, url: String) -> some View {
        Button {
            browser.load(url, in: browser.selectedTabID)
        } label: {
            Text(title)
                .font(ABFont.title(15))
                .foregroundStyle(ABColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(ABColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func openYouTubeIfNeeded() {
        let candidate = browser.addressText.isEmpty
            ? (browser.selectedTab?.urlString ?? "")
            : browser.addressText
        if let id = YouTubeURLDetector.videoID(from: candidate) {
            youtubeVideoID = id
            showYouTubePlayer = true
        } else if let id = YouTubeURLDetector.videoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
                  candidate.isEmpty {
            youtubeVideoID = id
            showYouTubePlayer = true
        } else {
            // Try current page; if not YouTube, open YouTube home in browser.
            browser.load("https://m.youtube.com", in: browser.selectedTabID)
        }
    }
}

struct TabSwitcherView: View {
    @EnvironmentObject private var browser: BrowserController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(browser.tabs) { tab in
                    Button {
                        browser.selectTab(tab.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tab.title).foregroundStyle(ABColor.textPrimary)
                            Text(tab.urlString)
                                .font(.caption)
                                .foregroundStyle(ABColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            browser.closeTab(tab.id)
                        } label: {
                            Label("关闭", systemImage: "xmark")
                        }
                    }
                }
            }
            .navigationTitle("标签页")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        browser.addTab()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}

struct BookmarkListView: View {
    @EnvironmentObject private var browser: BrowserController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(browser.bookmarks.items) { item in
                    Button {
                        browser.load(item.urlString, in: browser.selectedTabID)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(item.urlString).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        browser.bookmarks.remove(id: browser.bookmarks.items[index].id)
                    }
                }
            }
            .navigationTitle("书签")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct HistoryListView: View {
    @EnvironmentObject private var browser: BrowserController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(browser.history.items) { item in
                    Button {
                        browser.load(item.urlString, in: browser.selectedTabID)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(item.urlString).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("历史")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清空") { browser.history.clear() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
