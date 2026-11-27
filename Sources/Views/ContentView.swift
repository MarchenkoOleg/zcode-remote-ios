import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Route] = []
    @State private var showLogs = false

    var body: some View {
        NavigationStack(path: $path) {
            AccountListView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .remote(let sessionID):
                        RemoteSessionView(sessionID: sessionID)
                    }
                }
        }
        .sheet(isPresented: $showLogs) {
            LogView()
        }
        .onAppear {
            if CommandLine.arguments.contains("show-logs") { showLogs = true }
            // Debug/testing entry point: `open-session=<uuid>` on launch.
            guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("open-session=") }),
                  let id = UUID(uuidString: String(argument.dropFirst("open-session=".count))),
                  model.session(id: id) != nil else { return }
            path = [.remote(id)]
        }
        .onOpenURL { url in
            guard url.scheme == "zcode-remote", url.host == "session" else { return }
            let rawID = url.pathComponents.dropFirst().first ?? ""
            guard let id = UUID(uuidString: rawID),
                  model.session(id: id) != nil else { return }
            path = [.remote(id)]
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.handleBecameActive()
            case .background:
                model.handleBackground()
            default:
                break
            }
        }
        .environment(\.locale, model.locale)
    }
}
