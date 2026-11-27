import SwiftUI

struct AddSessionView: View {
    let accountID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var linkText = ""
    @State private var fields = RemoteLink.Fields(sid: "", mid: "", name: "", appVersion: "3.19.0")
    @State private var parseError: String?

    private var canSave: Bool {
        !fields.sid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !fields.mid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $linkText)
                        .frame(minHeight: 90)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Разобрать ссылку") { parse() }
                    if let parseError {
                        Text(parseError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Ссылка из ZCode")
                } footer: {
                    Text("Ссылка распознаётся автоматически, как только в ней появятся sid и mid.")
                }

                Section("Параметры") {
                    TextField("sid", text: $fields.sid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("mid", text: $fields.mid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Имя машины", text: $fields.name)
                    TextField("Версия приложения", text: $fields.appVersion)
                }
            }
            .onChange(of: linkText) { _, newValue in
                if let parsed = RemoteLink.parse(newValue) {
                    fields = parsed
                    parseError = nil
                }
            }
            .navigationTitle("Новая сессия")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        model.addSession(fields: fields, accountID: accountID)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func parse() {
        if let parsed = RemoteLink.parse(linkText) {
            fields = parsed
            parseError = nil
        } else {
            parseError = "Не удалось разобрать ссылку. Ожидается https://zcode.z.ai/remote/v4?sid=…&mid=…"
        }
    }
}
