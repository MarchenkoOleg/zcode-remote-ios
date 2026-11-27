import SwiftUI

/// Accounts and their sessions on a single screen: every account is a
/// section with its remote links directly underneath.
struct AccountListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.editMode) private var editMode
    @State private var showAddAccount = false
    @State private var accountForNewSession: UUID?
    @State private var showAddSession = false
    @State private var editingSession: RemoteSession?
    @State private var showLogs = false
    @State private var nativeSession: NativeSessionTarget?
    @State private var showQRScanner = false
    @State private var scannedFields: ScannedFields?
    @State private var qrError: String?

    private struct ScannedFields: Identifiable {
        let id = UUID()
        let fields: RemoteLink.Fields
    }

    private struct NativeSessionTarget: Identifiable {
        let id: UUID
    }

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    var body: some View {
        List {
            if model.accounts.isEmpty {
                ContentUnavailableView {
                    Label("Нет аккаунтов", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Добавьте аккаунт ZCode: у каждого будут свои куки и авторизация.")
                } actions: {
                    Button("Добавить аккаунт") { showAddAccount = true }
                }
            } else {
                ForEach(model.accounts) { account in
                    Section {
                        ForEach(model.sessions(for: account.id)) { session in
                            Group {
                                if isEditing {
                                    Button { editingSession = session } label: {
                                        SessionRow(session: session)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink(value: Route.remote(session.id)) {
                                        SessionRow(session: session)
                                    }
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    editingSession = session
                                } label: {
                                    Label("Изменить", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    model.deleteSession(session.id)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                        if model.sessions(for: account.id).isEmpty {
                            Text("Нет сессий")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            accountForNewSession = account.id
                            showAddSession = true
                        } label: {
                            Label("Добавить сессию", systemImage: "plus.circle")
                                .font(.subheadline)
                        }
                    } header: {
                        AccountHeader(account: account, onAddSession: {
                            accountForNewSession = account.id
                            showAddSession = true
                        })
                    }
                }
            }
        }
        .navigationTitle("Аккаунты и сессии")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await model.versionChecker.check(force: true) }
                    } label: {
                        Label("Проверить версию", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        withAnimation { editMode?.wrappedValue = .active }
                    } label: {
                        Label("Изменить сессии", systemImage: "pencil")
                    }
                    Button {
                        if let id = model.selectedSessionID ?? model.sessions.first?.id {
                            nativeSession = NativeSessionTarget(id: id)
                        }
                    } label: {
                        Label("Нативный режим (бета)", systemImage: "bolt")
                    }
                    Button {
                        showLogs = true
                    } label: {
                        Label("Логи и сеть", systemImage: "doc.text.magnifyingglass")
                    }
                    Menu {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Button {
                                model.language = language
                            } label: {
                                Label(
                                    LocalizedStringKey(language.label),
                                    systemImage: model.language == language
                                        ? "checkmark"
                                        : "globe"
                                )
                            }
                        }
                    } label: {
                        Label("Язык", systemImage: "globe")
                    }
                    Menu {
                        ForEach(HomeButtonPlacement.allCases, id: \.self) { placement in
                            Button {
                                model.homeButtonPlacement = placement
                            } label: {
                                Label(
                                    LocalizedStringKey(placement.label),
                                    systemImage: model.homeButtonPlacement == placement
                                        ? "checkmark"
                                        : "house"
                                )
                            }
                        }
                    } label: {
                        Label("Кнопка «Домой»", systemImage: "house")
                    }
                    if let latest = model.versionChecker.latest {
                        Text("Последняя версия") + Text(": \(latest)")
                    }
                } label: {
                    Image(systemName: "info.circle")
                }
                if isEditing {
                    Button("Готово") {
                        withAnimation { editMode?.wrappedValue = .inactive }
                    }
                }
                Button { showQRScanner = true } label: {
                    Image(systemName: "qrcode.viewfinder")
                }
                Button { showAddAccount = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountView()
        }
        .sheet(isPresented: $showAddSession) {
            if let accountID = accountForNewSession {
                AddSessionView(accountID: accountID)
            }
        }
        .sheet(item: $editingSession) { session in
            EditSessionView(session: session)
        }
        .sheet(isPresented: $showLogs) {
            LogView()
        }
        .sheet(item: $nativeSession) { target in
            NativeSessionView(sessionID: target.id)
        }
        .sheet(isPresented: $showQRScanner) {
            NavigationStack {
                QRScannerView { code in
                    handleScanned(code)
                }
                .navigationTitle("Сканировать QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отмена") { showQRScanner = false }
                    }
                }
            }
        }
        .sheet(item: $scannedFields) { scanned in
            if let accountID = model.selectedAccountID ?? model.accounts.first?.id {
                AddSessionView(
                    accountID: accountID,
                    initialFields: scanned.fields,
                    allowsAccountSelection: true
                )
            }
        }
        .alert("QR-код не распознан", isPresented: Binding(
            get: { qrError != nil },
            set: { if !$0 { qrError = nil } }
        )) {
            Button("Ок", role: .cancel) {}
        }
        .task {
            if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("qr-code=") }) {
                handleScanned(String(argument.dropFirst("qr-code=".count)))
            }
            if CommandLine.arguments.contains("native"),
               let id = model.selectedSessionID ?? model.sessions.first?.id {
                nativeSession = NativeSessionTarget(id: id)
            }
            await model.versionChecker.check()
        }
    }
    private func handleScanned(_ code: String) {
        guard let fields = RemoteLink.parse(code) else {
            qrError = code
            return
        }
        showQRScanner = false
        if model.accounts.isEmpty {
            model.addAccount(
                label: fields.name.isEmpty ? "ZCode" : fields.name,
                username: "",
                token: nil
            )
        }
        scannedFields = ScannedFields(fields: fields)
    }
}

private struct AccountHeader: View {
    @Environment(AppModel.self) private var model
    let account: ZCodeAccount
    let onAddSession: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(account.initials)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.gradient, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                    .font(.headline)
                if !account.username.isEmpty {
                    Text(account.username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.token(for: account.id) != nil {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
            }
            Menu {
                Button(action: onAddSession) {
                    Label("Добавить сессию", systemImage: "plus")
                }
                Button(role: .destructive) {
                    model.deleteAccount(account.id)
                } label: {
                    Label("Удалить аккаунт", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: RemoteSession

    private var outdated: Bool {
        model.versionChecker.isOutdated(session.appVersion)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("sid \(session.sid) · v\(session.appVersion)")
                    if outdated {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if outdated, let latest = model.versionChecker.latest {
                    Text("доступна") + Text(" \(latest)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            statusIcon
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.connectionStates[session.id] {
        case .connected:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsAuth:
            Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.orange)
        case .loading:
            ProgressView().controlSize(.small)
        case .offline:
            Image(systemName: "wifi.slash").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .idle, nil:
            EmptyView()
        }
    }
}
