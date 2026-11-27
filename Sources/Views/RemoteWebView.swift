import SwiftUI
import WebKit

struct RemoteWebView: UIViewRepresentable {
    let session: RemoteSession
    let account: ZCodeAccount
    @Environment(AppModel.self) private var model

    func makeUIView(context: Context) -> WKWebView {
        let webView = model.webViewCache.webView(
            for: session,
            account: account,
            onStateChange: { state in
                Task { @MainActor in model.setConnectionState(state, for: session.id) }
            },
            onPopup: { url in
                Task { @MainActor in model.requestAuth(url: url, sessionID: session.id) }
            },
            onPageKind: { kind in
                Task { @MainActor in model.setPageKind(kind, for: session.id) }
            }
        )
        model.setActiveSession(session.id)
        if webView.url == nil {
            webView.load(URLRequest(url: session.url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        model.setActiveSession(session.id)
    }
}
