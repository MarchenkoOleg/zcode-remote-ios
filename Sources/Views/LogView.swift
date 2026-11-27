import SwiftUI
import UIKit

struct LogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter: AppLog.Category?

    private var entries: [AppLog.Entry] {
        let all = model.log.entries.reversed()
        guard let filter else { return Array(all) }
        return all.filter { $0.category == filter }
    }

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Записей нет",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Логи появятся после подключения к серверу.")
                    )
                } else {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(Self.time.string(from: entry.date))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(entry.category.rawValue.uppercased())
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: .capsule)
                                if entry.level != .info {
                                    Image(systemName: entry.level == .error
                                          ? "exclamationmark.octagon.fill"
                                          : "exclamationmark.triangle.fill")
                                        .foregroundStyle(entry.level == .error ? .red : .orange)
                                }
                            }
                            Text(entry.message)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Логи")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Все") { filter = nil }
                        ForEach(AppLog.Category.allCases, id: \.self) { category in
                            Button(category.rawValue) { filter = category }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    Button { share() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { model.log.clear() } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .task {
            // Debug/testing entry point: verify the share sheet without taps.
            guard CommandLine.arguments.contains("share-log") else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            share()
        }
    }

    private func share() {
        let text = entries.reversed().map { entry in
            "\(Self.time.string(from: entry.date)) [\(entry.category.rawValue)/\(entry.level.rawValue)] \(entry.message)"
        }.joined(separator: "\n")

        // Sharing as a file keeps long logs usable in Mail/Files and avoids
        // relying on a huge text item in the share sheet.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zcode-remote-\(Int(Date().timeIntervalSince1970)).log")
        var items: [Any] = [text]
        if let data = text.data(using: .utf8), (try? data.write(to: url, options: .atomic)) != nil {
            items = [url]
        }

        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // LogView itself is presented as a sheet, so the root view controller
        // is covered and silently refuses the presentation. Use the topmost.
        guard let presenter = Self.topViewController() else {
            AppLog.shared.log("Экспорт логов: не найден контроллер для показа", category: .app, level: .error)
            return
        }
        AppLog.shared.log("Экспорт логов: \(items.count) item(s), показан через \(type(of: presenter))", category: .app)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    private static func topViewController(from base: UIViewController? = nil) -> UIViewController? {
        let base = base ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        if let navigation = base as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let presented = base?.presentedViewController {
            return topViewController(from: presented)
        }
        return base
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
