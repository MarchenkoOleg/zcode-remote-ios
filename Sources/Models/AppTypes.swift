import Foundation

nonisolated enum RemotePageKind: String, Sendable, Equatable {
    case loading
    case auth
    case home
    case chat
    case other
}

/// Identifies which screen of the ZCode web app is currently displayed.
nonisolated enum PageProbe {
    /// Installed once per web view. Reports the detected screen to native
    /// code after the DOM settles, instead of making the app poll.
    static let observerScript = """
    (() => {
      if (window.__zcodePageObserverInstalled) return;
      window.__zcodePageObserverInstalled = true;
      let timer = null;
      const classify = () => {
        const t = ((document.body && document.body.innerText) || '').toLowerCase();
        if (t.includes('sign in to continue') || t.includes('authorize in browser')) return 'auth';
        if (t.includes('task chat') || t.includes('ask for follow-up changes')) return 'chat';
        if (t.includes('task list') || t.includes('new task') || t.includes('new project')) return 'home';
        return 'other';
      };
      const report = () => {
        timer = null;
        try {
          window.webkit.messageHandlers.zcodePageObserver.postMessage(classify());
        } catch (e) { /* bridge not ready yet */ }
      };
      const schedule = () => {
        if (timer) clearTimeout(timer);
        timer = setTimeout(report, 200);
      };
      const observer = new MutationObserver(schedule);
      observer.observe(document.documentElement, {
        childList: true, subtree: true, characterData: true
      });
      window.addEventListener('focus', schedule);
      schedule();
    })()
    """

    static let script = """
    (() => {
      const t = ((document.body && document.body.innerText) || '').toLowerCase();
      if (t.includes('sign in to continue') || t.includes('authorize in browser')) return 'auth';
      if (t.includes('task chat') || t.includes('ask for follow-up changes')) return 'chat';
      if (t.includes('task list') || t.includes('new task') || t.includes('new project')) return 'home';
      return 'other';
    })()
    """
}

/// Wraps the SPA's fetch/XHR so the app sees the actual API calls ZCode makes.
nonisolated enum NetworkProbe {
    static let script = """
    (() => {
      if (window.__zcodeNetHook) return;
      window.__zcodeNetHook = true;
      const post = (kind, url, method, status, ms, keys) => {
        try {
          window.webkit.messageHandlers.zcodeNetworkObserver.postMessage({
            kind: kind, url: String(url || ''), method: method,
            status: status, ms: ms, keys: keys || ''
          });
        } catch (e) {}
      };
      const describe = (data) => {
        const text = typeof data === 'string' ? data :
          (data && data.data ? String(data.data) : '');
        let keys = '';
        try {
          const parsed = JSON.parse(text);
          if (parsed && typeof parsed === 'object') {
            keys = Object.keys(parsed).slice(0, 8).join(',');
            if (parsed.type !== undefined) keys = 'type=' + parsed.type + ' ' + keys;
            let payload = parsed.payload;
            if (typeof payload === 'string') {
              try { payload = JSON.parse(payload); } catch (e) {}
            }
            if (payload && typeof payload === 'object') {
              keys += ' payload{' + Object.keys(payload).slice(0, 12).join(',') + '}';
            }
          }
        } catch (e) {}
        return { len: text.length, keys: keys };
      };
      const OriginalWS = window.WebSocket;
      if (OriginalWS) {
        window.WebSocket = new Proxy(OriginalWS, {
          construct(target, args) {
            const ws = new target(...args);
            const wsURL = String(args[0] || '');
            const originalSend = ws.send.bind(ws);
            ws.send = function(data) {
              const info = describe(data);
              post('ws-send', wsURL, '', 0, 0, info.len + 'b ' + info.keys);
              return originalSend(data);
            };
            ws.addEventListener('message', (event) => {
              const info = describe(event.data);
              post('ws-recv', wsURL, '', 0, 0, info.len + 'b ' + info.keys);
            });
            return ws;
          }
        });
      }
      const urlOf = (input) => {
        try {
          if (typeof input === 'string') return input;
          if (!input) return '';
          if (input.url) return input.url;
          if (input.href) return input.href;
          const asText = String(input);
          return asText === '[object Object]' ? '' : asText;
        } catch (e) { return ''; }
      };
      const originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function(input, init) {
          let url = urlOf(input);
          if (url && !/^https?:/i.test(url)) {
            try { url = new URL(url, window.location.href).href; } catch (e) {}
          }
          const method = (init && init.method) || (input && input.method) || 'GET';
          const start = Date.now();
          return originalFetch.apply(this, arguments).then((res) => {
            post('fetch', url, method, res.status, Date.now() - start);
            return res;
          }).catch((err) => {
            post('fetch', url, method, 0, Date.now() - start);
            throw err;
          });
        };
      }
      const originalOpen = XMLHttpRequest.prototype.open;
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        let resolved = urlOf(url);
        if (resolved && !/^https?:/i.test(resolved)) {
          try { resolved = new URL(resolved, window.location.href).href; } catch (e) {}
        }
        this.__zcodeMethod = method;
        this.__zcodeURL = resolved;
        return originalOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        const self = this;
        const start = Date.now();
        this.addEventListener('loadend', function() {
          post('xhr', self.__zcodeURL, self.__zcodeMethod, self.status || 0, Date.now() - start);
        });
        return originalSend.apply(this, arguments);
      };
    })()
    """
}

/// Interface language selected in the app; `.system` follows device settings.
nonisolated enum AppLanguage: String, Sendable, CaseIterable, Hashable {
    case system
    case ru
    case en

    var label: String {
        switch self {
        case .system: "Системный"
        case .ru: "Русский"
        case .en: "English"
        }
    }
}

/// Where the persistent «Домой» shortcut sits inside a remote session.
nonisolated enum HomeButtonPlacement: String, Sendable, CaseIterable, Hashable {
    case overlay
    case bottom

    var label: String {
        switch self {
        case .overlay: "Поверх, в шапке"
        case .bottom: "Снизу экрана"
        }
    }
}

nonisolated enum SessionConnectionState: Sendable, Equatable {
    case idle
    case loading
    case connected
    case needsAuth
    case offline
    case failed(String)
}

nonisolated enum Route: Hashable, Sendable {
    case remote(UUID)
}

nonisolated struct PersistedState: Codable, Sendable {
    var accounts: [ZCodeAccount] = []
    var sessions: [RemoteSession] = []
}

/// A popup opened by the remote page (typically the ZCode sign-in flow).
nonisolated struct AuthRequest: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let account: ZCodeAccount
    let sessionID: UUID

    init(url: URL, account: ZCodeAccount, sessionID: UUID) {
        self.id = UUID()
        self.url = url
        self.account = account
        self.sessionID = sessionID
    }
}
