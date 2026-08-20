import Foundation

/// One running Claude Code or Grok Build process together with everything it spawned.
struct LiveProcess: Identifiable, Hashable {
    var id: Int32 { pid }

    let pid: Int32
    let ppid: Int32
    let tty: String?           // e.g. "ttys004", nil when not attached to a terminal
    let selfRSS: Int           // bytes, this process only
    let treeRSS: Int           // bytes, this process plus all descendants
    let elapsed: TimeInterval  // seconds since launch
    let command: String
    let resumeArgument: String? // session id passed via `--resume <uuid>`, or Grok's live registry
    var cwd: String?
    var descendants: [Int32]
    var kind: SessionKind = .claude
    /// True when the CLI itself is `SIGSTOP`'d. Descendants are paused with it, but the root is
    /// what the UI keys off — a stopped session stays live, it just is not scheduled.
    var isStopped: Bool = false

    var startedAt: Date { Date(timeIntervalSinceNow: -elapsed) }

    /// True when the process belongs to a VS Code integrated terminal rather than Terminal.app.
    var host: TerminalHost = .unknown
}

enum TerminalHost: String {
    case terminalApp = "Terminal"
    case vscode = "VS Code"
    case unknown = "Detached"
}

private struct RawProcess {
    let pid: Int32
    let ppid: Int32
    let rss: Int
    let elapsed: TimeInterval
    let tty: String?
    let command: String
    let isStopped: Bool
}

enum ProcessScanner {

    /// Enumerates every live Claude Code and Grok Build TUI process and measures each process tree.
    /// Returns `nil` when the process table itself could not be read (hung `ps` after sleep),
    /// so the UI can keep the last good list instead of flashing zero sessions.
    static func scan() -> [LiveProcess]? {
        let all = readProcessTable()
        guard !all.isEmpty else { return nil }

        var byPID: [Int32: RawProcess] = [:]
        var childrenOf: [Int32: [Int32]] = [:]
        for entry in all {
            byPID[entry.pid] = entry
            childrenOf[entry.ppid, default: []].append(entry.pid)
        }

        let grokPIDs = Set(all.filter { isGrokCLI($0.command) }.map(\.pid))
        var roots: [(RawProcess, SessionKind)] = all.filter { isClaudeCLI($0.command) }.map { ($0, .claude) }

        for entry in all where grokPIDs.contains(entry.pid) {
            // Subagents are themselves `grok` processes parented by the TUI; fold them into the
            // parent's tree rather than listing them as independent sessions.
            if hasAncestor(entry.ppid, in: grokPIDs, table: byPID) { continue }
            roots.append((entry, .grok))
        }

        let grokActive = SessionIndex.grokActiveSessionIDs()

        var results: [LiveProcess] = []
        for (root, kind) in roots {
            let tree = descendants(of: root.pid, in: childrenOf)
            let treeRSS = ([root.pid] + tree).reduce(0) { $0 + (byPID[$1]?.rss ?? 0) }
            let resume = parseResumeArgument(root.command)
                ?? (kind == .grok ? grokActive[root.pid] : nil)

            results.append(
                LiveProcess(
                    pid: root.pid,
                    ppid: root.ppid,
                    tty: root.tty,
                    selfRSS: root.rss,
                    treeRSS: treeRSS,
                    elapsed: root.elapsed,
                    command: root.command,
                    resumeArgument: resume,
                    cwd: nil,
                    descendants: tree,
                    kind: kind,
                    isStopped: root.isStopped,
                    host: classifyHost(root: root, table: byPID)
                )
            )
        }

        results = attachWorkingDirectories(results)
        return results.sorted { $0.treeRSS > $1.treeRSS }
    }

    // MARK: - Process table

    private static func readProcessTable() -> [RawProcess] {
        // Command must come last: it is the only field allowed to contain spaces.
        let output = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,rss=,etime=,state=,tty=,command="], timeout: 6)
        return output.split(separator: "\n").compactMap { parseRow(String($0)) }
    }

    private static func parseRow(_ line: String) -> RawProcess? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 7,
              let pid = Int32(fields[0]),
              let ppid = Int32(fields[1]),
              let rssKB = Int(fields[2])
        else { return nil }

        let elapsed = parseElapsed(String(fields[3]))
        let isStopped = fields[4].first == "T"
        let ttyField = String(fields[5])
        let tty = ttyField.hasPrefix("tty") ? ttyField : nil

