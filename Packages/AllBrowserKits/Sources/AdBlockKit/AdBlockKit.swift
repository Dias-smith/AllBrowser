import Foundation
import StorageKit

#if canImport(WebKit)
import WebKit
#endif

public struct AdBlockRulePack: Codable, Equatable {
    public var version: String
    public var updatedAt: Date
    public var domains: [String]

    public static let bundled = AdBlockRulePack(
        version: "1.0.0-bundled",
        updatedAt: Date(timeIntervalSince1970: 0),
        domains: [
            "doubleclick.net",
            "googlesyndication.com",
            "googleadservices.com",
            "adservice.google.com",
            "pagead2.googlesyndication.com",
            "ads.yahoo.com",
            "adnxs.com",
            "adsrvr.org",
            "facebook.com/tr",
            "scorecardresearch.com",
            "taboola.com",
            "outbrain.com",
            "criteo.com",
            "amazon-adsystem.com",
            "moatads.com",
            "adsafeprotected.com",
        ]
    )
}

@MainActor
public final class AdBlockService: ObservableObject {
    @Published public private(set) var pack: AdBlockRulePack
    @Published public private(set) var blockedThisSession: Int = 0
    @Published public var whitelistHosts: Set<String> = []

    private let packStore = JSONStore<AdBlockRulePack>(filename: "adblock-pack.json")
    private let whitelistStore = JSONStore<[String]>(filename: "adblock-whitelist.json")

    public init() {
        pack = packStore.load(default: .bundled)
        whitelistHosts = Set(whitelistStore.load(default: []))
    }

    public func resetSessionCounter() {
        blockedThisSession = 0
    }

    public func recordBlock() {
        blockedThisSession += 1
    }

    public func toggleWhitelist(host: String) {
        if whitelistHosts.contains(host) {
            whitelistHosts.remove(host)
        } else {
            whitelistHosts.insert(host)
        }
        try? whitelistStore.save(Array(whitelistHosts).sorted())
    }

    public func isWhitelisted(host: String?) -> Bool {
        guard let host else { return false }
        return whitelistHosts.contains(host)
    }

    public func contentRuleJSON(enabled: Bool) -> String {
        guard enabled else {
            return "[]"
        }
        var rules: [[String: Any]] = []
        for domain in pack.domains {
            rules.append([
                "trigger": [
                    "url-filter": domain.replacingOccurrences(of: ".", with: "\\."),
                    "resource-type": ["script", "image", "raw", "style-sheet", "media", "popup"],
                ],
                "action": ["type": "block"],
            ])
        }
        // Hide common ad containers (best effort)
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": [
                "type": "css-display-none",
                "selector": ".adsbygoogle, .ad-banner, .advertisement, [id*='google_ads'], [class*='ad-slot']",
            ],
        ])
        let data = try? JSONSerialization.data(withJSONObject: rules, options: [])
        return String(data: data ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

#if canImport(WebKit)
    public func compileRuleList(enabled: Bool) async throws -> WKContentRuleList? {
        guard enabled else { return nil }
        let json = contentRuleJSON(enabled: true)
        return try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "AllBrowserAdBlock",
                encodedContentRuleList: json
            ) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: list)
                }
            }
        }
    }
#endif

    public func exportBlockerListJSON(enabled: Bool) -> Data {
        Data(contentRuleJSON(enabled: enabled).utf8)
    }

    public func reloadBundledRules() {
        pack = .bundled
        try? packStore.save(pack)
    }
}
