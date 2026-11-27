import SwiftUI

struct RemoteSessionView: View {
    let sessionID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var session: RemoteSession? { model.session(id: sessionID) }
    private var account: ZCodeAccount? {
        guard let session else { return nil }
        return model.account(id: session.accountID)
    }

    /// ZCode v4 mirrors the Mac desktop over WebSocket, so the page DOM only
    /// contains relay status — it cannot tell a chat from the project list.
    /// The button is therefore always available; the user chooses whether it
    /// sits in ZCode's empty header slot or in a slim strip at the bottom.
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let session, let account {
                    RemoteWebView(session: session, account: account)
                } else {
                    ContentUnavailableView("Сессия удалена", systemImage: "link.badge.plus")
                }
            }

            if model.homeButtonPlacement == .bottom {
                bottomBar
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.homeButtonPlacement == .overlay {
                homeButton
            }
        }
        .navigationBarHidden(true)
        .sheet(item: Bindable(model).authRequest) { request in
            NavigationStack {
                AuthWebView(url: request.url, account: request.account)
                    .navigationTitle("Авторизация")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Готово") { model.finishAuth() }
                        }
                    }
            }
        }
        .task {
            model.touchSession(sessionID)
            // Debug/testing entry point: `force-page=<kind>` pins the screen.
            if let forced = CommandLine.arguments.first(where: { $0.hasPrefix("force-page=") }),
               let kind = RemotePageKind(rawValue: String(forced.dropFirst("force-page=".count))) {
                model.setPageKind(kind, for: sessionID)
            }
        }
    }

    private var homeCapsule: some View {
        Button { dismiss() } label: {
            HStack(spacing: 5) {
                Image(systemName: "house.fill")
                Text("Домой")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .clipShape(Capsule())
    }

    private var homeButton: some View {
        // ZCode's header sits just below the status bar; keep the button in
        // its empty slot, clear of the chevron / palette icons on the right.
        homeCapsule
            .padding(.trailing, 58)
            .padding(.top, 2)
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            homeCapsule
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(.bar)
    }
}