        // Rebuild the command by finding where the sixth field starts in the original line.
        var remainder = line
        for _ in 0..<6 {
            remainder = remainder.drop(while: { $0 == " " }).drop(while: { $0 != " " }).description
        }
        let command = remainder.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }

        return RawProcess(
            pid: pid,
            ppid: ppid,
            rss: rssKB * 1024,
            elapsed: elapsed,
            tty: tty,
            command: command,
            isStopped: isStopped
        )
    }

    /// Parses ps elapsed time: `[[dd-]hh:]mm:ss`.
    private static func parseElapsed(_ text: String) -> TimeInterval {
        var days = 0.0
        var rest = text
        if let dash = text.firstIndex(of: "-") {
            days = Double(text[text.startIndex..<dash]) ?? 0
            rest = String(text[text.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        var seconds = 0.0
        for part in parts { seconds = seconds * 60 + part }
        return days * 86_400 + seconds
    }

    private static func descendants(of pid: Int32, in childrenOf: [Int32: [Int32]]) -> [Int32] {
        var found: [Int32] = []
        var queue = childrenOf[pid] ?? []
        while let next = queue.popLast() {
            found.append(next)
            queue.append(contentsOf: childrenOf[next] ?? [])
        }
        return found
    }

    // MARK: - Identification

    /// Matches the interactive `claude` CLI while excluding the VS Code extension's headless binary
    /// and unrelated Claude helper processes.
    private static func isClaudeCLI(_ command: String) -> Bool {
        let executable = command.split(separator: " ").first.map(String.init) ?? command
        let name = (executable as NSString).lastPathComponent
        guard name == "claude" else { return false }

        // The IDE extension drives a headless copy over stdio; it has no terminal window to manage.
        if command.contains("--output-format stream-json") { return false }
        if command.contains("--input-format stream-json") { return false }
        return true
    }

    /// Matches the interactive Grok Build TUI, excluding headless/ACP invocations and subcommands
    /// like `grok sessions` or `grok doctor`.
    private static func isGrokCLI(_ command: String) -> Bool {
        let tokens = command.split(separator: " ").map(String.init)
        guard let executable = tokens.first else { return false }
        let name = (executable as NSString).lastPathComponent
        guard name == "grok" || name.hasPrefix("grok-macos") else { return false }

        if tokens.contains("-p") || tokens.contains("--prompt") { return false }
        if tokens.contains("--output-format") || tokens.contains("--input-format") { return false }

        if let subcommand = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }),
           grokSubcommands.contains(subcommand) {
            return false
        }
        return true
    }

    private static let grokSubcommands: Set<String> = [
        "agent", "completions", "dashboard", "doctor", "du", "disk-usage",
        "export", "help", "inspect", "leader", "login", "logout", "mcp",
        "memory", "models", "plugin", "sessions", "setup", "trace", "update",
        "version", "v", "worktree", "wrap"
    ]

    private static func hasAncestor(_ start: Int32, in pids: Set<Int32>, table: [Int32: RawProcess]) -> Bool {
        var current = start
        var hops = 0
        while hops < 8, current > 1 {
            if pids.contains(current) { return true }
            guard let parent = table[current] else { return false }
            current = parent.ppid
            hops += 1
        }
        return false
    }

    private static func parseResumeArgument(_ command: String) -> String? {
        let tokens = command.split(separator: " ").map(String.init)
        guard let index = tokens.firstIndex(where: { $0 == "--resume" || $0 == "-r" }) else { return nil }
        let next = index + 1
        guard next < tokens.count else { return nil }   // bare `claude --resume` opens the picker
        let candidate = tokens[next]
        return looksLikeUUID(candidate) ? candidate : nil
    }

    static func looksLikeUUID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }

    /// Walks up the parent chain to find which application owns the terminal.
    private static func classifyHost(root: RawProcess, table: [Int32: RawProcess]) -> TerminalHost {
        var current = root.ppid
        var hops = 0
        while hops < 8, current > 1, let parent = table[current] {
            let command = parent.command
            if command.contains("Terminal.app") { return .terminalApp }
            if command.contains("Visual Studio Code") || command.contains("Code Helper") { return .vscode }
            if command.contains("iTerm") || command.contains("Ghostty") || command.contains("WezTerm") {
                return .terminalApp
            }
            current = parent.ppid
            hops += 1
        }
        return .unknown
    }

    // MARK: - Working directories

    /// Resolves each process's cwd in a single batched lsof call.
    private static func attachWorkingDirectories(_ processes: [LiveProcess]) -> [LiveProcess] {
        guard !processes.isEmpty else { return processes }

        let pidList = processes.map { String($0.pid) }.joined(separator: ",")
        let output = Shell.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pidList, "-Fpn"], timeout: 6)

        var directories: [Int32: String] = [:]
        var currentPID: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                currentPID = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = currentPID {
                directories[pid] = String(line.dropFirst())
            }
        }

        return processes.map { process in
            var copy = process
            copy.cwd = directories[process.pid]
            return copy
        }
    }
}
