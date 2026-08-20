import Foundation

/// Finds where a project's directory actually lives today.
///
/// A transcript records the directory a session started in, but folders get moved and renamed.
/// The folder name under ~/.claude/projects is a lossy encoding of a path — every character
/// outside [A-Za-z0-9] became "-" — so it cannot simply be reversed. Instead this walks the real
/// filesystem, re-encoding candidate directory names to find the branch that matches.
enum DirectoryResolver {

    static func exists(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }

    /// Resolves "-Users-coding-Downloads-Folders-texts" to "/Users/coding/Downloads/Folders/texts"
    /// by matching each segment against directories that really exist. Returns nil when the
    /// project directory is gone entirely.
    static func resolve(encodedFolder: String) -> String? {
        var remaining = encodedFolder
        while remaining.hasPrefix("-") { remaining.removeFirst() }
        guard !remaining.isEmpty else { return nil }

        var budget = 4_000
        return walk(base: "/", remaining: remaining, budget: &budget)
    }

    private static func walk(base: String, remaining: String, budget: inout Int) -> String? {
        if remaining.isEmpty { return base }
        guard budget > 0 else { return nil }

        for entry in subdirectories(of: base) {
            budget -= 1
            guard budget > 0 else { return nil }

            let encoded = SessionIndex.encodeProjectFolder(entry)
            guard !encoded.isEmpty else { continue }

            let child = (base as NSString).appendingPathComponent(entry)

            if remaining == encoded { return child }

            if remaining.count > encoded.count,
               remaining.hasPrefix(encoded + "-"),
               let hit = walk(
                   base: child,
                   remaining: String(remaining.dropFirst(encoded.count + 1)),
                   budget: &budget
               ) {
                return hit
            }
        }
        return nil
    }

    private static func subdirectories(of path: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return entries.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            let child = (path as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: child, isDirectory: &isDirectory) else { return false }
            return isDirectory.boolValue
        }
    }
}
