import SwiftUI

/// Native remote session: WKWebView is used only if a JWT is missing. All
/// further traffic goes through `NativeRemoteClient` without WebKit.
struct NativeSessionView: View {
    let sessionID: UUID
    @Environment(AppModel.self) private var model
    @State private var client = NativeRemoteClient()
    @State private var showSignIn = false
    @State private var errorMessage: String?

    private var session: RemoteSession? { model.session(id: sessionID) }
    private var account: ZCodeAccount? {
        guard let session else { return nil }
        return model.account(id: session.accountID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch client.state {
                    case .idle:
                        Text("Ожидание подключения")
                    case .connecting:
                        ProgressView("Подключение…")
                    case .paired(let status):
                        Label {
                            Text("Связано:") + Text(" \(status)")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Relay V2")
                }

                if !client.workspaces.isEmpty {
                    Section("Пространства") {
                        ForEach(client.workspaces, id: \.workspacePath) { workspace in
                            Button {
                                Task { try? await client.openBridge(workspace: workspace) }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(workspace.label)
                                    Text(workspace.workspacePath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !client.rpcEvents.isEmpty {
                    Section("RPC") {
                        ForEach(Array(client.rpcEvents.suffix(10).enumerated()), id: \.offset) { _, event in
                            Text("\(event.type) · \(event.id) · \(event.channel)")
                                .font(.caption2)
                        }
                    }
                }

                Section("События") {
                    ForEach(client.events.suffix(30), id: \.self) { event in
                        Text(event).font(.caption2)
                    }
                }
            }
            .navigationTitle("Нативный режим")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { client.disconnect() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task {
                            guard let workspace = client.workspaces.first else { return }
                            try? await client.listTasks(
                                workspacePath: workspace.workspacePath,
                                workspaceIdentity: workspace.workspaceIdentity
                            )
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    Button {
                        Task { await connect() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
        .task { await connect() }
        .sheet(isPresented: $showSignIn) {
            if let account {
                NavigationStack {
                    HybridSignInView(account: account) { token in
                        try? KeychainStore.save(token, for: account.id)
                        showSignIn = false
                        Task { await connect() }
                    }
                    .navigationTitle("Вход в z.ai")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    private func connect() async {
        guard let session, let account else { return }
        guard let jwt = KeychainStore.load(for: account.id) else {
            showSignIn = true
            return
        }
        await client.connect(session: session, jwt: jwt)
        if case .paired = client.state {
            try? await client.requestBootstrap()
            try? await client.requestWorkspaceList()
        }
    }
}
