import SwiftUI
import WebKit

/// Sign-in popup from the remote page. Uses the *same* data store as the
/// account, so cookies set here are immediately visible to the remote session.
struct AuthWebView: UIViewRepresentable {
    let url: URL
    let account: ZCodeAccount

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: account.dataStoreID)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate {
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
