import Foundation

/// Starred session ids, persisted so they survive restarts.
///
/// Keyed by session id rather than by pid or path: the whole point is that a starred session
/// outlives the process that was running it.
struct Favorites {

    private(set) var ids: Set<String> = []

    private static var storeURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("starred.json")
    }

    static func load() -> Favorites {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return Favorites() }
        return Favorites(ids: Set(decoded))
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    mutating func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(ids).sorted()) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
