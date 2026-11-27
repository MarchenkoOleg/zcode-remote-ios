import SwiftUI

struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var username = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Аккаунт") {
                    TextField("Название, например Oleg", text: $label)
                    TextField("Логин z.ai (необязательно)", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    SecureField("Токен (необязательно)", text: $token)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Авторизация")
                } footer: {
                    Text("Токен хранится в Keychain только на этом устройстве. Основная авторизация живёт в изолированном хранилище аккаунта — можно оставить поле пустым и войти в веб-интерфейсе.")
                }
            }
            .navigationTitle("Новый аккаунт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        model.addAccount(label: label, username: username, token: token)
                        dismiss()
                    }
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
