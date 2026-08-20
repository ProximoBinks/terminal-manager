import Foundation

/// A session as presented in the UI: the transcript on disk, plus the live process and
/// terminal tab backing it when one exists.
struct ManagedSession: Identifiable, Hashable {
    /// Live rows are keyed by pid: two windows can legitimately share one transcript, and
    /// duplicate identifiers would collapse them in the list.
    var id: String {
        if let process { return "pid-\(process.pid)" }
        return record?.id ?? UUID().uuidString
    }

    var record: SessionRecord?
    var process: LiveProcess?
    var window: TerminalWindow?
    /// Set when this row is a remembered live session whose process has gone (reboot, crash,
    /// closed terminal) rather than being Freed through the app.
    var interruption: RememberedSession? = nil

    var isLive: Bool { process != nil }
    var isPaused: Bool { process?.isStopped ?? false }
    var isInterrupted: Bool { interruption != nil && process == nil }
    var ramBytes: Int { process?.treeRSS ?? 0 }

    var title: String {
        if let title = window?.title, !title.isEmpty { return title }
        if let title = record?.title, !title.isEmpty { return title }
        if let title = interruption?.title, !title.isEmpty { return title }
        return "(unknown session)"
    }

    /// A live process's cwd is authoritative and always exists. Otherwise use the directory the
    /// index located on disk, falling back to the transcript's recorded value purely for display.
    var directory: String {
        if let cwd = process?.cwd { return cwd }
        if let current = record?.currentDirectory, !current.isEmpty { return current }
        if let remembered = interruption?.directory, !remembered.isEmpty { return remembered }
        return record?.cwd ?? ""
    }

    /// False when the project folder has been moved or deleted, so no `cd` can be offered.
    var directoryExists: Bool {
        if process != nil { return true }
        return !(record?.currentDirectory.isEmpty ?? true)
    }

    /// Set when the directory recorded in the transcript is gone but the folder was found
    /// elsewhere, which is worth surfacing because the old path will not work.
    var directoryWasRelocated: Bool {
        guard let record, !record.currentDirectory.isEmpty else { return false }
        return record.currentDirectory != record.cwd
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return directory.hasPrefix(home) ? "~" + directory.dropFirst(home.count) : directory
    }

    var kind: SessionKind {
        record?.kind ?? process?.kind ?? interruption?.kind ?? .claude
    }

    /// `--resume <id>` finds the session wherever it is run from, but the session's own file paths
    /// assume its project directory, so the command cds there first. If that directory no longer
    /// exists the cd is dropped rather than emitted — a failing `cd` before `&&` would stop
    /// the CLI from running at all.
    var resumeCommand: String? {
        guard let id = record?.id else { return nil }
        let launch = "\(kind.cliName) --resume \(id)"
        guard directoryExists, !directory.isEmpty else { return launch }
        let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted) && \(launch)"
    }

    /// The bare form, for when the terminal is already in the right directory.
    var shortResumeCommand: String? {
        guard let id = record?.id else { return nil }
        return "\(kind.cliName) --resume \(id)"
    }

    var lastActive: Date {
        if let process, process.elapsed > 0, record == nil { return process.startedAt }
        if isInterrupted, let seen = interruption?.lastSeen { return seen }
        return record?.modified ?? .distantPast
    }

    /// Free-text haystack used by the search field.
    var searchText: String {
        [
            title,
            displayPath,
            record?.id ?? "",
            record?.lastPrompt ?? "",
            kind.displayName,
            kind.cliName,
            process.map { "pid \($0.pid) \($0.tty ?? "")" } ?? "",
            process?.host.rawValue ?? "",
            isPaused ? "paused" : "",
            isInterrupted ? "interrupted stopped" : ""
        ].joined(separator: " ").lowercased()
    }
}

enum SessionMatcher {

