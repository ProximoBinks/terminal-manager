import Foundation
import Darwin

/// Thin wrapper around running short-lived command line tools.
enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 8) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }

        // Read on a helper thread so a hung `ps`/`lsof` after sleep cannot block forever.
        // Killing the child closes the pipe and unblocks the read.
        var data = Data()
        let lock = NSLock()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let chunk = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            data = chunk
            lock.unlock()
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.15)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = finished.wait(timeout: .now() + 1)
        }

        lock.lock()
        let output = data
        lock.unlock()
        return String(data: output, encoding: .utf8) ?? ""
    }

    /// Runs an AppleScript snippet through osascript.
    static func osascript(_ source: String) -> String {
        run("/usr/bin/osascript", ["-e", source], timeout: 5)
    }
}
