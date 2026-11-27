import SwiftUI
import WebKit

struct RemoteWebView: UIViewRepresentable {
    let session: RemoteSession
    let account: ZCodeAccount
    @Environment(AppModel.self) private var model

    final class Coordinator {
        var language: AppLanguage?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        guard context.coordinator.language != model.language else { return }
        context.coordinator.language = model.language

        // ZCode's web UI reads `zcode-locale-preference` from localStorage.
        // Only zh-CN and en-US exist; for Russian or system we clear the
        // override and let the browser locale decide (it falls back to en-US).
        let script: String
        switch model.language {
        case .en:
            script = Self.script(setting: "en-US")
        case .ru, .system:
            script = Self.script(setting: nil)
        }
        webView.evaluateJavaScript(script) { changed, _ in
            guard (changed as? Bool) == true else { return }
            DispatchQueue.main.async { webView.reload() }
        }
    }

    private static func script(setting value: String?) -> String {
        let action: String
        if value != nil {
            action = "if (localStorage.getItem(key) === value) return false; localStorage.setItem(key, value); return true;"
        } else {
            action = "if (!localStorage.getItem(key)) return false; localStorage.removeItem(key); return true;"
        }
        let quoted = value.map { "'\($0)'" } ?? "null"
        return """
        (() => {
          const key = 'zcode-locale-preference';
          const value = \(quoted);
          \(action)
        })()
        """
    }
}
