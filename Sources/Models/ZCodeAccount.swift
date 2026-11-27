import Foundation

/// A ZCode user. Every account owns an isolated, persistent WebKit data store,
/// so cookies and local storage never leak between different users.
nonisolated struct ZCodeAccount: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var label: String
    var username: String
    let dataStoreID: UUID
    var createdAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        username: String = "",
        dataStoreID: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.username = username
        self.dataStoreID = dataStoreID
        self.createdAt = createdAt
    }

    var initials: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        return String(trimmed.prefix(2)).uppercased()
    }
}
