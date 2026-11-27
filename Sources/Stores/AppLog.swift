import Foundation
import OSLog
import Observation

/// Single log sink: writes to the system log and keeps a short in-memory
/// buffer so the log can be viewed and shared from the app.
@Observable
@MainActor
final class AppLog {
    enum Category: String, Sendable, CaseIterable {
        case app, network, cache, webview, version
    }

    enum Level: String, Sendable {
        case info, warning, error
    }

    struct Entry: Identifiable, Sendable {
        let id: UUID
        let date: Date
        let category: Category
        let level: Level
        let message: String
    }

    static let shared = AppLog()

    private(set) var entries: [Entry] = []
    private let maxEntries = 600
    private let logger = Logger(subsystem: "ru.ligarobotov.zcode-remote", category: "remote")
    private let fileURL: URL
    private let fileLimit = 2_000_000

    private static let fileTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("ZCodeRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("app.log", isDirectory: false)
    }

    func log(_ message: String, category: Category = .app, level: Level = .info) {
        let entry = Entry(id: UUID(), date: Date(), category: category, level: level, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        appendToFile(entry)
        switch level {
        case .info:
            logger.info("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
        case .warning:
            logger.warning("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
        case .error:
            logger.error("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
        }
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
        log("Лог очищен")
    }

    private func appendToFile(_ entry: Entry) {
        let line = "\(Self.fileTime.string(from: entry.date)) [\(entry.category.rawValue)/\(entry.level.rawValue)] \(entry.message)\n"
        rotateIfNeeded()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? Data(line.utf8).write(to: fileURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
    }

    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int,
              size > fileLimit,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let tail = text.split(separator: "\n").suffix(1000).joined(separator: "\n")
        try? (tail + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

nonisolated enum NetworkLog {
    static func request(
        _ label: String,
        request: URLRequest,
        status: Int?,
        bytes: Int,
        duration: TimeInterval,
        cacheHit: Bool
    ) {
        let method = request.httpMethod ?? "GET"
        let host = request.url?.host ?? "—"
        let path = request.url?.path ?? ""
        let statusText = status.map(String.init) ?? "error"
        let text = "\(label) \(method) \(host)\(path) → \(statusText) · \(bytes)B · \(String(format: "%.2f", duration))s · \(cacheHit ? "cache" : "network")"
        Task { @MainActor in
            AppLog.shared.log(text, category: .network)
        }
    }

    static func message(_ text: String, category: AppLog.Category = .network, level: AppLog.Level = .info) {
        Task { @MainActor in
            AppLog.shared.log(text, category: category, level: level)
        }
    }
}
