import Foundation
import SwiftUI
import WebKit
import AdBlockKit
import StorageKit

public struct BrowserTab: Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var urlString: String
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var estimatedProgress: Double

    public init(
        id: UUID = UUID(),
        title: String = "新标签页",
        urlString: String = "",
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        estimatedProgress: Double = 0
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.estimatedProgress = estimatedProgress
    }
}

@MainActor
public final class BrowserController: ObservableObject {
    @Published public var tabs: [BrowserTab]
    @Published public var selectedTabID: UUID
    @Published public var addressText: String = ""
    @Published public var showTabSwitcher = false

    public let bookmarks: BookmarkStore
    public let history: HistoryStore
    public let adBlock: AdBlockService
    public let settings: SettingsStore

    private var webViews: [UUID: WKWebView] = [:]
    private var ruleList: WKContentRuleList?

    public init(
        bookmarks: BookmarkStore,
        history: HistoryStore,
        adBlock: AdBlockService,
        settings: SettingsStore
    ) {
        self.bookmarks = bookmarks
        self.history = history
        self.adBlock = adBlock
        self.settings = settings
        let first = BrowserTab()
        self.tabs = [first]
        self.selectedTabID = first.id
    }

    public var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    public func webView(for tabID: UUID) -> WKWebView {
        if let existing = webViews[tabID] {
            return existing
        }
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences
        if let ruleList {
            config.userContentController.add(ruleList)
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webViews[tabID] = webView
        return webView
    }

    public func refreshContentRules() async {
        do {
            ruleList = try await adBlock.compileRuleList(enabled: settings.settings.adBlockEnabled)
            for (id, webView) in webViews {
                webView.configuration.userContentController.removeAllContentRuleLists()
                if let ruleList {
                    let host = URL(string: tabs.first(where: { $0.id == id })?.urlString ?? "")?.host
                    if !adBlock.isWhitelisted(host: host) {
                        webView.configuration.userContentController.add(ruleList)
                    }
                }
            }
        } catch {
            // Keep browsing even if rule compilation fails.
        }
    }

    public func addTab(urlString: String? = nil) {
        let tab = BrowserTab(urlString: urlString ?? "")
        tabs.append(tab)
        selectedTabID = tab.id
        addressText = urlString ?? ""
        if let urlString, !urlString.isEmpty {
            load(urlString, in: tab.id)
        }
    }

    public func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        webViews[id]?.stopLoading()
        webViews[id] = nil
        if tabs.isEmpty {
            addTab()
        } else if selectedTabID == id {
            selectedTabID = tabs[0].id
            addressText = tabs[0].urlString
        }
    }

    public func selectTab(_ id: UUID) {
        selectedTabID = id
        addressText = tabs.first(where: { $0.id == id })?.urlString ?? ""
        showTabSwitcher = false
    }

    public func submitAddress() {
        load(addressText, in: selectedTabID)
    }

    public func load(_ raw: String, in tabID: UUID) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url: URL
        if let parsed = URL(string: trimmed), parsed.scheme != nil {
            url = parsed
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            url = URL(string: "https://\(trimmed)") ?? URL(string: "about:blank")!
        } else {
            let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            let template = settings.settings.searchEngineURLTemplate
            url = URL(string: String(format: template, query)) ?? URL(string: "https://duckduckgo.com")!
        }
        addressText = url.absoluteString
        updateTab(tabID) { tab in
            tab.urlString = url.absoluteString
            tab.isLoading = true
        }
        let webView = webView(for: tabID)
        webView.load(URLRequest(url: url))
    }

    public func goBack() {
        webView(for: selectedTabID).goBack()
    }

    public func goForward() {
        webView(for: selectedTabID).goForward()
    }

    public func reload() {
        webView(for: selectedTabID).reload()
    }

    public func updateTab(_ id: UUID, mutate: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tabs[index])
    }

    public func handleNavigationFinished(tabID: UUID, webView: WKWebView) {
        let title = webView.title?.isEmpty == false ? (webView.title ?? "页面") : (webView.url?.host ?? "页面")
        let urlString = webView.url?.absoluteString ?? ""
        updateTab(tabID) { tab in
            tab.title = title
            tab.urlString = urlString
            tab.isLoading = false
            tab.canGoBack = webView.canGoBack
            tab.canGoForward = webView.canGoForward
            tab.estimatedProgress = webView.estimatedProgress
        }
        if selectedTabID == tabID {
            addressText = urlString
        }
        if let urlString = webView.url?.absoluteString, !urlString.isEmpty {
            history.record(title: title, urlString: urlString)
        }
    }

    public func bookmarkCurrent() {
        guard let tab = selectedTab, !tab.urlString.isEmpty else { return }
        bookmarks.add(title: tab.title, urlString: tab.urlString)
    }
}

public struct BrowserWebView: UIViewRepresentable {
    public let tabID: UUID
    public let controller: BrowserController

    public init(tabID: UUID, controller: BrowserController) {
        self.tabID = tabID
        self.controller = controller
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(tabID: tabID, controller: controller)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let webView = controller.webView(for: tabID)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.observe(webView)
        if let urlString = controller.tabs.first(where: { $0.id == tabID })?.urlString,
           !urlString.isEmpty,
           webView.url == nil {
            controller.load(urlString, in: tabID)
        }
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}

    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let tabID: UUID
        let controller: BrowserController
        private var observations: [NSKeyValueObservation] = []

        init(tabID: UUID, controller: BrowserController) {
            self.tabID = tabID
            self.controller = controller
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    guard let self else { return }
                    Task { @MainActor in
                        self.controller.updateTab(self.tabID) { tab in
                            tab.estimatedProgress = webView.estimatedProgress
                            tab.isLoading = webView.isLoading
                            tab.canGoBack = webView.canGoBack
                            tab.canGoForward = webView.canGoForward
                        }
                    }
                },
                webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                    guard let self else { return }
                    Task { @MainActor in
                        self.controller.updateTab(self.tabID) { tab in
                            if let title = webView.title, !title.isEmpty {
                                tab.title = title
                            }
                        }
                    }
                },
            ]
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                controller.handleNavigationFinished(tabID: tabID, webView: webView)
            }
        }

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url?.absoluteString {
                Task { @MainActor in
                    controller.addTab(urlString: url)
                }
            }
            return nil
        }
    }
}
