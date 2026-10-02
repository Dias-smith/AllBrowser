import Foundation
import UIKit
import WebKit

/// Hosts `bridge-ios.html` + `resolution.js` in a hidden WKWebView and implements
/// the `AndroidBridge` / Flutter message APIs the extractor expects.
@MainActor
public final class StreamJSExtractor: NSObject {
    public static let shared = StreamJSExtractor()

    private var webView: WKWebView?
    private var isBooted = false
    private var bootContinuations: [CheckedContinuation<Void, Error>] = []
    private var pendingExtract: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var visitorData: String = ""
    private let session: URLSession
    private let ephemeralSession: URLSession

    private override init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config)

        let ephemeral = URLSessionConfiguration.ephemeral
        ephemeral.httpCookieAcceptPolicy = .never
        ephemeral.httpShouldSetCookies = false
        ephemeralSession = URLSession(configuration: ephemeral)

        super.init()
    }

    public func extract(watchURL: String) async throws -> [String: Any] {
        StreamLog.info("JSExtractor extract begin \(watchURL)")
        try await ensureBooted()
        StreamLog.info("JSExtractor booted visitorData=\(StreamLog.truncate(visitorData, limit: 40))")
        let uid = UUID().uuidString
        let payload: [String: Any] = [
            "uid": uid,
            "event": 0, // Extract
            "source": 0, // YTB
            "data": ["url": watchURL],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            throw StreamJSExtractorError.invalidPayload
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            pendingExtract[uid] = cont
            StreamLog.info("JSExtractor postMessage uid=\(uid)")

            let b64 = Data(json.utf8).base64EncodedString()
            // Always return a plain string — postMessageToJSBridge may return a Promise /
            // object that WKWebView rejects as "unsupported type", which previously
            // aborted the pending extract before sendMessageToNative arrived.
            let js = """
            (function(){
              try {
                if (!window.extractor || !extractor.postMessageToJSBridge) {
                  return 'ERR:extractor not ready';
                }
                var raw = atob('\(b64)');
                extractor.postMessageToJSBridge(raw);
                return 'OK';
              } catch (e) {
                return 'ERR:' + (e && e.message ? e.message : e);
              }
            })();
            """
            webView?.evaluateJavaScript(js) { [weak self] result, error in
                Task { @MainActor in
                    if let text = result as? String, text.hasPrefix("ERR:") {
                        StreamLog.error("JSExtractor bridge ERR \(text)")
                        self?.failExtract(
                            uid: uid,
                            error: StreamJSExtractorError.message(String(text.dropFirst(4)))
                        )
                        return
                    }
                    if let error {
                        // Ignore unsupported-type / void results; async result comes via bridge.
                        let ns = error as NSError
                        let msg = ns.localizedDescription.lowercased()
                        if ns.domain == WKError.errorDomain,
                           msg.contains("unsupported type") || ns.code == 5 {
                            StreamLog.info("JSExtractor evaluateJS non-fatal: \(ns.localizedDescription)")
                            return
                        }
                        StreamLog.error("JSExtractor evaluateJS failed", error: error)
                        self?.failExtract(uid: uid, error: error)
                        return
                    }
                    StreamLog.info("JSExtractor postMessage accepted result=\(String(describing: result))")
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                if self.pendingExtract[uid] != nil {
                    StreamLog.error("JSExtractor timeout uid=\(uid)")
                    self.failExtract(uid: uid, error: StreamJSExtractorError.timeout)
                }
            }
        }
    }

    private func ensureBooted() async throws {
        if isBooted { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            bootContinuations.append(cont)
            if webView == nil {
                bootWebView()
            }
        }
    }

    private func bootWebView() {
        StreamLog.info("JSExtractor bootWebView start")
        let controller = WKUserContentController()
        controller.add(self, name: "AndroidBridge")
        controller.add(self, name: "flutterRequest")
        controller.add(self, name: "callbackFlutterExtract")

        // Fallback Flutter channel if resolution.js does not take the vsplayer path.
        let flutterPolyfill = """
        window.flutterRequest = window.flutterRequest || {
          postMessage: function(msg) {
            window.webkit.messageHandlers.flutterRequest.postMessage(String(msg));
          }
        };
        window.callbackFlutterExtract = window.callbackFlutterExtract || {
          postMessage: function(msg) {
            window.webkit.messageHandlers.callbackFlutterExtract.postMessage(
              typeof msg === 'string' ? msg : JSON.stringify(msg)
            );
          }
        };
        """
        controller.addUserScript(WKUserScript(source: flutterPolyfill, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .default()

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: config)
        view.isHidden = true
        view.navigationDelegate = self
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        webView = view

        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first {
            view.frame = CGRect(x: -2, y: -2, width: 1, height: 1)
            view.alpha = 0.01
            window.addSubview(view)
        }

        guard let htmlURL = Bundle.module.url(forResource: "bridge-ios", withExtension: "html") else {
            StreamLog.error("JSExtractor missing bridge-ios.html in bundle")
            finishBoot(error: StreamJSExtractorError.missingScript)
            return
        }
        let accessURL = htmlURL.deletingLastPathComponent()
        StreamLog.info("JSExtractor loadFileURL \(htmlURL.lastPathComponent) access=\(accessURL.path)")
        view.loadFileURL(htmlURL, allowingReadAccessTo: accessURL)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !self.isBooted, !self.bootContinuations.isEmpty {
                StreamLog.error("JSExtractor boot timeout (no onExtractorReady)")
                self.finishBoot(error: StreamJSExtractorError.scriptNotReady)
            }
        }
    }

    private func finishBoot(error: Error?) {
        let conts = bootContinuations
        bootContinuations.removeAll()
        if let error {
            StreamLog.error("JSExtractor boot failed", error: error)
            conts.forEach { $0.resume(throwing: error) }
        } else {
            StreamLog.info("JSExtractor boot ready")
            isBooted = true
            conts.forEach { $0.resume() }
            syncVisitorDataToJS()
        }
    }

    private func failExtract(uid: String, error: Error) {
        guard let cont = pendingExtract.removeValue(forKey: uid) else { return }
        cont.resume(throwing: error)
    }

    // MARK: - AndroidBridge

    private func handleAndroidBridge(_ body: Any) {
        let obj: [String: Any]
        if let dict = body as? [String: Any] {
            obj = dict
        } else if let text = body as? String,
                  let data = text.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = dict
        } else {
            return
        }

        let method = (obj["method"] as? String) ?? ""
        switch method {
        case "onExtractorReady":
            StreamLog.info("AndroidBridge onExtractorReady")
            finishBoot(error: nil)

        case "onExtractorError":
            let message = (obj["message"] as? String)?.nilIfEmpty
                ?? StreamJSExtractorError.scriptNotReady.localizedDescription
            StreamLog.error("AndroidBridge onExtractorError \(message)")
            finishBoot(error: StreamJSExtractorError.message(message))

        case "requestWithCallback":
            let callbackId = (obj["callbackId"] as? String) ?? ""
            let urlString = (obj["url"] as? String) ?? ""
            let httpMethod = (obj["httpMethod"] as? String) ?? "GET"
            let headersJSON = (obj["headers"] as? String) ?? "{}"
            let bodyString = (obj["body"] as? String) ?? ""
            let optionsJSON = (obj["options"] as? String) ?? "{}"
            StreamLog.info("AndroidBridge request \(httpMethod) \(StreamLog.truncate(urlString)) id=\(callbackId)")
            Task { @MainActor in
                await self.performBridgeRequest(
                    callbackId: callbackId,
                    urlString: urlString,
                    httpMethod: httpMethod,
                    headersJSON: headersJSON,
                    bodyString: bodyString,
                    optionsJSON: optionsJSON
                )
            }

        case "sendMessageToNative":
            let preview = StreamLog.truncate(String(describing: obj["message"]), limit: 220)
            StreamLog.info("AndroidBridge sendMessageToNative \(preview)")
            handleExtractCallback(obj["message"] ?? "")

        case "queryUserInfo":
            let callbackId = (obj["callbackId"] as? String) ?? ""
            StreamLog.info("AndroidBridge queryUserInfo id=\(callbackId)")
            invokeJSCallback(callbackId: callbackId, success: true, result: "{}", errCode: 0, errMsg: "")

        case "queryFIRRemoteConfigThen":
            let callbackId = (obj["callbackId"] as? String) ?? ""
            StreamLog.info("AndroidBridge queryFIRRemoteConfig key=\(obj["key"] ?? "") id=\(callbackId)")
            invokeJSCallback(callbackId: callbackId, success: true, result: "", errCode: 0, errMsg: "")

        default:
            StreamLog.info("AndroidBridge unknown method=\(method)")
        }
    }

    private func performBridgeRequest(
        callbackId: String,
        urlString: String,
        httpMethod: String,
        headersJSON: String,
        bodyString: String,
        optionsJSON: String
    ) async {
        guard !callbackId.isEmpty, let url = URL(string: urlString) else {
            invokeJSCallback(callbackId: callbackId, success: false, result: nil, errCode: -1, errMsg: "Invalid request")
            return
        }

        let headers = (try? JSONSerialization.jsonObject(with: Data(headersJSON.utf8))) as? [String: Any] ?? [:]
        let options = (try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? [String: Any] ?? [:]
        let withoutCookie = {
            if let n = options["withoutCookie"] as? Int { return n != 0 }
            if let b = options["withoutCookie"] as? Bool { return b }
            if let s = options["withoutCookie"] as? String { return s == "1" || s.lowercased() == "true" }
            return false
        }()

        var request = URLRequest(url: url)
        request.httpMethod = httpMethod.uppercased()
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue("\(value)", forHTTPHeaderField: key)
        }
        if !bodyString.isEmpty {
            request.httpBody = bodyString.data(using: .utf8)
        }

        let activeSession = withoutCookie ? ephemeralSession : session
        do {
            let (data, response) = try await activeSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let success = (200..<400).contains(status)
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""

            let botHit = text.localizedCaseInsensitiveContains("Sign in to confirm")
                || text.localizedCaseInsensitiveContains("not a bot")
            StreamLog.info(
                "AndroidBridge response status=\(status) bytes=\(data.count) success=\(success) bot=\(botHit) withoutCookie=\(withoutCookie) id=\(callbackId)"
            )

            if success {
                updateVisitorData(from: text)
            }

            invokeJSCallback(
                callbackId: callbackId,
                success: success,
                result: text,
                errCode: success ? 0 : status,
                errMsg: success ? "" : "HTTP \(status)"
            )
        } catch {
            StreamLog.error("AndroidBridge request failed id=\(callbackId)", error: error)
            invokeJSCallback(
                callbackId: callbackId,
                success: false,
                result: nil,
                errCode: -1,
                errMsg: error.localizedDescription
            )
        }
    }

    /// Stores the response body in `__requestResults` then invokes the JS callback.
    /// Passing `null` as result forces `bridge-ios.html` to call `getRequestResult`.
    private func invokeJSCallback(
        callbackId: String,
        success: Bool,
        result: String?,
        errCode: Int,
        errMsg: String
    ) {
        guard !callbackId.isEmpty, let webView else { return }
        let idLiteral = Self.jsStringLiteral(callbackId)
        let errLiteral = Self.jsStringLiteral(errMsg)

        let js: String
        if let result {
            let b64 = Data(result.utf8).base64EncodedString()
            js = """
            (function(){
              var id = \(idLiteral);
              var b64 = '\(b64)';
              try {
                var bin = atob(b64);
                var bytes = new Uint8Array(bin.length);
                for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                window.__requestResults[id] = new TextDecoder('utf-8').decode(bytes);
              } catch (e) {
                window.__requestResults[id] = '';
              }
              AndroidBridge_invokeCallback(id, \(success ? "true" : "false"), null, \(errCode), \(errLiteral));
            })();
            """
        } else {
            js = """
            AndroidBridge_invokeCallback(\(idLiteral), \(success ? "true" : "false"), null, \(errCode), \(errLiteral));
            """
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func updateVisitorData(from text: String) {
        guard let regex = try? NSRegularExpression(pattern: #""VISITOR_DATA"\s*:\s*"([^"]+)""#) else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return }
        let value = String(text[r])
        guard !value.isEmpty, value != visitorData else { return }
        visitorData = value
        StreamLog.info("visitorData updated \(StreamLog.truncate(value, limit: 48))")
        syncVisitorDataToJS()
    }

    private func syncVisitorDataToJS() {
        guard let webView, !visitorData.isEmpty else { return }
        let js = "window.__visitorData = \(Self.jsStringLiteral(visitorData));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private static func jsStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "'\(escaped)'"
    }

    // MARK: - Flutter fallback channel

    private func handleFlutterRequest(_ body: Any) {
        guard let text = body as? String,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reqId = obj["reqId"] as? Int,
              let urlString = obj["url"] as? String,
              let url = URL(string: urlString) else {
            return
        }

        let method = ((obj["method"] as? String) ?? "GET").uppercased()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30

        if let headers = obj["headers"] as? [String: Any] {
            for (key, value) in headers {
                request.setValue("\(value)", forHTTPHeaderField: key)
            }
        }

        if let bodyString = obj["data"] as? String, !bodyString.isEmpty {
            request.httpBody = bodyString.data(using: .utf8)
        } else if let bodyDict = obj["data"] as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: bodyDict) {
            request.httpBody = encoded
            if request.value(forHTTPHeaderField: "content-type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "content-type")
            }
        }

        Task {
            let callbackJSON: String
            do {
                let (responseData, response) = try await self.session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let success = (200..<400).contains(status)
                if success, let text = String(data: responseData, encoding: .utf8) {
                    await MainActor.run { self.updateVisitorData(from: text) }
                }
                let b64 = responseData.base64EncodedString()
                let payload: [String: Any] = [
                    "reqId": reqId,
                    "success": success,
                    "result": b64,
                    "errCode": success ? 0 : status,
                    "errMsg": success ? "" : "HTTP \(status)",
                ]
                callbackJSON = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"
            } catch {
                let payload: [String: Any] = [
                    "reqId": reqId,
                    "success": false,
                    "result": Data().base64EncodedString(),
                    "errCode": -1,
                    "errMsg": error.localizedDescription,
                ]
                callbackJSON = String(
                    data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(),
                    encoding: .utf8
                ) ?? "{}"
            }

            await MainActor.run {
                let b64 = Data(callbackJSON.utf8).base64EncodedString()
                let js = "extractor.callbackFlutterRequest(atob('\(b64)'));"
                self.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    private func handleExtractCallback(_ body: Any) {
        let text: String?
        if let s = body as? String {
            text = s
        } else if let dict = body as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let s = String(data: data, encoding: .utf8) {
            text = s
        } else {
            text = nil
        }

        guard let text,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = obj["uid"] as? String,
              let cont = pendingExtract.removeValue(forKey: uid) else {
            return
        }

        if let wrapper = obj["data"] as? [String: Any] {
            let success = wrapper["success"] as? Bool ?? false
            let errorMsg = (wrapper["errorMsg"] as? String)?.nilIfEmpty
            if success, let payload = wrapper["data"] as? [String: Any] {
                // resolution.js sometimes returns success=true with music=null + login error.
                if payload["music"] == nil || payload["music"] is NSNull {
                    let msg = errorMsg ?? "login required / empty music payload"
                    StreamLog.error("Extract callback empty music uid=\(uid) msg=\(msg)")
                    cont.resume(throwing: StreamJSExtractorError.message(msg))
                    return
                }
                StreamLog.info("Extract callback OK uid=\(uid) keys=\(Array(payload.keys).sorted())")
                cont.resume(returning: payload)
            } else {
                let msg = errorMsg ?? StreamJSExtractorError.extractFailed.localizedDescription
                StreamLog.error("Extract callback fail uid=\(uid) msg=\(msg) wrapper=\(StreamLog.truncate(String(describing: wrapper), limit: 240))")
                cont.resume(throwing: StreamJSExtractorError.message(msg))
            }
        } else {
            StreamLog.error("Extract callback missing data uid=\(uid)")
            cont.resume(throwing: StreamJSExtractorError.extractFailed)
        }
    }
}

extension StreamJSExtractor: WKScriptMessageHandler {
    public nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let name = message.name
        let body = message.body
        Task { @MainActor in
            switch name {
            case "AndroidBridge":
                self.handleAndroidBridge(body)
            case "flutterRequest":
                self.handleFlutterRequest(body)
            case "callbackFlutterExtract":
                self.handleExtractCallback(body)
            default:
                break
            }
        }
    }
}

extension StreamJSExtractor: WKNavigationDelegate {
    public nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.finishBoot(error: error)
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.finishBoot(error: error)
        }
    }
}

public enum StreamJSExtractorError: LocalizedError {
    case missingScript
    case scriptNotReady
    case invalidPayload
    case timeout
    case extractFailed
    case noPlayableURL
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .missingScript: return "bridge-ios.html / resolution.js is missing from the app bundle."
        case .scriptNotReady: return "Stream extractor script failed to initialize."
        case .invalidPayload: return "Invalid extractor request payload."
        case .timeout: return "Stream extraction timed out."
        case .extractFailed: return "Stream extraction failed."
        case .noPlayableURL: return "No progressive playable URL was returned."
        case .message(let text): return text
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
