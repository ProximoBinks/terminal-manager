import Foundation

/// Sessions belonging to one project directory, which is how the list is organised.
struct ProjectGroup: Identifiable {
    var id: String { key }

    static let starredKey = "__starred__"

    let key: String            // Claude-style encoding of the project directory
    let name: String           // "terminal-manager", "Downloads", "Home", or a tag name
    let path: String           // "~/Documents/GitHub/terminal-manager"
    var sessions: [ManagedSession]
    /// Set when this is a Starred subgroup clustered by a tag.
    var starredTag: Tag? = nil

    var isStarredSection: Bool { key == Self.starredKey || key.hasPrefix(Self.starredKey + ":") }

    var liveCount: Int { sessions.filter(\.isLive).count }
    var interruptedCount: Int { sessions.filter(\.isInterrupted).count }
    var ramBytes: Int { sessions.reduce(0) { $0 + $1.ramBytes } }
    var lastActive: Date { sessions.map(\.lastActive).max() ?? .distantPast }

    /// Starred sessions are lifted into a single section at the top rather than left scattered
    /// across projects, so the answer to "what was I in the middle of" is always in one place.
    static func build(
        from sessions: [ManagedSession],
        starred: Set<String>,
        tags: TagStore = TagStore()
    ) -> [ProjectGroup] {
        let starredSessions = sessions.filter { session in
            guard let id = session.record?.id else { return false }
            return starred.contains(id)
        }
        let starredIDs = Set(starredSessions.compactMap { $0.record?.id })

        var buckets: [String: [ManagedSession]] = [:]
        for session in sessions {
            if let id = session.record?.id, starredIDs.contains(id) { continue }
            buckets[groupKey(for: session), default: []].append(session)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        return buckets.map { key, members in
            // Prefer a live process's directory: it is current, where a transcript's recorded
            // directory can be stale if the folder was moved.
            let directory = members.first(where: { $0.isLive })?.directory
                ?? members.first(where: { $0.isInterrupted })?.directory
                ?? members.first?.directory
                ?? ""

            let name: String
            if directory == home {
                name = "Home"
            } else if directory.isEmpty {
                name = key
            } else {
                name = (directory as NSString).lastPathComponent
            }

            let display = directory.hasPrefix(home)
                ? "~" + directory.dropFirst(home.count)
                : directory

            let ordered = Self.ordered(members)

            return ProjectGroup(key: key, name: name, path: String(display), sessions: ordered)
        }
        .sorted { left, right in
            // Projects with something running float to the top, then interrupted, then recent.
            if (left.liveCount > 0) != (right.liveCount > 0) { return left.liveCount > 0 }
            if left.liveCount != right.liveCount { return left.liveCount > right.liveCount }
            if (left.interruptedCount > 0) != (right.interruptedCount > 0) {
                return left.interruptedCount > 0
            }
            return left.lastActive > right.lastActive
        }
        .prepending(starredGroups(from: starredSessions, tags: tags))
    }

    /// Starred sessions are clustered by their first tag so a long starred list stays scannable.
    /// Untagged starred rows stay in a trailing "Starred" section.
    private static func starredGroups(from sessions: [ManagedSession], tags: TagStore) -> [ProjectGroup] {
        guard !sessions.isEmpty else { return [] }

        var claimed: Set<String> = []
        var groups: [ProjectGroup] = []

        for tag in tags.tags {
            let members = sessions.filter { session in
                guard let id = session.record?.id else { return false }
                return tags.contains(tag, on: id) && !claimed.contains(id)
            }
            guard !members.isEmpty else { continue }
            for session in members {
                if let id = session.record?.id { claimed.insert(id) }
            }
            groups.append(
                ProjectGroup(
                    key: starredKey + ":" + tag.id,
                    name: tag.name,
                    path: "",
                    sessions: Self.ordered(members),
                    starredTag: tag
                )
            )
        }

        let untagged = sessions.filter { session in
            guard let id = session.record?.id else { return true }
            return !claimed.contains(id)
        }
        if !untagged.isEmpty {
            groups.append(
                ProjectGroup(key: starredKey, name: "Starred", path: "", sessions: Self.ordered(untagged))
            )
        }
        return groups
    }

    /// Running, then paused, then interrupted (process gone, still in this group), then saved.
    private static func ordered(_ members: [ManagedSession]) -> [ManagedSession] {
        members.sorted { left, right in
            if left.isLive != right.isLive { return left.isLive }
            if left.isPaused != right.isPaused { return !left.isPaused }
            if left.isInterrupted != right.isInterrupted { return left.isInterrupted }
            if left.isLive { return left.ramBytes > right.ramBytes }
            return left.lastActive > right.lastActive
        }
    }

    private static func groupKey(for session: ManagedSession) -> String {
        // Prefer the live directory so Claude and Grok sessions in the same repo share a section.
        if !session.directory.isEmpty { return SessionIndex.encodeProjectFolder(session.directory) }
        if let folder = session.record?.projectFolder, !folder.isEmpty { return folder }
        return "unknown"
    }
}


private extension Array where Element == ProjectGroup {
    func prepending(_ groups: [ProjectGroup]) -> [ProjectGroup] {
        groups + self
    }
}
