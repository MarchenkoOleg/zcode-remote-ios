import Foundation

/// Parses the links ZCode prints for remote access, e.g.
/// `https://zcode.z.ai/remote/v4?sid=d_x&mid=uuid&name=Mac.local&app_version=3.19.0`.
nonisolated enum RemoteLink {
    static let host = "zcode.z.ai"

    nonisolated struct Fields: Sendable, Equatable {
        var sid: String
        var mid: String
        var name: String
        var appVersion: String
    }

    static func parse(_ text: String) -> Fields? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate),
              let host = url.host?.lowercased(),
              host == Self.host || host.hasSuffix("." + Self.host),
              url.path.hasPrefix("/remote/")
        else { return nil }

        var values: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if let value = item.value {
                values[item.name] = value
            }
        }

        guard let sid = values["sid"], !sid.isEmpty,
              let mid = values["mid"], !mid.isEmpty
        else { return nil }

        return Fields(
            sid: sid,
            mid: mid,
            name: values["name"] ?? "Mac",
            appVersion: values["app_version"] ?? "3.19.0"
        )
    }
}
