import SwiftUI

@main
struct TerminalManagerApp: App {
    @StateObject private var state = AppState()

    init() {
        // `TerminalManager --dump` prints the resolved session table and exits, which makes the
        // scanning and matching logic testable without the menu bar UI.
        if CommandLine.arguments.contains("--dump") {
            Diagnostics.dump()
            exit(0)
        }
        if CommandLine.arguments.contains("--groups") {
            Diagnostics.dumpGroups()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--star"),
           CommandLine.arguments.count > index + 1 {
            Diagnostics.toggleStar(id: CommandLine.arguments[index + 1])
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--pause"),
           CommandLine.arguments.count > index + 1,
           let pid = Int32(CommandLine.arguments[index + 1]) {
            Diagnostics.pause(pid: pid, stop: true)
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--unpause"),
           CommandLine.arguments.count > index + 1,
           let pid = Int32(CommandLine.arguments[index + 1]) {
            Diagnostics.pause(pid: pid, stop: false)
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--free"),
           CommandLine.arguments.count > index + 1,
           let pid = Int32(CommandLine.arguments[index + 1]) {
            Diagnostics.free(pid: pid)
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--sessions") {
            let filter = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : ""
            Diagnostics.dumpSessions(filter: filter)
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(state)
                .task { state.start() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal.fill")
                Text(state.statusTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
