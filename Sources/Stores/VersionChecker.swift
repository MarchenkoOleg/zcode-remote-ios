import Foundation
import Observation

/// Reads the release list embedded in zcode.z.ai and caches the newest
/// version, so a session created by an older ZCode build can be flagged.
@Observable
@MainActor
final class VersionChecker {
    private let url = URL(string: "https://zcode.z.ai/")!
    private let latestKey = "zcode.latestVersion"
    private let checkedAtKey = "zcode.latestVersionCheckedAt"
    private let maxAge: TimeInterval = 6 * 3600

    private(set) var latest: String?
    private(set) var checkedAt: Date?
    private(set) var errorMessage: String?

    enum VersionError: LocalizedError {
        case badResponse
        case notFound

        var errorDescription: String? {
            switch self {
            case .badResponse: "Сервер вернул неожиданный ответ"
            case .notFound: "Список версий не найден на странице"
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        latest = defaults.string(forKey: latestKey)
        checkedAt = defaults.object(forKey: checkedAtKey) as? Date
    }

    func check(force: Bool = false) async {
        if !force, latest != nil, let checkedAt,
           Date().timeIntervalSince(checkedAt) < maxAge { return }

        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        let started = Date()
        let cacheHit = URLCache.shared.cachedResponse(for: request) != nil

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            NetworkLog.request(
                "version",
                request: request,
                status: http?.statusCode,
                bytes: data.count,
                duration: Date().timeIntervalSince(started),
                cacheHit: cacheHit
            )
            guard http?.statusCode == 200 else { throw VersionError.badResponse }
            let html = String(data: data, encoding: .utf8) ?? ""
            guard let found = Self.latestVersion(in: html) else {
                throw VersionError.notFound
            }
            latest = found
            checkedAt = Date()
            errorMessage = nil
            let defaults = UserDefaults.standard
            defaults.set(found, forKey: latestKey)
            defaults.set(checkedAt, forKey: checkedAtKey)
            AppLog.shared.log("Последняя версия ZCode: \(found)", category: .version)
        } catch {
            errorMessage = error.localizedDescription
            AppLog.shared.log(
                "Не удалось проверить версию: \(error.localizedDescription)",
                category: .version,
                level: .error
            )
        }
    }

    func isOutdated(_ version: String) -> Bool {
        guard let latest,
              let current = Self.parse(version),
              let newest = Self.parse(latest) else { return false }
        return Self.isNewer(newest, than: current)
    }

    nonisolated static func latestVersion(in html: String) -> String? {
        // The site embeds escaped JSON: \"version\":\"3.19.1\"
        let pattern = #"version\\":\\"([0-9]+\.[0-9]+\.[0-9]+)\\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        var best: String?
        for match in regex.matches(in: html, range: range) {
            guard let swiftRange = Range(match.range(at: 1), in: html) else { continue }
            let candidate = String(html[swiftRange])
            guard let parsed = parse(candidate) else { continue }
            if best == nil || isNewer(parsed, than: parse(best!) ?? (0, 0, 0)) {
                best = candidate
            }
        }
        return best
    }

    nonisolated static func parse(_ version: String) -> (Int, Int, Int)? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    nonisolated static func isNewer(_ a: (Int, Int, Int), than b: (Int, Int, Int)) -> Bool {
        if a.0 != b.0 { return a.0 > b.0 }
        if a.1 != b.1 { return a.1 > b.1 }
        return a.2 > b.2
    }
}
