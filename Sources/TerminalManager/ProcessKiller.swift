import Foundation

enum ProcessKiller {

    /// Sends SIGTERM to the root so the CLI can flush its transcript and shut down child
    /// processes (MCP servers, subagents), then cleans up any descendant that outlives it.
    static func terminateTree(root: pid_t, descendants: [pid_t]) {
        // A SIGSTOP'd process will not run shutdown handlers until it is continued.
        continueTree(root: root, descendants: descendants)
        kill(root, SIGTERM)

        // Give the CLI a moment to exit on its own before touching its children.
        Thread.sleep(forTimeInterval: 2.5)

        for pid in descendants where isAlive(pid) {
            kill(pid, SIGTERM)
        }

        Thread.sleep(forTimeInterval: 1.5)

        for pid in ([root] + descendants) where isAlive(pid) {
            kill(pid, SIGKILL)
        }
    }

    /// Freezes the CLI and every child (MCP servers, subagents, in-flight shell commands).
    /// The processes keep their memory and terminal; they just stop being scheduled.
    static func stopTree(root: pid_t, descendants: [pid_t]) {
        for pid in descendants { kill(pid, SIGSTOP) }
        kill(root, SIGSTOP)
    }

    /// Wakes a tree previously frozen with `stopTree`.
    static func continueTree(root: pid_t, descendants: [pid_t]) {
        kill(root, SIGCONT)
        for pid in descendants { kill(pid, SIGCONT) }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
