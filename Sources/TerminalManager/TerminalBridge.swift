import AppKit
import Foundation

/// One Terminal.app tab, keyed by the tty its shell is attached to.
struct TerminalWindow: Hashable {
    let windowID: Int
    let tabIndex: Int
    let tty: String        // normalised to "ttys004"
    let title: String
}

/// Drives Terminal.app over AppleScript to locate, focus and close tabs.
enum TerminalBridge {

    /// Fetches all tabs in three bulk Apple Events rather than two per tab. Asking each tab
    /// individually costs about a second on a busy desktop; this stays around 0.1s.
    private static let listScript = """
    tell application "Terminal"
        set windowIDs to id of every window
        set ttyLists to tty of every tab of every window
        set titleLists to custom title of every tab of every window
    end tell
    set output to ""
    repeat with i from 1 to count of windowIDs
        set theTTYs to item i of ttyLists
        set theTitles to item i of titleLists
        repeat with j from 1 to count of theTTYs
            set aTitle to ""
            try
                set aTitle to item j of theTitles as text
            end try
            set output to output & (item i of windowIDs) & tab & j & tab & (item j of theTTYs) & tab & aTitle & linefeed
        end repeat
    end repeat
    return output
    """

    /// Returns every open Terminal.app tab. Empty when Terminal is not running or automation
    /// permission has not been granted yet.
    static func windows() -> [String: TerminalWindow] {
        guard isTerminalRunning() else { return [:] }

        var result: [String: TerminalWindow] = [:]
        for line in Shell.osascript(listScript).split(separator: "\n") {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3,
                  let windowID = Int(fields[0]),
                  let tabIndex = Int(fields[1])
            else { continue }

            let tty = normalise(fields[2])
            guard !tty.isEmpty else { continue }

            let title = fields.count > 3 ? fields[3...].joined(separator: "\t") : ""
            result[tty] = TerminalWindow(
                windowID: windowID,
                tabIndex: tabIndex,
                tty: tty,
                title: cleanTitle(title)
            )
        }
        return result
    }

    /// Brings the tab attached to `tty` to the front.
    static func focus(tty: String) {
        guard let window = windows()[normalise(tty)] else { return }
        _ = Shell.osascript("""
        tell application "Terminal"
            set index of (first window whose id is \(window.windowID)) to 1
            activate
        end tell
        """)
    }

    /// Closes the tab attached to `tty` without prompting to end running processes.
    static func close(tty: String) {
        guard let window = windows()[normalise(tty)] else { return }
        _ = Shell.osascript("""
        tell application "Terminal"
            close (first window whose id is \(window.windowID)) saving no
        end tell
        """)
    }

    /// Opens a new Terminal window running `command` (typically `cd … && claude|grok --resume …`).
    static func resume(command: String) {
        _ = Shell.osascript("""
        tell application "Terminal"
            activate
            do script "\(appleScriptEscape(command))"
        end tell
        """)
    }

    // MARK: - Helpers

    private static func isTerminalRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty
    }

    /// "/dev/ttys004" and "ttys004" both normalise to "ttys004".
    private static func normalise(_ tty: String) -> String {
        let trimmed = tty.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/dev/") ? String(trimmed.dropFirst(5)) : trimmed
    }

    /// Terminal tab titles are prefixed with Claude Code's status glyph.
    private static func cleanTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "✳✶✻✽*· "))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func appleScriptEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
