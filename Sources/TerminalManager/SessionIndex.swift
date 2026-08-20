import Foundation

enum SessionKind: String, Codable, Hashable {
    case claude
    case grok

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .grok: return "Grok"
        }
    }

    /// Executable used to resume this session from a shell.
    var cliName: String {
        switch self {
        case .claude: return "claude"
        case .grok: return "grok"
        }
    }
}

/// A Claude Code or Grok Build session as persisted on disk.
struct SessionRecord: Identifiable, Hashable, Codable {
    var id: String          // the session UUID, which is also the `--resume` argument
    var filePath: String
    var cwd: String
    var title: String
    var lastPrompt: String
    var modified: Date
    var byteSize: Int
    /// True when `cwd` was inferred from the folder name rather than read from the transcript.
    var cwdWasGuessed: Bool = false
    /// Canonical project key: Claude Code's folder naming applied to the launch directory.
    /// Shared by both CLIs so sessions in the same repo group together.
    var projectFolder: String = ""
    /// Where this project's directory is right now, which differs from `cwd` when the folder has
    /// been moved or renamed since the session ran. Empty when the directory no longer exists.
    var currentDirectory: String = ""
    var kind: SessionKind = .claude

    /// True when the recorded directory is gone and no replacement could be found.
    var directoryIsMissing: Bool { currentDirectory.isEmpty }

    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    /// Older caches predate `kind`; treat a missing value as Claude.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        filePath = try container.decode(String.self, forKey: .filePath)
        cwd = try container.decode(String.self, forKey: .cwd)
        title = try container.decode(String.self, forKey: .title)
        lastPrompt = try container.decode(String.self, forKey: .lastPrompt)
        modified = try container.decode(Date.self, forKey: .modified)
        byteSize = try container.decode(Int.self, forKey: .byteSize)
        cwdWasGuessed = try container.decodeIfPresent(Bool.self, forKey: .cwdWasGuessed) ?? false
        projectFolder = try container.decodeIfPresent(String.self, forKey: .projectFolder) ?? ""
        currentDirectory = try container.decodeIfPresent(String.self, forKey: .currentDirectory) ?? ""
        kind = try container.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .claude
    }

    init(
        id: String,
        filePath: String,
        cwd: String,
        title: String,
        lastPrompt: String,
        modified: Date,
        byteSize: Int,
        cwdWasGuessed: Bool = false,
        projectFolder: String = "",
        currentDirectory: String = "",
        kind: SessionKind = .claude
    ) {
        self.id = id
        self.filePath = filePath
        self.cwd = cwd
        self.title = title
        self.lastPrompt = lastPrompt
        self.modified = modified
        self.byteSize = byteSize
        self.cwdWasGuessed = cwdWasGuessed
        self.projectFolder = projectFolder
        self.currentDirectory = currentDirectory
        self.kind = kind
    }
}

/// Reads and caches session metadata without loading whole transcripts into memory.
enum SessionIndex {

    private static let projectsRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// Grok Build's home directory. `GROK_HOME` overrides `~/.grok` the same way the CLI does.
    static var grokHome: URL {
        if let override = ProcessInfo.processInfo.environment["GROK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }

    private static var cacheURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("session-index.json")
    }

    private struct CacheEntry: Codable {
        var record: SessionRecord
        var mtime: Date
        var size: Int
    }

    /// Loads every session on disk, re-parsing only files that changed since the last scan.
    static func loadAll() -> [SessionRecord] {
        var cache = readCache()
        var records: [SessionRecord] = []

        func ingest(file: URL, parse: (URL, Date, Int) -> SessionRecord?) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let mtime = (attributes?[.modificationDate] as? Date) ?? .distantPast
            let size = (attributes?[.size] as? Int) ?? 0

            if let cached = cache[file.path], cached.mtime == mtime, cached.size == size {
                records.append(cached.record)
                return
            }

            guard let parsed = parse(file, mtime, size) else { return }
            cache[file.path] = CacheEntry(record: parsed, mtime: mtime, size: size)
            records.append(parsed)
        }

        for file in transcriptFiles() {
            ingest(file: file, parse: parseClaude(file:mtime:size:))
        }
        for file in grokSummaryFiles() {
            ingest(file: file, parse: parseGrok(file:mtime:size:))
        }

        records = fillMissingDirectories(records)
        records = resolveCurrentDirectories(records)

        // Keep the cache in step with the repaired directories, and drop vanished transcripts.
        var repaired: [String: CacheEntry] = [:]
        for record in records {
            guard let entry = cache[record.filePath] else { continue }
            repaired[record.filePath] = CacheEntry(record: record, mtime: entry.mtime, size: entry.size)
        }
        writeCache(repaired)

        return records.sorted { $0.modified > $1.modified }
    }

