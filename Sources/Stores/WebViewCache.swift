import Foundation
import WebKit

/// Keeps a small set of WKWebViews alive so switching between sessions is
/// instant instead of rebuilding the page and losing its in-memory state.
@MainActor
final class WebViewCache {
    private var webViews: [UUID: WKWebView] = [:]
    private var delegates: [UUID: WebViewDelegate] = [:]
    private var lastUsed: [UUID: Date] = [:]
    private var activeID: UUID?
    private let maxCount = 3

    func setActive(_ id: UUID?) {
        activeID = id
    }

    func existingWebView(for id: UUID) -> WKWebView? {
        webViews[id]
    }

    func webView(
        for session: RemoteSession,
        account: ZCodeAccount,
        onStateChange: @escaping @Sendable (SessionConnectionState) -> Void,
        onPopup: @escaping @Sendable (URL) -> Void,
        onPageKind: @escaping @Sendable (RemotePageKind) -> Void
    ) -> WKWebView {
        if let existing = webViews[session.id] {
            lastUsed[session.id] = Date()
            evictIfNeeded(protecting: session.id)
            return existing
        }

        let delegate = WebViewDelegate(
            onStateChange: onStateChange,
            onPopup: onPopup,
            onPageKind: onPageKind
        )

        let configuration = WKWebViewConfiguration()
        // One persistent, isolated data store per user: cookies, IndexedDB and
        // local storage survive launches and never mix with another account.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: account.dataStoreID)
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        // A JS MutationObserver reports screen changes with a debounce; the
        // app no longer needs to poll the page on a timer.
        let observer = WKUserScript(
            source: PageProbe.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(observer)
        configuration.userContentController.add(delegate, name: "zcodePageObserver")

        let networkHook = WKUserScript(
            source: NetworkProbe.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(networkHook)
        configuration.userContentController.add(delegate, name: "zcodeNetworkObserver")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        delegates[session.id] = delegate

        webViews[session.id] = webView
        lastUsed[session.id] = Date()
        evictIfNeeded(protecting: session.id)
        return webView
    }

    func removeSession(_ id: UUID) {
        webViews[id]?.removeFromSuperview()
        webViews.removeValue(forKey: id)
        delegates.removeValue(forKey: id)
        lastUsed.removeValue(forKey: id)
    }

    func removeSessions(of accountID: UUID, in sessions: [RemoteSession]) {
        for session in sessions where session.accountID == accountID {
            removeSession(session.id)
        }
    }

    private func evictIfNeeded(protecting: UUID) {
        guard webViews.count > maxCount else { return }
        let candidates = lastUsed
            .filter { $0.key != protecting && $0.key != activeID }
            .sorted { $0.value < $1.value }
            .map(\.key)
        let excess = webViews.count - maxCount
        for id in candidates.prefix(excess) {
            removeSession(id)
        }
    }
}

@MainActor
final class WebViewDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let onStateChange: @Sendable (SessionConnectionState) -> Void
    private let onPopup: @Sendable (URL) -> Void
    private let onPageKind: @Sendable (RemotePageKind) -> Void

    private static let resourceProbe = """
    (() => {
      const r = performance.getEntriesByType('resource')
        .map(x => ({ u: x.name, d: Math.round(x.duration) }))
        .sort((a, b) => b.d - a.d).slice(0, 5);
      return r.map(x => x.d + 'ms ' + x.u).join(' | ');
    })()
    """

    init(
        onStateChange: @escaping @Sendable (SessionConnectionState) -> Void,
        onPopup: @escaping @Sendable (URL) -> Void,
        onPageKind: @escaping @Sendable (RemotePageKind) -> Void
    ) {
        self.onStateChange = onStateChange
        self.onPopup = onPopup
        self.onPageKind = onPageKind
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url {
            NetworkLog.message("Навигация: \(Self.redacted(url.absoluteString))")
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        NetworkLog.message("Загрузка страницы началась", category: .webview)
        Task { @MainActor [weak self] in self?.onStateChange(.loading) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NetworkLog.message("Страница загружена", category: .webview)
        Task { @MainActor [weak self] in
            self?.onStateChange(.connected)
            if let text = try? await webView.evaluateJavaScript(Self.resourceProbe) as? String,
               !text.isEmpty {
                NetworkLog.message("Самые медленные ресурсы: \(text)")
            }
            if let raw = try? await webView.evaluateJavaScript(PageProbe.script) as? String,
               let kind = RemotePageKind(rawValue: raw) {
                self?.onPageKind(kind)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NetworkLog.message("Ошибка загрузки: \(error.localizedDescription)", category: .webview, level: .error)
        Task { @MainActor [weak self] in self?.onStateChange(.failed(error.localizedDescription)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NetworkLog.message("Ошибка загрузки: \(error.localizedDescription)", category: .webview, level: .error)
        Task { @MainActor [weak self] in self?.onStateChange(.failed(error.localizedDescription)) }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "zcodePageObserver",
           let raw = message.body as? String,
           let kind = RemotePageKind(rawValue: raw) {
            if CommandLine.arguments.contains("dump-page"), let webView = message.webView {
                Task { @MainActor in
                    if let text = try? await webView.evaluateJavaScript("""
                    JSON.stringify({
                      title: document.title,
                      text: ((document.body && document.body.innerText) || '').slice(0, 300),
                      content: ((document.body && document.body.textContent) || '').slice(0, 300),
                      frames: Array.from(document.querySelectorAll('iframe')).map(f => ({
                        src: f.src,
                        text: ((f.contentDocument && f.contentDocument.body &&
                                f.contentDocument.body.innerText) || '').slice(0, 300)
                      })),
                      canvas: document.querySelectorAll('canvas').length
                    })
                    """) as? String {
                        NetworkLog.message("PAGE-TEXT[\(raw)]: \(text)")
                    }
                }
            }
            onPageKind(kind)
            return
        }

        guard message.name == "zcodeNetworkObserver",
              let body = message.body as? [String: Any] else { return }
        let kind = body["kind"] as? String ?? "request"
        let url = Self.redacted(body["url"] as? String ?? "")
        let method = body["method"] as? String ?? "GET"
        let status = body["status"] as? Int ?? 0
        let ms = body["ms"] as? Int ?? 0
        let keys = body["keys"] as? String ?? ""
        NetworkLog.message(
            "\(kind.uppercased()) \(method) \(url) → \(status) · \(ms)ms" +
            (keys.isEmpty ? "" : " · \(keys)")
        )

        if let page = Self.pageKind(fromRequestURL: url) {
            onPageKind(page)
        }
    }

    /// WebSocket URLs carry a fresh auth token in plain sight; keep the
    /// endpoint visible in logs but never persist the credential itself.
    nonisolated private static func redacted(_ value: String) -> String {
        guard var components = URLComponents(string: value),
              let items = components.queryItems else { return value }
        let secrets = ["token", "sid", "mid", "auth", "secret", "key"]
        components.queryItems = items.map { item in
            secrets.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "***")
                : item
        }
        return components.string ?? value
    }

    /// Best-effort classification of ZCode's own API calls. Every request is
    /// logged so the exact endpoint can be refined from the in-app log.
    nonisolated private static func pageKind(fromRequestURL url: String) -> RemotePageKind? {
        let lower = url.lowercased()
        guard lower.contains("/api/v1/") || lower.contains("/api/") else { return nil }
        if lower.contains("/client/configs") { return nil }
        if lower.contains("/chat") || lower.contains("/task") {
            return (lower.contains("/list") || lower.hasSuffix("/chats") || lower.hasSuffix("/tasks")) ? .home : .chat
        }
        if lower.contains("/project") { return .home }
        return nil
    }

    /// ZCode opens its sign-in page with `window.open`. WKWebView drops popups
    /// unless a UIDelegate handles them, so surface it as an in-app sheet.
    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = MainActor.assumeIsolated({ navigationAction.request.url }) else { return nil }
        Task { @MainActor [weak self] in self?.onPopup(url) }
        return nil
    }
}
