import Foundation
import OSLog

/// Small JSON store for account/session metadata. Deliberately not Keychain:
/// only secrets go there, and the list must be cheap to read on launch.
@MainActor
final class Store {
    var state: PersistedState
    private let fileURL: URL
    private let logger = Logger(subsystem: "ru.ligarobotov.zcode-remote", category: "store")

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("ZCodeRemote", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                logger.error("Cannot create store directory: \(error.localizedDescription, privacy: .public)")
            }
        }
        self.fileURL = directory.appendingPathComponent("store.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            self.state = decoded
        } else {
            self.state = PersistedState()
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Cannot save store: \(error.localizedDescription, privacy: .public)")
        }
    }
}
