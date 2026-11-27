import Foundation
import Observation

/// Native implementation of ZCode's Relay V2 transport (no WebKit).
///
/// The relay only authenticates, pairs and forwards opaque JSON payloads;
/// task data itself is carried in `data.payload` and in RPC frames. This
/// client implements the transport layer and the app-payload envelope, so a
/// native UI can be built on top without loading the web client at all.
@Observable
@MainActor
final class NativeRemoteClient {
    enum State: Sendable {
        case idle
        case connecting
        case paired(pairStatus: String)
        case failed(String)
    }

    private struct TokenResponse: Decodable {
        let code: Int
        let msg: String
        let data: TokenData?
    }

    private struct TokenData: Decodable {
        let token: String
        let expiresIn: Int
    }

    var state: State = .idle
    private(set) var events: [String] = []
    private(set) var workspaces: [WorkspaceTarget] = []
    private(set) var activeWorkspaceKey: String?
    private(set) var bridgeSessionID: String?
    private(set) var bridgeGeneration: Int?
    private(set) var rpcEvents: [RPCMessage] = []
    private var rpcSequence = 0

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reassembler = FragmentReassembler()

    /// `jwt` is the z.ai bearer token from the account's Keychain entry.
    /// Without it the relay cannot issue a one-time terminal token.
    func connect(session: RemoteSession, jwt: String) async {
        disconnect()
        state = .connecting
        note("Запрос одноразового токена terminal")
        do {
            let token = try await requestToken(jwt: jwt)
            try await openSocket(token: token, session: session)
        } catch {
            state = .failed(error.localizedDescription)
            note("Ошибка: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        reassembler.reset()
        state = .idle
    }

    // MARK: - Relay V2 handshake

    private func requestToken(jwt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://zcode.z.ai/api/v1/remote/token")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["role": "terminal"])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NativeError.relay("HTTP \(status)")
        }
        let result = try NativeRemoteProtocol.decoder.decode(TokenResponse.self, from: data)
        guard result.code == 0, let token = result.data?.token else {
            throw NativeError.relay(result.msg)
        }
        note("Токен получен, TTL \(result.data?.expiresIn ?? 0) с")
        return token
    }

    private func openSocket(token: String, session: RemoteSession) async throws {
        var components = URLComponents(string: "wss://zcode.z.ai/api/v1/remote/ws2")!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "mid", value: session.mid),
        ]
        guard let url = components.url else { throw NativeError.relay("bad ws url") }

        let task = URLSession.shared.webSocketTask(with: url)
        self.socket = task
        task.resume()

        let auth: [String: Any] = [
            "type": "auth_init",
            "device_sid": session.sid,
            "client_ts": Int(Date().timeIntervalSince1970),
        ]
        try await send(auth)
        note("auth_init отправлен")

