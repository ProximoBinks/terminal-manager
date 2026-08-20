import Foundation
import ServiceManagement

/// A session that was live (or paused) the last time we saw it. After a reboot, a crash, or a
/// closed terminal the process is gone, but the row stays in its project group until the user
/// resumes it or dismisses it.
struct RememberedSession: Codable, Hashable, Identifiable {
    var id: String
    var kind: SessionKind
    var directory: String
    var title: String
    var wasPaused: Bool
    var lastSeen: Date

    func stubRecord() -> SessionRecord {
        let exists = DirectoryResolver.exists(directory)
        return SessionRecord(
            id: id,
            filePath: "",
            cwd: directory,
            title: title.isEmpty ? "(untitled session)" : title,
            lastPrompt: "",
            modified: lastSeen,
            byteSize: 0,
            projectFolder: SessionIndex.encodeProjectFolder(directory),
            currentDirectory: exists ? directory : "",
            kind: kind
        )
    }
}

/// UI preferences and the live-session roster, persisted next to `starred.json`.
struct AppMemory: Codable {
    var showArchived: Bool = false
    var expansion: [String: Bool] = [:]
    var remembered: [RememberedSession] = []

    private static let expiration: TimeInterval = 14 * 24 * 60 * 60

    private static var storeURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("preferences.json")
    }

    static func load() -> AppMemory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? decoder.decode(AppMemory.self, from: data)
        else { return AppMemory() }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    /// Writes every currently live session into the roster. Entries whose process has vanished
    /// (reboot, crash, closed window) are kept until dismissed, resumed back to live, or 14 days
    /// have passed since they were last seen running.
    mutating func rememberLive(_ live: [ManagedSession]) {
        var map: [String: RememberedSession] = [:]
        for item in remembered { map[item.id] = item }

        var liveIDs: Set<String> = []
        for session in live {
            guard let id = session.record?.id else { continue }
            liveIDs.insert(id)
            map[id] = RememberedSession(
                id: id,
                kind: session.kind,
                directory: session.directory,
                title: session.title,
                wasPaused: session.isPaused,
                lastSeen: Date()
            )
        }

        let cutoff = Date().addingTimeInterval(-Self.expiration)
        remembered = map.values.filter { liveIDs.contains($0.id) || $0.lastSeen >= cutoff }
        save()
    }

    mutating func forget(_ id: String) {
        remembered.removeAll { $0.id == id }
        save()
    }
}

enum LoginItem {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("TerminalManager login item: \(error.localizedDescription)")
        }
    }
}
