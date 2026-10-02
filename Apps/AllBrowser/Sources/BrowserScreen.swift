import SwiftUI
import DesignSystem
import BrowserKit
import StorageKit
import YouTubeKit

struct BrowserScreen: View {
    @EnvironmentObject private var browser: BrowserController
    @EnvironmentObject private var settings: SettingsStore
    @State private var showBookmarks = false
    @State private var showHistory = false
    @State private var localPlayerVideo: LocalPlayerRequest?
    @State private var playerError: String?
    @State private var lastAutoPlayedVideoID: String?

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
            .sheet(item: $localPlayerVideo) { request in
                YouTubePlayerScreen(videoID: request.id, preloaded: request.preloaded) { success in
                    handleLocalPlaybackSettled(success: success, request: request)
                }
            }
            .alert("Cannot play locally", isPresented: Binding(
                get: { playerError != nil },
                set: { if !$0 { playerError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(playerError ?? "")
            }
            .onAppear {
                installYouTubeInterceptHandlers()
            }
            .onChange(of: settings.settings.youtubeOpenInLocalPlayer) { _, enabled in
                installYouTubeInterceptHandlers()
                if !enabled {
                    lastAutoPlayedVideoID = nil
                }
            }
            .onChange(of: browser.pendingLocalYouTube?.token) { _, _ in
                guard let pending = browser.pendingLocalYouTube else { return }
                browser.pendingLocalYouTube = nil
                presentLocalPlayer(
                    videoID: pending.videoID,
                    fallbackURL: pending.url.absoluteString,
                    restorePreviousOnSuccess: false
                )
            }
            .onChange(of: browser.selectedTab?.urlString) { _, newURL in
                // SPA pushState may already change the URL without a cancellable navigation.
                Task { await handleSPALocalPlayIfNeeded(urlString: newURL) }
            }
        }
    }

    private func installYouTubeInterceptHandlers() {
        guard settings.settings.youtubeOpenInLocalPlayer else {
            browser.youtubeVideoIDFromURL = nil
            return
        }
        browser.youtubeVideoIDFromURL = { url in
            YouTubeURLDetector.videoID(from: url)
        }
    }

    /// When YouTube SPA already updated the address bar, open local player and
    /// restore the previous page on success.
    private func handleSPALocalPlayIfNeeded(urlString: String?) async {
        guard settings.settings.youtubeOpenInLocalPlayer else { return }
        guard let urlString, !urlString.isEmpty,
              let id = YouTubeURLDetector.videoID(from: urlString) else { return }
        guard id != lastAutoPlayedVideoID else { return }
        guard localPlayerVideo?.id != id else { return }

        YouTubeLog.info("SPA local-play detected id=\(id)")
        presentLocalPlayer(
            videoID: id,
            fallbackURL: urlString,
            restorePreviousOnSuccess: true
        )
    }

    private func presentLocalPlayer(
        videoID: String,
        fallbackURL: String,
        restorePreviousOnSuccess: Bool
    ) {
        lastAutoPlayedVideoID = videoID
        YouTubeLog.info(
            "Present local player id=\(videoID) restorePrev=\(restorePreviousOnSuccess) fallback=\(YouTubeLog.truncate(fallbackURL))"
        )
        localPlayerVideo = LocalPlayerRequest(
            id: videoID,
            preloaded: nil,
            fallbackURL: fallbackURL,
            restorePreviousOnSuccess: restorePreviousOnSuccess
        )
    }

    private func handleLocalPlaybackSettled(success: Bool, request: LocalPlayerRequest) {
        if success {
            YouTubeLog.info("Local play success — stay in player, skip page playback")
            if request.restorePreviousOnSuccess,
               YouTubeURLDetector.videoID(from: browser.currentPageURLString()) == request.id {
                browser.goBack()
            }
            return
        }

        YouTubeLog.info("Local play failed — fallback to page \(YouTubeLog.truncate(request.fallbackURL))")
        localPlayerVideo = nil
        browser.allowNextYouTubeNavigation(videoID: request.id)
        // Keep lastAutoPlayedVideoID so SPA onChange won't immediately re-open local player.
        browser.load(request.fallbackURL, in: browser.selectedTabID)
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
                Toggle("Play YouTube locally", isOn: Binding(
                    get: { settings.settings.youtubeOpenInLocalPlayer },
                    set: { value in settings.update { $0.youtubeOpenInLocalPlayer = value } }
                ))
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

    private func handleAutoLocalPlayIfNeeded(urlString: String?) async {
        // Kept as no-op path name for older call sites; SPA uses handleSPALocalPlayIfNeeded.
        await handleSPALocalPlayIfNeeded(urlString: urlString)
    }

    private func openLocalYouTubePlayer(preferredID: String? = nil) async {
        let id: String
        if let preferredID {
            id = preferredID
        } else if let resolved = await resolveCurrentYouTubeVideoID() {
            id = resolved
        } else {
            YouTubeLog.error("openLocalYouTubePlayer — no video id")
            playerError = "Open a YouTube video page first, then try again."
            return
        }
        let fallback = browser.currentPageURLString().isEmpty
            ? "https://m.youtube.com/watch?v=\(id)"
            : browser.currentPageURLString()
        presentLocalPlayer(
            videoID: id,
            fallbackURL: fallback,
            restorePreviousOnSuccess: false
        )
    }

    private func resolveCurrentYouTubeVideoID() async -> String? {
        let pageURL = browser.currentPageURLString()
        if let id = YouTubeURLDetector.videoID(from: pageURL) {
            return id
        }
        if let id = YouTubeURLDetector.videoID(from: browser.addressText) {
            return id
        }

        // YouTube mobile SPA sometimes keeps a short URL in the bar; ask the page.
        let script = """
        (function() {
          try {
            var href = location.href || '';
            var u = new URL(href);
            var v = u.searchParams.get('v');
            if (v) return v;
            var parts = u.pathname.split('/').filter(Boolean);
            var keys = ['shorts', 'embed', 'live', 'v'];
            for (var i = 0; i < parts.length; i++) {
              if (keys.indexOf(parts[i]) >= 0 && parts[i + 1]) return parts[i + 1];
            }
            if (window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.videoDetails) {
              return window.ytInitialPlayerResponse.videoDetails.videoId || null;
            }
            var player = document.querySelector('ytd-watch-flexy, ytm-watch');
            if (player && player.getAttribute('video-id')) return player.getAttribute('video-id');
          } catch (e) {}
          return null;
        })();
        """
        if let raw = await browser.evaluateJavaScript(script) as? String {
            return YouTubeURLDetector.videoID(from: "https://www.youtube.com/watch?v=\(raw)") ?? raw
        }
        return nil
    }

    /// Pulls a playable URL from the visible tab. Prefers an in-page Innertube
    /// `/player` call (same cookies that already passed bot checks), then DOM /
    /// script scraping.
    private func extractStreamFromCurrentPage(videoID: String) async -> YouTubeVideoInfo? {
        let playerAPIScript = """
        (async function(videoId) {
          var cfg = (window.ytcfg && window.ytcfg.data_) || {};
          var clients = [
            {
              clientName: 'IOS',
              clientVersion: '19.45.4',
              clientNameHeader: '5',
              userAgent: 'com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)'
            },
            {
              clientName: 'ANDROID',
              clientVersion: '19.28.35',
              clientNameHeader: '3',
              userAgent: 'com.google.android.youtube/19.28.35 (Linux; U; Android 13) gzip'
            },
            {
              clientName: 'MWEB',
              clientVersion: cfg.INNERTUBE_CLIENT_VERSION || '2.20250321.00.00',
              clientNameHeader: String(cfg.INNERTUBE_CONTEXT_CLIENT_NAME || '2'),
              userAgent: null
            }
          ];
          var lastDiag = null;
          for (var i = 0; i < clients.length; i++) {
            var c = clients[i];
            var context = (c.clientName === 'MWEB' && cfg.INNERTUBE_CONTEXT)
              ? cfg.INNERTUBE_CONTEXT
              : { client: {
                  clientName: c.clientName,
                  clientVersion: c.clientVersion,
                  hl: 'en',
                  gl: 'US'
                } };
            if (c.userAgent) context.client.userAgent = c.userAgent;
            if (c.clientName === 'IOS') {
              context.client.deviceMake = 'Apple';
              context.client.deviceModel = 'iPhone';
              context.client.osName = 'iPhone';
              context.client.osVersion = '17.5.1';
              context.client.platform = 'MOBILE';
            }
            var body = {
              context: context,
              videoId: videoId,
              playbackContext: {
                contentPlaybackContext: {
                  html5Preference: 'HTML5_PREF_WANTS',
                  signatureTimestamp: cfg.STS || cfg.SIGNATURE_TIMESTAMP
                }
              },
              contentCheckOk: true,
              racyCheckOk: true
            };
            try {
              var headers = { 'Content-Type': 'application/json' };
              headers['X-YouTube-Client-Name'] = c.clientNameHeader;
              headers['X-YouTube-Client-Version'] = context.client.clientVersion;
              var res = await fetch('/youtubei/v1/player?prettyPrint=false', {
                method: 'POST',
                credentials: 'same-origin',
                headers: headers,
                body: JSON.stringify(body)
              });
              var text = await res.text();
              var parsed = null;
              try { parsed = JSON.parse(text); } catch (e) {}
              var sd = parsed && parsed.streamingData;
              var status = parsed && parsed.playabilityStatus && parsed.playabilityStatus.status;
              var reason = parsed && parsed.playabilityStatus && parsed.playabilityStatus.reason;
              var hasHls = !!(sd && sd.hlsManifestUrl);
              var formats = ((sd && sd.formats) || []).concat((sd && sd.adaptiveFormats) || []);
              var withURL = 0;
              for (var f = 0; f < formats.length; f++) {
                if (formats[f].url) withURL++;
              }
              lastDiag = {
                kind: 'diag',
                client: c.clientName,
                httpStatus: res.status,
                playability: status || '',
                reason: reason || '',
                formats: formats.length,
                withURL: withURL,
                hls: hasHls,
                bytes: text.length
              };
              if (sd && (hasHls || withURL > 0)) {
                return JSON.stringify({
                  kind: 'player',
                  json: text,
                  client: c.clientName,
                  httpStatus: res.status,
                  playability: status || '',
                  withURL: withURL,
                  hls: hasHls
                });
              }
            } catch (e) {
              lastDiag = { kind: 'diag', client: c.clientName, error: String(e) };
            }
          }
          return lastDiag ? JSON.stringify(lastDiag) : null;
        })('\(videoID)');
        """
        if let raw = await browser.evaluateJavaScript(playerAPIScript) as? String {
            YouTubeLog.info("in-page playerAPI raw=\(YouTubeLog.truncate(raw, limit: 240))")
            if let info = decodePageExtractPayload(raw, videoID: videoID) {
                return info
            }
        }

        let script = """
        (function() {
          function braceJSON(text, start) {
            var depth = 0, inStr = false, esc = false;
            for (var j = start; j < text.length; j++) {
              var c = text.charAt(j);
              if (inStr) {
                if (esc) esc = false;
                else if (c === '\\\\') esc = true;
                else if (c === '"') inStr = false;
              } else {
                if (c === '"') inStr = true;
                else if (c === '{') depth++;
                else if (c === '}') {
                  depth--;
                  if (depth === 0) return text.substring(start, j + 1);
                }
              }
            }
            return null;
          }
          function metaTitle() {
            try {
              var t = document.querySelector('meta[name="title"], meta[property="og:title"]');
              if (t && t.content) return t.content;
            } catch (e) {}
            return document.title || 'YouTube';
          }
          function pickVideoURL() {
            var videos = document.querySelectorAll('video');
            for (var i = 0; i < videos.length; i++) {
              var v = videos[i];
              var src = v.currentSrc || v.src || '';
              if (src && src.indexOf('blob:') !== 0 && /^https?:/i.test(src)) return src;
              var sources = v.querySelectorAll('source');
              for (var j = 0; j < sources.length; j++) {
                var s = sources[j].src || '';
                if (s && s.indexOf('blob:') !== 0 && /^https?:/i.test(s)) return s;
              }
            }
            return null;
          }
          function fromScripts() {
            var scripts = document.getElementsByTagName('script');
            for (var i = 0; i < scripts.length; i++) {
              var text = scripts[i].textContent || '';
              var key = 'ytInitialPlayerResponse';
              var idx = text.indexOf(key);
              if (idx < 0) continue;
              var eq = text.indexOf('=', idx);
              if (eq < 0) continue;
              var start = text.indexOf('{', eq);
              if (start < 0) continue;
              var blob = braceJSON(text, start);
              if (!blob) continue;
              try {
                var obj = JSON.parse(blob);
                if (obj && (obj.streamingData || obj.videoDetails)) return blob;
              } catch (e) {}
            }
            return null;
          }

          var direct = pickVideoURL();
          if (direct) {
            return JSON.stringify({ kind: 'direct', url: direct, title: metaTitle() });
          }

          try {
            if (window.ytInitialPlayerResponse &&
                (window.ytInitialPlayerResponse.streamingData || window.ytInitialPlayerResponse.videoDetails)) {
              return JSON.stringify({ kind: 'player', json: JSON.stringify(window.ytInitialPlayerResponse) });
            }
          } catch (e) {}

          var fromScript = fromScripts();
          if (fromScript) {
            return JSON.stringify({ kind: 'player', json: fromScript });
          }
          return null;
        })();
        """

        if let raw = await browser.evaluateJavaScript(script) as? String,
           let info = decodePageExtractPayload(raw, videoID: videoID) {
            return info
        }
        return nil
    }

    private func decodePageExtractPayload(_ raw: String, videoID: String) -> YouTubeVideoInfo? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["kind"] as? String else {
            do {
                return try YouTubePlayerResponseMapper.videoInfo(videoID: videoID, playerJSON: raw)
            } catch {
                YouTubeLog.error("decode raw player JSON failed", error: error)
                return nil
            }
        }

        if kind == "diag" {
            YouTubeLog.info(
                "in-page playerAPI diag client=\(obj["client"] ?? "") status=\(obj["httpStatus"] ?? "") playability=\(obj["playability"] ?? "") reason=\(obj["reason"] ?? "") formats=\(obj["formats"] ?? "") withURL=\(obj["withURL"] ?? "") hls=\(obj["hls"] ?? "") error=\(obj["error"] ?? "")"
            )
            return nil
        }

        if kind == "direct",
           let urlString = obj["url"] as? String,
           let url = URL(string: urlString),
           url.scheme?.hasPrefix("http") == true {
            let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return YouTubePlayerResponseMapper.videoInfo(
                videoID: videoID,
                title: (title?.isEmpty == false ? title! : "YouTube"),
                streamURL: url
            )
        }

        if kind == "player", let json = obj["json"] as? String {
            YouTubeLog.info(
                "in-page player payload client=\(obj["client"] ?? "?") http=\(obj["httpStatus"] ?? "?") withURL=\(obj["withURL"] ?? "?") hls=\(obj["hls"] ?? "?")"
            )
            do {
                return try YouTubePlayerResponseMapper.videoInfo(videoID: videoID, playerJSON: json)
            } catch {
                YouTubeLog.error("in-page player JSON not playable", error: error)
                return nil
            }
        }
        return nil
    }
}

private struct LocalPlayerRequest: Identifiable {
    let id: String
    var preloaded: YouTubeVideoInfo?
    var fallbackURL: String
    /// When true (SPA already navigated), goBack() after local play succeeds.
    var restorePreviousOnSuccess: Bool
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
