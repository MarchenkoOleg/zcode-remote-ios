import Foundation

/// Wire types for the native WebSocket client. ZCode sends a thin JSON
/// envelope; the actual desktop data travels in Base64 fragments inside it.
nonisolated struct RemoteWSMessage: Decodable, Sendable {
    let type: String
    let serverTs: Int?
    let payload: RemoteWSPayload?
}

nonisolated struct WorkspaceTarget: Decodable, Sendable {
    let workspacePath: String
    let workspaceIdentity: String?
    let remoteSessionId: String?
    let label: String
    let kind: String?
    let connectionState: String?
}

nonisolated struct AppPayloadResult: Decodable, Sendable {
    let windowControlSessionId: String?
    let desktopAppVersion: String?
    let workspaces: [WorkspaceTarget]?
    let activeWorkspaceKey: String?
    let activeTaskId: String?
    let bridgeSessionId: String?
    let bridgeGeneration: Int?
    let recoveryId: String?
}

nonisolated struct RemoteWSPayload: Decodable, Sendable {
    let zcodeType: String?
    let requestId: String?
    let success: Bool?
    let result: AppPayloadResult?
    let pairStatus: String?
    let reason: String?
    let dataBase64: String?
    let fragmentIndex: Int?
    let fragmentCount: Int?
    let messageBytes: Int?
    let messageSeq: Int?
    let checksum: String?
    let bridgeSessionId: String?
    let bridgeGeneration: Int?
    let ackMessageSeq: Int?
    let epoch: Int?
    let seq: Int?
}

enum NativeRemoteProtocol {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Parses a WebSocket text frame without ever logging its contents.
    static func parse(_ text: String) -> RemoteWSMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? decoder.decode(RemoteWSMessage.self, from: data)
    }
}

/// Reassembles the `dataBase64` fragments of one desktop message.
nonisolated struct FragmentReassembler: Sendable {
    private var fragments: [Int: Data] = [:]
    private var expectedCount = 0
    private var expectedBytes = 0

    mutating func reset() {
        fragments.removeAll()
        expectedCount = 0
        expectedBytes = 0
    }

    /// Returns the complete payload once all fragments have arrived.
    mutating func add(
        base64: String,
        index: Int?,
        count: Int?,
        bytes: Int?
    ) -> Data? {
        guard let chunk = Data(base64Encoded: base64) else { return nil }

        guard let index, let count, count > 1 else { return chunk }
        if fragments.isEmpty {
            expectedCount = count
            expectedBytes = bytes ?? count * chunk.count
        }
        guard count == expectedCount else {
            reset()
            return nil
        }

        fragments[index] = chunk
        guard fragments.count == expectedCount else { return nil }

        let ordered = (0..<expectedCount).compactMap { fragments[$0] }
        let joined = ordered.reduce(into: Data()) { $0.append($1) }
        let complete = expectedBytes == 0 || joined.count == expectedBytes ? joined : nil
        reset()
        return complete
    }
}