    /// Locates each project's directory as it exists today. The recorded `cwd` is trusted first
    /// and costs a single stat; the filesystem search only runs for projects that have moved, and
    /// its result is shared by every session in the same project folder.
    private static func resolveCurrentDirectories(_ records: [SessionRecord]) -> [SessionRecord] {
        var resolvedByFolder: [String: String] = [:]

        return records.map { record in
            var copy = record

            if DirectoryResolver.exists(record.cwd) {
                copy.currentDirectory = record.cwd
                return copy
            }

            if let cached = resolvedByFolder[record.projectFolder] {
                copy.currentDirectory = cached
                return copy
            }

            let resolved = DirectoryResolver.resolve(encodedFolder: record.projectFolder) ?? ""
            resolvedByFolder[record.projectFolder] = resolved
            copy.currentDirectory = resolved
            return copy
        }
    }

    /// A transcript whose own `cwd` field could not be read borrows the directory from its
    /// siblings, which all live under the same project folder. This is far more reliable than
    /// trying to reverse the lossy `/a/b` -> `-a-b` folder encoding.
    private static func fillMissingDirectories(_ records: [SessionRecord]) -> [SessionRecord] {
        var canonical: [String: [String: Int]] = [:]
        for record in records where !record.cwd.isEmpty && !record.cwdWasGuessed {
            let folder = (record.filePath as NSString).deletingLastPathComponent
            canonical[folder, default: [:]][record.cwd, default: 0] += 1
        }

        return records.map { record in
            guard record.cwd.isEmpty || record.cwdWasGuessed else { return record }
            let folder = (record.filePath as NSString).deletingLastPathComponent
            guard let best = canonical[folder]?.max(by: { $0.value < $1.value })?.key else { return record }
            var copy = record
            copy.cwd = best
            copy.cwdWasGuessed = false
            return copy
        }
    }

    private static func transcriptFiles() -> [URL] {
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil
        ) else { return [] }

