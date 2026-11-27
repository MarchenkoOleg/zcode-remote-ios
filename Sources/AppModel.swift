import Foundation
import Observation
import UIKit
import WebKit

@Observable
@MainActor
final class AppModel {
    private let store = Store()
    let connectivity = ConnectivityMonitor()
    let webViewCache = WebViewCache()
    let versionChecker = VersionChecker()
    let log = AppLog.shared

    private(set) var accounts: [ZCodeAccount]
    private(set) var sessions: [RemoteSession]
    var selectedAccountID: UUID?
    var selectedSessionID: UUID?

    var connectionStates: [UUID: SessionConnectionState] = [:]
    var pageKinds: [UUID: RemotePageKind] = [:]
    var lastError: String?
    var authRequest: AuthRequest?

    /// User preference for the home shortcut, persisted between launches.
    var homeButtonPlacement: HomeButtonPlacement = AppModel.loadHomeButtonPlacement() {
        didSet {
            UserDefaults.standard.set(homeButtonPlacement.rawValue, forKey: AppModel.placementKey)
        }
    }

    var language: AppLanguage = AppModel.loadLanguage() {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: AppModel.languageKey)
        }
    }

    /// Locale injected into SwiftUI so String Catalog translations apply
    /// without restarting the app or changing system-wide settings.
    var locale: Locale {
        switch language {
        case .system: .current
        case .ru: Locale(identifier: "ru")
        case .en: Locale(identifier: "en")
        }
    }

    private static let placementKey = "homeButtonPlacement"
    private static let languageKey = "appLanguage"

    private static func loadLanguage() -> AppLanguage {
        // Debug/testing entry point: `language=<system|ru|en>`.
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("language=") }),
           let forced = AppLanguage(rawValue: String(argument.dropFirst("language=".count))) {
            return forced
        }
        if let raw = UserDefaults.standard.string(forKey: languageKey),
           let language = AppLanguage(rawValue: raw) {
            return language
        }
        return .system
    }

    private static func loadHomeButtonPlacement() -> HomeButtonPlacement {
        // Debug/testing entry point: `home-button=<overlay|bottom>`.
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("home-button=") }),
           let forced = HomeButtonPlacement(rawValue: String(argument.dropFirst("home-button=".count))) {
            return forced
        }
        if let raw = UserDefaults.standard.string(forKey: placementKey),
           let placement = HomeButtonPlacement(rawValue: raw) {
            return placement
        }
        return .overlay
    }

    private var backoffs: [UUID: Backoff] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        accounts = store.state.accounts
        sessions = store.state.sessions
        selectedAccountID = accounts.first?.id
        selectedSessionID = sessions.first?.id

        connectivity.onPathChange = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.handlePathChange(status)
            }
        }
        connectivity.startHealthChecks()

        // WebKit keeps its own cache; this one covers our own health/version
        // requests so they don't hit the network on every launch.
        let cache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            diskPath: "zcode-remote-cache"
        )
        URLCache.shared = cache
        log.log(
            "URLCache: \(cache.memoryCapacity / 1024 / 1024) MB в памяти, \(cache.diskCapacity / 1024 / 1024) MB на диске",
            category: .cache
        )

        preloadLastSession()
        Task { await versionChecker.check() }
    }

    /// Warm start: the last used session is loaded off-screen at launch, so
    /// opening it is instant instead of starting a cold page load.
    private func preloadLastSession() {
        guard let session = sessions.max(by: {
            ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast)
        }), let account = account(id: session.accountID) else { return }

        let webView = webViewCache.webView(
            for: session,
            account: account,
            onStateChange: { [weak self] state in
                Task { @MainActor in self?.setConnectionState(state, for: session.id) }
            },
            onPopup: { [weak self] url in
                Task { @MainActor in self?.requestAuth(url: url, sessionID: session.id) }
            },
            onPageKind: { [weak self] kind in
                Task { @MainActor in self?.setPageKind(kind, for: session.id) }
            }
        )
        if webView.url == nil {
            webView.load(URLRequest(url: session.url))
            log.log("Предзагрузка сессии «\(session.name)»", category: .cache)
        } else {
            log.log("Сессия «\(session.name)» уже в кэше WKWebView", category: .cache)
        }
    }

    // MARK: - Lookup

    func account(id: UUID?) -> ZCodeAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    func session(id: UUID?) -> RemoteSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func sessions(for accountID: UUID) -> [RemoteSession] {
        sessions
            .filter { $0.accountID == accountID }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
    }

    func token(for accountID: UUID) -> String? {
        KeychainStore.load(for: accountID)
    }

    // MARK: - Editing

    func addAccount(label: String, username: String, token: String?) {
        let account = ZCodeAccount(
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username
        )
        accounts.append(account)
        if let token, !token.isEmpty {
            try? KeychainStore.save(token, for: account.id)
        }
        selectedAccountID = account.id
        persist()
    }

    func deleteAccount(_ id: UUID) {
        guard let account = account(id: id) else { return }
        cancelAllRetries(for: sessions.filter { $0.accountID == id }.map(\.id))
        webViewCache.removeSessions(of: id, in: sessions)
        WKWebsiteDataStore(forIdentifier: account.dataStoreID)
            .removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { }
        KeychainStore.delete(for: id)

        accounts.removeAll { $0.id == id }
        sessions.removeAll { $0.accountID == id }
        if selectedAccountID == id { selectedAccountID = accounts.first?.id }
        if let selected = selectedSessionID, session(id: selected) == nil { selectedSessionID = nil }
        persist()
    }

    func addSession(fields: RemoteLink.Fields, accountID: UUID) {
        let session = RemoteSession(
            accountID: accountID,
            sid: fields.sid,
            mid: fields.mid,
            name: fields.name,
            appVersion: fields.appVersion
        )
        sessions.append(session)
        selectedSessionID = session.id
        persist()
    }

    /// Edits a session in place — its id and stored web data (auth) survive.
    func updateSession(_ updated: RemoteSession) {
        guard let index = sessions.firstIndex(where: { $0.id == updated.id }) else { return }
        sessions[index] = updated
        persist()
        log.log("Обновлена сессия «\(updated.name)», версия \(updated.appVersion)")
        if let webView = webViewCache.existingWebView(for: updated.id) {
            webView.load(URLRequest(url: updated.url))
        }
    }

    func deleteSession(_ id: UUID) {
        guard session(id: id) != nil else { return }
        cancelRetry(id)
        backoffs[id] = nil
        connectionStates[id] = nil
        webViewCache.removeSession(id)
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id { selectedSessionID = nil }
        persist()
    }

    func touchSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].lastOpenedAt = Date()
        persist()
    }

    // MARK: - Connection

    func setActiveSession(_ id: UUID?) {
        webViewCache.setActive(id)
    }

    func pageKind(for id: UUID) -> RemotePageKind {
        pageKinds[id] ?? .loading
    }

    func setPageKind(_ kind: RemotePageKind, for id: UUID) {
        guard pageKinds[id] != kind else { return }
        pageKinds[id] = kind
        log.log("Экран сессии \(id.uuidString.prefix(8)): \(kind.rawValue)", category: .webview)
        switch kind {
        case .auth:
            connectionStates[id] = .needsAuth
        case .home, .chat, .other:
            if connectionStates[id] == .needsAuth {
                connectionStates[id] = .connected
            }
        case .loading:
            break
        }
    }

    func requestAuth(url: URL, sessionID: UUID) {
        guard let session = session(id: sessionID),
              let account = account(id: session.accountID) else { return }
        authRequest = AuthRequest(url: url, account: account, sessionID: sessionID)
    }

    func finishAuth() {
        guard let sessionID = authRequest?.sessionID else { return }
        authRequest = nil
        reconnect(sessionID)
    }

    func setConnectionState(_ state: SessionConnectionState, for id: UUID) {
        connectionStates[id] = state
        switch state {
        case .connected, .idle:
            cancelRetry(id)
            backoffs[id] = nil
        case .needsAuth:
            cancelRetry(id)
        case .failed(let message):
            lastError = message
            scheduleRetry(for: id)
        case .offline:
            cancelRetry(id)
        case .loading:
            break
        }
    }

    func reconnect(_ id: UUID) {
        guard let webView = webViewCache.existingWebView(for: id) else { return }
        guard connectivity.pathStatus != .offline else {
            connectionStates[id] = .offline
            return
        }
        connectionStates[id] = .loading
        log.log("Переподключение сессии \(id.uuidString)", category: .webview)
        webView.reload()
    }

    func handleBecameActive() {
        connectivity.startHealthChecks()
        Task { await connectivity.checkServer() }
        Task { await versionChecker.check() }
        if connectivity.pathStatus == .online { reconnectVisibleSessions() }
    }

    func handleBackground() {
        connectivity.stopHealthChecks()
    }

    func copyLink(_ id: UUID) {
        guard let url = session(id: id)?.url else { return }
        UIPasteboard.general.string = url.absoluteString
    }

    func openInSafari(_ id: UUID) async {
        guard let url = session(id: id)?.url else { return }
        await UIApplication.shared.open(url)
    }

    private func handlePathChange(_ status: ConnectivityMonitor.PathStatus) {
        switch status {
        case .online:
            connectivity.startHealthChecks()
            Task { await connectivity.checkServer() }
            reconnectVisibleSessions()
        case .offline:
            for id in connectionStates.keys {
                connectionStates[id] = .offline
                cancelRetry(id)
            }
        case .unknown:
            break
        }
    }

    private func reconnectVisibleSessions() {
        guard let id = selectedSessionID else { return }
        if case .failed = connectionStates[id] { backoffs[id] = nil }
        reconnect(id)
    }

    private func scheduleRetry(for id: UUID) {
        cancelRetry(id)
        var backoff = backoffs[id] ?? Backoff()
        let delay = backoff.nextDelay()
        backoffs[id] = backoff
        log.log(
            "Повтор подключения через \(String(format: "%.1f", delay)) с",
            category: .network,
            level: .warning
        )

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnect(id)
        }
        retryTasks[id] = task
    }

    private func cancelRetry(_ id: UUID) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
    }

    private func cancelAllRetries(for ids: [UUID]) {
        for id in ids { cancelRetry(id) }
    }

    private func persist() {
        store.state = PersistedState(accounts: accounts, sessions: sessions)
        store.save()
    }
}
