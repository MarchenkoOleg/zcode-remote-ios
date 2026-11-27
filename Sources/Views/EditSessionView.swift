import SwiftUI

struct EditSessionView: View {
    let session: RemoteSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var sid: String
    @State private var mid: String
    @State private var appVersion: String

    init(session: RemoteSession) {
        self.session = session
        _name = State(initialValue: session.name)
        _sid = State(initialValue: session.sid)
        _mid = State(initialValue: session.mid)
        _appVersion = State(initialValue: session.appVersion)
    }

    private var canSave: Bool {
        !sid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !mid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Сессия") {
                    TextField("Имя машины", text: $name)
                    TextField("sid", text: $sid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("mid", text: $mid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("Версия ZCode", text: $appVersion)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if let latest = model.versionChecker.latest {
                        if model.versionChecker.isOutdated(appVersion) {
                            Label {
                                Text("Доступна версия") + Text(" \(latest) — ")
                                + Text("используется") + Text(" \(appVersion)")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .foregroundStyle(.orange)
                            .font(.footnote)
                            Button {
                                appVersion = latest
                            } label: {
                                Text("Перейти на") + Text(" \(latest)")
                            }
                        } else {
                            Label("Версия актуальна", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.footnote)
                        }
                    } else if let error = model.versionChecker.errorMessage {
                        Text("Не удалось проверить версию") + Text(": \(error)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await model.versionChecker.check(force: true) }
                    } label: {
                        Label("Проверить последнюю версию", systemImage: "arrow.triangle.2.circlepath")
                    }
                } header: {
                    Text("Версия")
                } footer: {
                    Text("Изменения применяются к существующей сессии: авторизация и история остаются, обновляется только ссылка.")
                }
            }
            .navigationTitle("Изменить сессию")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let updated = RemoteSession(
                            id: session.id,
                            accountID: session.accountID,
                            sid: sid,
                            mid: mid,
                            name: name,
                            appVersion: appVersion,
                            createdAt: session.createdAt,
                            lastOpenedAt: session.lastOpenedAt
                        )
                        model.updateSession(updated)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
