import Foundation

/// Headless view of everything the app knows, for verifying scanning and matching.
enum Diagnostics {
    private static func loadSessions() -> (sessions: [ManagedSession], records: [SessionRecord], processes: [LiveProcess], windows: [String: TerminalWindow]) {
        let processes = ProcessScanner.scan() ?? []
        let windows = TerminalBridge.windows()
        let records = SessionIndex.loadAll()
        let sessions = SessionMatcher.merge(
            processes: processes,
            windows: windows,
            records: records,
            remembered: AppMemory.load().remembered
        )
        return (sessions, records, processes, windows)
    }

    static func dump() {
        let loaded = loadSessions()
        let sessions = loaded.sessions
        let records = loaded.records
        let processes = loaded.processes
        let windows = loaded.windows

        let live = sessions.filter(\.isLive)
        let interrupted = sessions.filter(\.isInterrupted)
        let total = live.reduce(0) { $0 + $1.ramBytes }

        let claude = records.filter { $0.kind == .claude }.count
        let grok = records.filter { $0.kind == .grok }.count
        print("processes: \(processes.count)   terminal tabs: \(windows.count)   transcripts: \(records.count) (claude \(claude) / grok \(grok))")
        print("live: \(live.count)   interrupted: \(interrupted.count)   ram: \(Format.compactBytes(total))")
        print(String(repeating: "-", count: 100))

        for session in live {
            guard let process = session.process else { continue }
            let resolved = session.record?.id ?? "UNRESOLVED"
            let source: String
            if process.kind == .grok, process.resumeArgument == session.record?.id {
                source = "active"
            } else if session.window != nil {
                source = "title"
            } else if process.resumeArgument != nil {
                source = "resume/mtime"
            } else {
                source = "mtime"
            }

            let columns = [
                pad(String(process.pid), 6),
                pad(process.kind.displayName, 7),
                pad(process.isStopped ? "paused" : "run", 7),
                pad(process.tty ?? "-", 8),
                pad(process.host.rawValue, 9),
                pad(Format.compactBytes(session.ramBytes), 8),
                pad(source, 13),
                pad(resolved, 38),
                session.title
            ]
            print(columns.joined(separator: " "))
            print("       " + session.displayPath)
        }

        if !interrupted.isEmpty {
            print(String(repeating: "-", count: 100))
            print("interrupted (process gone, still in project group):")
            for session in interrupted {
                print([
                    pad(session.kind.displayName, 7),
                    pad(session.record?.id ?? "-", 38),
                    session.title
                ].joined(separator: " "))
                print("       " + session.displayPath)
            }
        }

        print(String(repeating: "-", count: 100))
        print("archived transcripts: \(sessions.filter { !$0.isLive && !$0.isInterrupted }.count)")
    }

    /// `--sessions <substring>` lists indexed transcripts whose path or title matches.
    static func dumpSessions(filter: String) {
        let records = SessionIndex.loadAll()
        let needle = filter.lowercased()
        for record in records {
            let haystack = (record.kind.displayName + " " + record.cwd + " " + record.title + " " + record.id + " " + record.lastPrompt).lowercased()
            guard needle.isEmpty || haystack.contains(needle) else { continue }
            let status: String
            if record.directoryIsMissing {
                status = "MISSING"
            } else if record.currentDirectory != record.cwd {
                status = "MOVED"
            } else {
                status = "ok"
            }

            print([
                pad(record.kind.displayName, 7),
                pad(record.id, 38),
                pad(Format.compactBytes(record.byteSize), 9),
                pad(status, 8),
                pad(record.currentDirectory.isEmpty ? record.cwd : record.currentDirectory, 48),
                record.title
            ].joined(separator: " "))
        }
    }

    /// `--groups` prints the section structure the menu renders, including the starred section.
    static func dumpGroups() {
        let sessions = loadSessions().sessions
        let starred = Favorites.load().ids
        let tags = TagStore.load()

        let visible = sessions.filter { session in
            session.isLive || session.isInterrupted || (session.record.map { starred.contains($0.id) } ?? false)
        }

        for group in ProjectGroup.build(from: visible, starred: starred, tags: tags) {
            let ram = group.ramBytes > 0 ? "  \(Format.compactBytes(group.ramBytes))" : ""
            print("\(group.isStarredSection ? "★ " : "")\(group.name)  [\(group.liveCount) live / \(group.interruptedCount) interrupted / \(group.sessions.count)]\(ram)")
            for session in group.sessions {
                let mark = starred.contains(session.record?.id ?? "") ? "★" : " "
                let dot: String
                if session.isPaused { dot = "◐" }
                else if session.isLive { dot = "●" }
                else if session.isInterrupted { dot = "◑" }
                else { dot = "○" }
                let tagNames = tags.tags(for: session.record?.id ?? "").map(\.name).joined(separator: ",")
                let tagPad = tagNames.isEmpty ? "" : " [\(tagNames)]"
                print("   \(mark) \(dot) \(pad(session.title + tagPad, 52)) \(session.resumeCommand ?? "")")
            }
        }
    }

    /// `--star <session-id>` toggles a star from the command line, for testing persistence.
    static func toggleStar(id: String) {
        var favorites = Favorites.load()
        favorites.toggle(id)
        print(favorites.contains(id) ? "starred \(id)" : "unstarred \(id)")
        print("now starred: \(Favorites.load().ids.sorted())")
    }

    /// `--pause <pid>` / `--unpause <pid>` exercise the freeze path the Pause button uses.
    static func pause(pid: pid_t, stop: Bool) {
        let table = ProcessScanner.scan() ?? []
        let descendants = table.first(where: { $0.pid == pid })?.descendants ?? childrenFallback(of: pid)
        print("\(stop ? "pausing" : "unpausing") \(pid) plus \(descendants.count) descendants: \(descendants)")
        if stop {
            ProcessKiller.stopTree(root: pid, descendants: descendants)
        } else {
            ProcessKiller.continueTree(root: pid, descendants: descendants)
        }
        let output = Shell.run("/bin/ps", ["-o", "state=", "-p", String(pid)]).trimmingCharacters(in: .whitespacesAndNewlines)
        print("state now: \(output.isEmpty ? "gone" : output)")
    }

    /// `--free <pid>` exercises the same termination path the Free button uses.
    static func free(pid: pid_t) {
        let table = ProcessScanner.scan() ?? []
        let descendants = table.first(where: { $0.pid == pid })?.descendants ?? childrenFallback(of: pid)
        print("terminating \(pid) plus \(descendants.count) descendants: \(descendants)")
        ProcessKiller.terminateTree(root: pid, descendants: descendants)
        let survivors = ([pid] + descendants).filter { ProcessKiller.isAlive($0) }
        print(survivors.isEmpty ? "all terminated" : "still alive: \(survivors)")
    }

    /// Used when the target is not a tracked CLI process, so the scanner does not know it.
    private static func childrenFallback(of pid: pid_t) -> [pid_t] {
        let output = Shell.run("/bin/ps", ["-axo", "pid=,ppid="])
        var childrenOf: [pid_t: [pid_t]] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let child = Int32(parts[0]), let parent = Int32(parts[1]) else { continue }
            childrenOf[parent, default: []].append(child)
        }
        var found: [pid_t] = []
        var queue = childrenOf[pid] ?? []
        while let next = queue.popLast() {
            found.append(next)
            queue.append(contentsOf: childrenOf[next] ?? [])
        }
        return found
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
    }
}