        startReceiveLoop()
        startHeartbeat()
    }

    private func send(_ object: [String: Any]) async throws {
        guard let socket else { throw NativeError.relay("no socket") }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NativeError.relay("bad frame")
        }
        try await socket.send(.string(text))
    }

    // MARK: - App payload layer

    func requestBootstrap() async throws {
        let requestID = UUID().uuidString
        try await sendDataPayload([
            "zcode_type": "bootstrap-request",
            "requestId": requestID,
            "terminalClientSessionId": requestID,
        ])
        note("bootstrap-request \(requestID)")
    }

    func requestWorkspaceList() async throws {
        let requestID = UUID().uuidString
        try await sendDataPayload([
            "zcode_type": "workspace-list-request",
            "requestId": requestID,
        ])
        note("workspace-list-request \(requestID)")
    }

    func openBridge(workspace: WorkspaceTarget, taskID: String? = nil) async throws {
        let requestID = UUID().uuidString
        let bridgeID = UUID().uuidString
        var payload: [String: Any] = [
            "zcode_type": "workspace-bridge-open",
            "requestId": requestID,
            "bridgeSessionId": bridgeID,
            "workspaceKey": workspace.workspaceIdentity ?? workspace.workspacePath,
        ]
        if let taskID { payload["taskId"] = taskID }
        try await sendDataPayload(payload)
        bridgeSessionID = bridgeID
        note("workspace-bridge-open: \(workspace.label)")
    }

    func sendViewState(activeWorkspaceKey: String?, activeTaskID: String?) async throws {
        var viewState: [String: Any] = ["updatedAt": Int(Date().timeIntervalSince1970) * 1000]
        if let activeWorkspaceKey { viewState["activeWorkspaceKey"] = activeWorkspaceKey }
        if let activeTaskID { viewState["activeTaskId"] = activeTaskID }
        try await sendDataPayload([
            "zcode_type": "mobile-view-state-update",
            "viewState": viewState,
        ])
    }

    /// Sends one RPC request as a single (non-fragmented) `rpc-frame`.
    func callRPC(channel: String, method: String, arguments: RPCValue) async throws {
        guard let bridgeSessionID else {
            throw NativeError.relay("bridge not ready")
        }
        let bytes = RPCMessage.request(
            id: rpcSequence + 1,
            channel: channel,
            method: method,
            arguments: arguments
        )
        rpcSequence += 1
        var payload: [String: Any] = [
            "zcode_type": "rpc-frame",
            "bridgeSessionId": bridgeSessionID,
            "seq": rpcSequence,
            "messageSeq": rpcSequence,
            "fragmentIndex": 0,
            "fragmentCount": 1,
            "messageBytes": bytes.count,
            "dataBase64": bytes.base64EncodedString(),
            "checksum": ["algorithm": "crc32", "value": CRC32.hex(bytes)],
        ]
        if let generation = bridgeGeneration { payload["bridgeGeneration"] = generation }
        try await sendDataPayload(payload)
        note("RPC → \(channel).\(method)")
    }

    /// Minimal task-list service call from `zcodeTaskService`.
    func listTasks(workspacePath: String, workspaceIdentity: String?) async throws {
        var arguments: [String: Any] = ["workspacePath": workspacePath]
        if let workspaceIdentity { arguments["workspaceIdentity"] = workspaceIdentity }
        let json = String(
            decoding: try JSONSerialization.data(withJSONObject: arguments),
            as: UTF8.self
        )
        try await callRPC(
            channel: "zcodeTaskService",
            method: "listTasks",
            arguments: .object(json)
        )
    }

    private func sendDataPayload(_ payload: [String: Any]) async throws {
        try await send([
            "type": "data",
            "payload": payload,
            "client_ts": Int(Date().timeIntervalSince1970),
        ])
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let socket = self.socket else { return }
                do {
                    let message = try await socket.receive()
                    switch message {
                    case .string(let text):
                        await self.handle(text: text)
                    case .data(let data):
                        self.note("Получено \(data.count) бинарных байт (не ожидалось)")
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        await MainActor.run { self.state = .failed(error.localizedDescription) }
                        self.note("Соединение закрыто: \(error.localizedDescription)")
                    }
                    return
                }
            }
        }
    }

    private func handle(text: String) async {
        guard let message = NativeRemoteProtocol.parse(text) else {
            note("Неразбираемое сообщение relays")
            return
        }
        switch message.type {
        case "auth_ack":
            let status = message.payload?.pairStatus ?? "unknown"
            state = .paired(pairStatus: status)
            note("auth_ack: \(status)")

        case "pair_status_ack":
            note("pair_status_ack: \(message.payload?.pairStatus ?? "unknown")")

        case "data":
            await handleData(message.payload)

        case "error":
            state = .failed(message.payload?.reason ?? "relay error")
            note("error: \(message.payload?.reason ?? "unknown")")

        default:
            note("Неизвестный тип: \(message.type)")
        }
    }

    private func handleData(_ payload: RemoteWSPayload?) async {
        guard let payload, let kind = payload.zcodeType else {
            note("data без zcode_type")
            return
        }
        note("payload: \(kind)")

        switch kind {
        case "bootstrap-response", "workspace-list-response", "workspace-list-updated":
            applyWorkspaces(payload.result)

        case "workspace-bridge-ready":
            bridgeSessionID = payload.result?.bridgeSessionId ?? payload.bridgeSessionId
            bridgeGeneration = payload.result?.bridgeGeneration ?? payload.bridgeGeneration
            note("мост готов: \(bridgeSessionID ?? "—")")

        case "rpc-frame":
            guard let base64 = payload.dataBase64,
                  let complete = reassembler.add(
                      base64: base64,
                      index: payload.fragmentIndex,
                      count: payload.fragmentCount,
                      bytes: payload.messageBytes
                  ) else { return }
            note("RPC-кадр собран: \(complete.count) байт")
            if let rpc = try? RPCMessage.decode(complete) {
                rpcEvents.append(rpc)
                if rpcEvents.count > 200 { rpcEvents.removeFirst(rpcEvents.count - 200) }
                note("RPC \(rpc.type) id=\(rpc.id) \(rpc.channel)")
            } else {
                note("RPC-кадр не разобран")
            }
            if let seq = payload.messageSeq {
                let ack: [String: Any] = [
                    "type": "data",
                    "payload": [
                        "zcode_type": "rpc-frame-ack",
                        "bridgeSessionId": payload.bridgeSessionId ?? "",
                        "ackMessageSeq": seq,
                    ] as [String: Any],
                    "client_ts": Int(Date().timeIntervalSince1970),
                ]
                try? await send(ack)
            }

        case "bridge-degraded", "app-error":
            note("Событие моста: \(kind) \(payload.reason ?? "")")

        default:
            // Bootstrap, workspace-list, view-state and action payloads are
            // handled by the app layer; the transport only reports them here.
            break
        }
    }

    private func applyWorkspaces(_ result: AppPayloadResult?) {
        guard let result else { return }
        if let workspaces = result.workspaces {
            self.workspaces = workspaces
        }
        if let key = result.activeWorkspaceKey {
            activeWorkspaceKey = key
        }
        note("пространств: \(result.workspaces?.count ?? 0), активное: \(result.activeWorkspaceKey ?? "—")")
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                try? await self.send([
                    "type": "pair_status_query",
                    "client_ts": Int(Date().timeIntervalSince1970),
                ])
            }
        }
    }

    private func note(_ text: String) {
        events.append(text)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        AppLog.shared.log("[native-ws] \(text)", category: .network)
    }
}

nonisolated enum NativeError: LocalizedError {
    case relay(String)

    var errorDescription: String? {
        switch self {
        case .relay(let message): "Relay: \(message)"
        }
    }
}
