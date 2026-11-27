import Foundation
import Network
import Observation

/// Tracks both the device path and the reachability of zcode.z.ai, so the UI
/// can tell "no Wi-Fi" apart from "the server is down".
@Observable
@MainActor
final class ConnectivityMonitor {
    enum PathStatus: Sendable, Equatable {
        case unknown
        case online
        case offline
    }

    var pathStatus: PathStatus = .unknown
    var serverReachable: Bool?
    var lastCheckedAt: Date?

    var onPathChange: (@Sendable (PathStatus) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ru.ligarobotov.zcode-remote.network", qos: .utility)
    private let healthURL = URL(string: "https://zcode.z.ai/")!
    private var healthTask: Task<Void, Never>?
    private var previousStatus: PathStatus = .unknown

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let status: PathStatus = path.status == .satisfied ? .online : .offline
            Task { @MainActor [weak self] in
                self?.apply(status)
            }
        }
        monitor.start(queue: queue)
    }

    func startHealthChecks() {
        guard healthTask == nil else { return }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkServer()
                // Each HEAD takes ~1s on real Wi-Fi; 45s keeps the server
                // signal fresh without a constant request in the log.
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    func stopHealthChecks() {
        healthTask?.cancel()
        healthTask = nil
    }

    func checkServer() async {
        var request = URLRequest(url: healthURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "HEAD"
        let started = Date()
        let cacheHit = URLCache.shared.cachedResponse(for: request) != nil
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            NetworkLog.request(
                "health",
                request: request,
                status: code,
                bytes: data.count,
                duration: Date().timeIntervalSince(started),
                cacheHit: cacheHit
            )
            serverReachable = code < 500
        } catch {
            NetworkLog.request(
                "health",
                request: request,
                status: nil,
                bytes: 0,
                duration: Date().timeIntervalSince(started),
                cacheHit: cacheHit
            )
            serverReachable = false
        }
        lastCheckedAt = Date()
    }

    private func apply(_ status: PathStatus) {
        pathStatus = status
        guard status != previousStatus else { return }
        previousStatus = status
        let label: String = switch status {
        case .unknown: "unknown"
        case .online: "online"
        case .offline: "offline"
        }
        AppLog.shared.log("Состояние сети: \(label)", category: .network)
        onPathChange?(status)
    }
}
