import SwiftUI
import DesignSystem
import BrowserKit

struct BrowserScreen: View {
    @EnvironmentObject private var browser: BrowserController
    @State private var showBookmarks = false
    @State private var showHistory = false

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
        }
    }

    private var addressBar: some View {
        HStack(spacing: 10) {
            TextField("Search or enter URL", text: $browser.addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .padding(10)
                .background(ABColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onSubmit { browser.submitAddress() }

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
            Button { browser.addTab() } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New Tab")
            Spacer()
            Menu {
                Button("Add Bookmark") { browser.bookmarkCurrent() }
                Button("Bookmarks") { showBookmarks = true }
                Button("History") { showHistory = true }
                Button("New Tab") { browser.addTab() }
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
            Text("Private browsing · Media hub · Local management")
                .font(ABFont.body(14))
                .foregroundStyle(ABColor.textSecondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                quickLink(title: "Google", url: "https://www.google.com")
                quickLink(title: "Facebook", url: "https://www.facebook.com")
                quickLink(title: "YouTube", url: "https://m.youtube.com")
                quickLink(title: "Amazon", url: "https://www.amazon.com")
                quickLink(title: "Instagram", url: "https://www.instagram.com")
                quickLink(title: "TikTok", url: "https://www.tiktok.com")
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
                            Label("Close", systemImage: "xmark")
                        }
                    }
                }
            }
            .navigationTitle("Tabs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
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
            .navigationTitle("Bookmarks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
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
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { browser.history.clear() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
