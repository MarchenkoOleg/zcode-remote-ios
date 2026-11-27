import SwiftUI
import WebKit

/// Used once per account: shows ZCode sign-in in a WKWebView and reports the
/// JWT found in its isolated web storage. After that the session runs natively.
struct HybridSignInView: UIViewRepresentable {
    let account: ZCodeAccount
    let onToken: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: account.dataStoreID)

        let watcher = WKUserScript(
            source: Self.tokenWatcher,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(watcher)
        configuration.userContentController.add(context.coordinator, name: "zcodeJwt")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://zcode.z.ai/remote/v4")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private static let tokenWatcher = """
    (() => {
      if (window.__zcodeJwtWatch) return;
      window.__zcodeJwtWatch = true;
      const read = () => {
        try {
          const browser = localStorage.getItem('oauth:browser_session');
          let token = browser ? JSON.parse(browser).zcodeJwtToken : null;
          if (!token) token = localStorage.getItem('zcodejwttoken');
          if (!token) token = localStorage.getItem('oauth:zai:access_token');
          if (token) {
            window.webkit.messageHandlers.zcodeJwt.postMessage(token);
            return;
          }
        } catch (e) {}
        setTimeout(read, 500);
      };
      read();
    })()
    """

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler {
        private let onToken: @MainActor (String) -> Void

        init(onToken: @escaping @MainActor (String) -> Void) {
            self.onToken = onToken
        }

        @MainActor
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "zcodeJwt", let token = message.body as? String, !token.isEmpty else { return }
            onToken(token)
        }

        nonisolated func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = MainActor.assumeIsolated({ navigationAction.request.url }) else { return nil }
            Task { @MainActor in webView.load(URLRequest(url: url)) }
            return nil
        }
    }
}