    /// Joins live processes, terminal tabs and on-disk transcripts into a single list.
    static func merge(
        processes: [LiveProcess],
        windows: [String: TerminalWindow],
        records: [SessionRecord],
        remembered: [RememberedSession] = []
    ) -> [ManagedSession] {

        var recordsByFolder: [String: [SessionRecord]] = [:]
        for record in records {
            recordsByFolder[record.projectFolder, default: []].append(record)
        }
        for key in recordsByFolder.keys {
            recordsByFolder[key]?.sort { $0.modified > $1.modified }
        }

        var claimed: Set<String> = []
        var live: [ManagedSession] = []

        for process in processes {
            let window = process.tty.flatMap { windows[$0] }
            let candidates = candidateRecords(for: process.cwd, in: recordsByFolder)
                .filter { $0.kind == process.kind }
            let match = resolve(process: process, window: window, candidates: candidates, claimed: claimed)
            if let match { claimed.insert(match.id) }
            live.append(ManagedSession(record: match, process: process, window: window))
        }

        var recordsByID: [String: SessionRecord] = [:]
        for record in records { recordsByID[record.id] = record }

        var interrupted: [ManagedSession] = []
        for item in remembered {
            if claimed.contains(item.id) { continue }
            let record = recordsByID[item.id] ?? item.stubRecord()
            claimed.insert(item.id)
            interrupted.append(
                ManagedSession(record: record, process: nil, window: nil, interruption: item)
            )
        }

        let archived = records
            .filter { !claimed.contains($0.id) }
            .map { ManagedSession(record: $0, process: nil, window: nil) }

        return live.sorted { $0.ramBytes > $1.ramBytes }
            + interrupted.sorted { $0.lastActive > $1.lastActive }
            + archived.sorted { $0.lastActive > $1.lastActive }
    }

    /// Maps a working directory to its transcripts using Claude Code's own folder naming. A
    /// process may have moved into a subdirectory since launch, so walk up to the nearest
    /// ancestor that actually has sessions.
    private static func candidateRecords(
        for cwd: String?,
        in index: [String: [SessionRecord]]
    ) -> [SessionRecord] {
        guard let cwd else { return [] }

        var path = cwd
        while true {
            if let hit = index[SessionIndex.encodeProjectFolder(path)] { return hit }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return [] }
            path = parent
        }
    }

    /// Picks the transcript a running process is writing to, in descending order of confidence.
    private static func resolve(
        process: LiveProcess,
        window: TerminalWindow?,
        candidates: [SessionRecord],
        claimed: Set<String>
    ) -> SessionRecord? {

        let available = candidates.filter { !claimed.contains($0.id) }
        guard !available.isEmpty else { return nil }

        // 1. The terminal tab title, when the CLI writes it, matches the generated session title.
        if let title = window?.title, !title.isEmpty {
            if let hit = available.first(where: { $0.title == title }) { return hit }
        }

        // A live session's transcript is always touched after its process started. Allow a little
        // slack because ps reports elapsed time at second granularity.
        let launch = process.startedAt.addingTimeInterval(-120)
        let touchedSinceLaunch = available.filter { $0.modified >= launch }

        // 2. The id passed to `--resume`, but only if that transcript is still being appended to.
        //    Resuming often forks into a fresh transcript, so this is a hint rather than an answer.
        if let resumeID = process.resumeArgument,
           let hit = touchedSinceLaunch.first(where: { $0.id == resumeID }) {
            return hit
        }

        // 3. The most recently written transcript for this directory.
        if let hit = touchedSinceLaunch.first { return hit }

        // 4. Fall back to the resume id even if stale, so the UI can still show something useful.
        if let resumeID = process.resumeArgument,
           let hit = available.first(where: { $0.id == resumeID }) {
            return hit
        }

        // 5. Last resort: the id this process was launched with, even though another window
        //    already claimed that transcript. Two windows resuming one session is a real
        //    situation, and showing the id the user typed beats showing nothing.
        if let resumeID = process.resumeArgument,
           let hit = candidates.first(where: { $0.id == resumeID }) {
            return hit
        }

        return nil
    }
}
