import Foundation

/// One `zcode.z.ai/remote/v4` link belonging to an account.
nonisolated struct RemoteSession: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var accountID: UUID
    var sid: String
    var mid: String
    var name: String
    var appVersion: String
    var createdAt: Date
    var lastOpenedAt: Date?

    init(
        id: UUID = UUID(),
        accountID: UUID,
        sid: String,
        mid: String,
        name: String,
        appVersion: String,
        createdAt: Date = Date(),
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.sid = sid
        self.mid = mid
        self.name = name
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }

    /// Rebuilt from components so values such as a machine name with spaces are
    /// encoded correctly.
    var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "zcode.z.ai"
        components.path = "/remote/v4"
        components.queryItems = [
            URLQueryItem(name: "sid", value: sid),
            URLQueryItem(name: "mid", value: mid),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "app_version", value: appVersion),
        ]
        guard let url = components.url else {
            preconditionFailure("Hard-coded URL components must always encode")
        }
        return url
    }
}