        var files: [URL] = []
        for dir in projectDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            files.append(contentsOf: entries.filter { $0.pathExtension == "jsonl" })
        }
        return files
    }

    /// Each Grok session is `~/.grok/sessions/<encoded-cwd>/<session-id>/summary.json`.
    /// Group folders that exceed 255 bytes store the real path in a sibling `.cwd` file.
    private static func grokSummaryFiles() -> [URL] {
        let root = grokHome.appendingPathComponent("sessions", isDirectory: true)
        guard let groups = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var files: [URL] = []
        for group in groups {
            guard isDirectory(group) else { continue }
            let direct = group.appendingPathComponent("summary.json")
            if FileManager.default.fileExists(atPath: direct.path) {
                files.append(direct)
                continue
            }
            guard let sessions = try? FileManager.default.contentsOfDirectory(
                at: group, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for session in sessions {
                let summary = session.appendingPathComponent("summary.json")
                if FileManager.default.fileExists(atPath: summary.path) {
                    files.append(summary)
                }
            }
        }
        return files
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// pid → session id for live Grok TUI processes, from `~/.grok/active_sessions.json`.
    static func grokActiveSessionIDs() -> [Int32: String] {
        let url = grokHome.appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }

        var map: [Int32: String] = [:]
        for row in rows {
            guard let sid = row["session_id"] as? String, !sid.isEmpty else { continue }
            let pid: Int32?
            if let value = row["pid"] as? Int {
                pid = Int32(value)
            } else if let value = row["pid"] as? NSNumber {
                pid = value.int32Value
            } else {
                pid = nil
            }
            if let pid { map[pid] = sid }
        }
        return map
    }

    // MARK: - Parsing

    /// Transcripts can contain single lines over a megabyte, so a fixed tail can land mid-line
    /// and yield nothing. Widen the window until the metadata records show up.
    private static let tailWindows = [256 * 1024, 2 * 1024 * 1024, 12 * 1024 * 1024]
    private static let headWindow = 512 * 1024

    private static func parseClaude(file: URL, mtime: Date, size: Int) -> SessionRecord? {
        let sessionID = file.deletingPathExtension().lastPathComponent
        guard looksLikeSessionID(sessionID) else { return nil }

        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var title = ""
        var lastPrompt = ""
        var cwd = ""

        // The head carries the launch directory. Later entries report whatever directory the
        // agent had moved into, so only the first occurrence identifies the session's project.
        var openingPrompt = ""
        for object in jsonObjects(in: readHead(handle)) {
            if cwd.isEmpty, let value = object["cwd"] as? String { cwd = value }
            if openingPrompt.isEmpty, object["type"] as? String == "user",
               let text = firstUserText(object) {
                openingPrompt = String(text.prefix(90))
            }
            if !cwd.isEmpty && !openingPrompt.isEmpty { break }
        }

        // The tail carries the most recent ai-title / last-prompt records.
        for window in tailWindows {
            for object in jsonObjects(in: readTail(handle, size: size, window: window)) {
                switch object["type"] as? String {
                case "ai-title":
                    if let value = object["aiTitle"] as? String, !value.isEmpty { title = value }
                case "last-prompt":
                    if let value = object["lastPrompt"] as? String, !value.isEmpty { lastPrompt = value }
                default:
                    break
                }
            }
            if !title.isEmpty { break }
            if window >= size { break }
        }

        if title.isEmpty { title = openingPrompt }

        var guessed = false
        if cwd.isEmpty {
            cwd = decodeProjectDirectory(file.deletingLastPathComponent().lastPathComponent)
            guessed = true
        }
        if title.isEmpty { title = "(untitled session)" }

        return SessionRecord(
            id: sessionID,
            filePath: file.path,
            cwd: cwd,
            title: title,
            lastPrompt: lastPrompt,
            modified: mtime,
            byteSize: size,
            cwdWasGuessed: guessed,
            projectFolder: file.deletingLastPathComponent().lastPathComponent,
            kind: .claude
        )
    }

    private static func parseGrok(file: URL, mtime: Date, size: Int) -> SessionRecord? {
        let sessionDir = file.deletingLastPathComponent()
        let sessionID = sessionDir.lastPathComponent
        guard looksLikeSessionID(sessionID) else { return nil }

        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let info = object["info"] as? [String: Any] ?? [:]
        let id = (info["id"] as? String).flatMap { looksLikeSessionID($0) ? $0 : nil } ?? sessionID

        var cwd = (info["cwd"] as? String) ?? ""
        var guessed = false
        if cwd.isEmpty {
            cwd = decodeGrokDirectory(sessionDir.deletingLastPathComponent())
            guessed = !cwd.isEmpty
        }

        let title = firstNonEmpty([
            object["generated_title"] as? String,
            object["session_summary"] as? String
        ]) ?? ""

        let updates = sessionDir.appendingPathComponent("updates.jsonl")
        let updatesSize = (try? FileManager.default.attributesOfItem(atPath: updates.path)[.size] as? Int) ?? 0
        let byteSize = updatesSize > 0 ? updatesSize : size

        var lastPrompt = firstNonEmpty([object["last_turn_summary"] as? String]) ?? ""
        if lastPrompt.isEmpty {
            lastPrompt = grokLastPrompt(updates: updates, size: updatesSize)
        }
        if lastPrompt.isEmpty {
            lastPrompt = firstNonEmpty([object["last_recap"] as? String]).map { String($0.prefix(90)) } ?? ""
        }

        let modified = parseISO8601(object["last_active_at"] as? String)
            ?? parseISO8601(object["updated_at"] as? String)
            ?? mtime

        let resolvedTitle = title.isEmpty
            ? (lastPrompt.isEmpty ? "(untitled session)" : lastPrompt)
            : title

        return SessionRecord(
            id: id,
            filePath: file.path,
            cwd: cwd,
            title: resolvedTitle,
            lastPrompt: lastPrompt == resolvedTitle ? "" : lastPrompt,
            modified: modified,
            byteSize: byteSize,
            cwdWasGuessed: guessed,
            projectFolder: encodeProjectFolder(cwd),
            kind: .grok
        )
    }

    /// Tail-scan `updates.jsonl` for the most recent user prompt. Chunks are concatenated when
    /// they arrive back-to-back so a split message still reads as one line.
    private static func grokLastPrompt(updates: URL, size: Int) -> String {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: updates) else { return "" }
        defer { try? handle.close() }

        for window in tailWindows {
            var last = ""
            var assembling = ""
            for object in jsonObjects(in: readTail(handle, size: size, window: window)) {
                guard let params = object["params"] as? [String: Any],
                      let update = params["update"] as? [String: Any],
                      update["sessionUpdate"] as? String == "user_message_chunk",
                      let content = update["content"] as? [String: Any],
                      let text = content["text"] as? String
                else {
                    if !assembling.isEmpty {
                        last = assembling
                        assembling = ""
                    }
                    continue
                }
                assembling += text
            }
            if !assembling.isEmpty { last = assembling }
            if let cleaned = sanitize(last) { return String(cleaned.prefix(90)) }
            if window >= size { break }
        }
        return ""
    }

    private static func decodeGrokDirectory(_ group: URL) -> String {
        let cwdFile = group.appendingPathComponent(".cwd")
        if let data = try? String(contentsOf: cwdFile, encoding: .utf8) {
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return group.lastPathComponent.removingPercentEncoding ?? ""
    }

    private static func parseISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        // `summary.json` writes microseconds; ISO8601DateFormatter wants milliseconds.
        if let dot = string.lastIndex(of: "."), string.hasSuffix("Z") {
            let fraction = string[string.index(after: dot)...].filter(\.isNumber)
            let trimmed = String(string[string.startIndex...dot]) + fraction.prefix(3) + "Z"
            if let date = fractional.date(from: String(trimmed)) { return date }
        }
        return nil
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private static func readTail(_ handle: FileHandle, size: Int, window: Int) -> Data {
        let offset = max(0, size - window)
        try? handle.seek(toOffset: UInt64(offset))
        let data = (try? handle.readToEnd()) ?? Data()
        guard offset > 0 else { return data }
        // Discard the leading partial line produced by seeking mid-file.
        if let newline = data.firstIndex(of: 0x0A) {
            return data[data.index(after: newline)...]
        }
        return Data()
    }

    private static func readHead(_ handle: FileHandle) -> Data {
        try? handle.seek(toOffset: 0)
        return (try? handle.read(upToCount: headWindow)) ?? Data()
    }

    private static func jsonObjects(in data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        }.compactMap { $0 }
    }

    /// Extracts plain text from a user message, which may be a string or a content-block array.
    private static func firstUserText(_ object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String {
            return sanitize(text)
        }
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where block["type"] as? String == "text" {
                if let text = block["text"] as? String { return sanitize(text) }
            }
        }
        return nil
    }

    /// Strips harness noise so the fallback title reflects what the user actually typed.
    private static func sanitize(_ text: String) -> String? {
        var value = text
        while let start = value.range(of: "<"), let end = value.range(of: ">", range: start.upperBound..<value.endIndex) {
            value.removeSubrange(start.lowerBound..<end.upperBound)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value.replacingOccurrences(of: "\n", with: " ")
    }

    private static func looksLikeSessionID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }

    /// Best-effort reversal of the folder encoding, used only for display when a transcript
    /// carries no cwd field of its own.
    private static func decodeProjectDirectory(_ name: String) -> String {
        "/" + name.dropFirst().replacingOccurrences(of: "-", with: "/")
    }

    /// Reproduces Claude Code's folder naming: every character outside [A-Za-z0-9] becomes "-".
    /// Also used as the shared project key for Grok sessions so both CLIs group together.
    static func encodeProjectFolder(_ path: String) -> String {
        String(path.map { character in
            character.isLetter && character.isASCII || character.isNumber && character.isASCII
                ? character
                : "-"
        })
    }

    // MARK: - Cache

    private static func readCache() -> [String: CacheEntry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func writeCache(_ cache: [String: CacheEntry]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
