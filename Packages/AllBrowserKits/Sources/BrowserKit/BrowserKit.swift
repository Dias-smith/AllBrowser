import Foundation
import SwiftUI
import WebKit
import AdBlockKit
import StorageKit
import DownloadsKit

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
        title: String = "New Tab",
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
    public let downloads: DownloadService

    private var webViews: [UUID: WKWebView] = [:]
    private var ruleList: WKContentRuleList?

    /// Returns a YouTube video id when the URL should be intercepted for local playback.
    public var youtubeVideoIDFromURL: ((URL) -> String?)?
    /// Set when a YouTube video navigation is cancelled for local playback.
    @Published public var pendingLocalYouTube: PendingLocalYouTube?
    /// Video IDs allowed to load in the webview once (fallback after local play fails).
    private var passthroughYouTubeVideoIDs: Set<String> = []

    public struct PendingLocalYouTube: Equatable {
        public let videoID: String
        public let url: URL
        public let token: UUID

        public init(videoID: String, url: URL) {
            self.videoID = videoID
            self.url = url
            self.token = UUID()
        }
    }

    public init(
        bookmarks: BookmarkStore,
        history: HistoryStore,
        adBlock: AdBlockService,
        settings: SettingsStore,
        downloads: DownloadService
    ) {
        self.bookmarks = bookmarks
        self.history = history
        self.adBlock = adBlock
        self.settings = settings
        self.downloads = downloads
        let first = BrowserTab()
        self.tabs = [first]
        self.selectedTabID = first.id
    }

    public func allowNextYouTubeNavigation(videoID: String) {
        passthroughYouTubeVideoIDs.insert(videoID)
    }

    @discardableResult
    public func consumeYouTubePassthrough(videoID: String) -> Bool {
        passthroughYouTubeVideoIDs.remove(videoID) != nil
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
        let title = webView.title?.isEmpty == false ? (webView.title ?? "Page") : (webView.url?.host ?? "Page")
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

    /// Prefer the live WKWebView URL, then tab state, then address bar.
    public func currentPageURLString() -> String {
        if let live = webViews[selectedTabID]?.url?.absoluteString, !live.isEmpty {
            return live
        }
        if let tabURL = selectedTab?.urlString, !tabURL.isEmpty {
            return tabURL
        }
        return addressText
    }

    public func evaluateJavaScript(_ script: String) async -> Any? {
        let view = webView(for: selectedTabID)
        return await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result)
            }
        }
    }

    /// Copies YouTube cookies from the browser's WKWebView data store into
    /// `HTTPCookieStorage.shared` so URLSession-based resolvers share the session.
    public func syncWebsiteCookiesToSharedStorage() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let youtubeCookies = cookies.filter {
                    let domain = $0.domain.lowercased()
                    return domain.contains("youtube.com") || domain.contains("google.com") || domain.contains("youtu.be")
                }
                for cookie in youtubeCookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                print("[YT] Synced \(youtubeCookies.count) browser cookies to URLSession")
                cont.resume()
            }
        }
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

    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let tabID: UUID
        let controller: BrowserController
        private var observations: [NSKeyValueObservation] = []
        private var downloadItemIDs: [ObjectIdentifier: UUID] = [:]

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
                // Catch SPA URL changes (YouTube watch / shorts) that skip full reloads.
                webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                    guard let self else { return }
                    Task { @MainActor in
                        let urlString = webView.url?.absoluteString ?? ""
                        self.controller.updateTab(self.tabID) { tab in
                            tab.urlString = urlString
                            tab.canGoBack = webView.canGoBack
                            tab.canGoForward = webView.canGoForward
                        }
                        if self.controller.selectedTabID == self.tabID, !urlString.isEmpty {
                            self.controller.addressText = urlString
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
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            guard isMainFrame,
                  let url = navigationAction.request.url
            else {
                decisionHandler(.allow)
                return
            }

            Task { @MainActor in
                if let videoID = self.controller.youtubeVideoIDFromURL?(url) {
                    if self.controller.consumeYouTubePassthrough(videoID: videoID) {
                        decisionHandler(.allow)
                        return
                    }
                    print("[YT] Intercept YouTube navigation id=\(videoID) — cancel page load")
                    decisionHandler(.cancel)
                    self.controller.pendingLocalYouTube = .init(videoID: videoID, url: url)
                    return
                }
                decisionHandler(.allow)
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

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let response = navigationResponse.response
            let mime = response.mimeType
            let url = response.url
            let filename = response.suggestedFilename

            let looksLikeAttachment: Bool = {
                if let http = response as? HTTPURLResponse,
                   let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
                   disposition.contains("attachment") {
                    return true
                }
                return false
            }()

            if let reason = DownloadPolicy.evaluate(url: url, mimeType: mime, suggestedFilename: filename) {
                // Block AV / protected media downloads outright.
                if looksLikeAttachment || !navigationResponse.canShowMIMEType {
                    Task { @MainActor in
                        _ = controller.downloads.beginDownload(
                            sourceURL: url,
                            mimeType: mime,
                            suggestedFilename: filename
                        )
                        // beginDownload already records blocked when policy fails
                        _ = reason
                    }
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.allow)
                return
            }

            if looksLikeAttachment || !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        public func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            Task { @MainActor in
                if let began = controller.downloads.beginDownload(
                    sourceURL: response.url ?? download.originalRequest?.url,
                    mimeType: response.mimeType,
                    suggestedFilename: suggestedFilename
                ) {
                    downloadItemIDs[ObjectIdentifier(download)] = began.itemID
                    completionHandler(began.destinationURL)
                } else {
                    completionHandler(nil)
                }
            }
        }

        public func downloadDidFinish(_ download: WKDownload) {
            Task { @MainActor in
                if let id = downloadItemIDs[ObjectIdentifier(download)] {
                    controller.downloads.completeDownload(id: id)
                    downloadItemIDs[ObjectIdentifier(download)] = nil
                }
            }
        }

        public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            Task { @MainActor in
                if let id = downloadItemIDs[ObjectIdentifier(download)] {
                    controller.downloads.failDownload(id: id, message: error.localizedDescription)
                    downloadItemIDs[ObjectIdentifier(download)] = nil
                }
            }
        }
    }
}
