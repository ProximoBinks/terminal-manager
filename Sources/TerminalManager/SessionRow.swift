import SwiftUI

struct SessionRow: View {
    let session: ManagedSession
    var showsProjectName: Bool = false

    @EnvironmentObject private var state: AppState
    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusDot

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 12, weight: (session.isLive || session.isInterrupted) ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle((session.isLive || session.isInterrupted) ? .primary : .secondary)

                if !rowTags.isEmpty { tagPills }

                // Swap metadata for actions in a fixed-height slot so hover never
                // grows the row and shoves everything below it.
                ZStack(alignment: .leading) {
                    Text(metadataLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(isHovering && hasActions ? 0 : 1)

                    actions
                        .opacity(isHovering && hasActions ? 1 : 0)
                        .allowsHitTesting(isHovering && hasActions)
                }
                .frame(height: 18, alignment: .leading)
            }

            Spacer(minLength: 4)

            if session.isLive {
                Text(Format.compactBytes(session.ramBytes))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(ramColor)
                    .padding(.top, 1)
            }

            tagButton
            starButton
            copyButton
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .background(isHovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var statusDot: some View {
        Group {
            if session.isInterrupted {
                Circle().stroke(Color.orange, lineWidth: 1.5)
            } else {
                Circle().fill(dotColor)
            }
        }
        .frame(width: 6, height: 6)
        .padding(.top, 5)
    }

    private var dotColor: Color {
        if session.isPaused { return .orange }
        if session.isLive { return .green }
        return Color.secondary.opacity(0.3)
    }

    private var rowTags: [Tag] { state.tags(for: session) }

    private var tagPills: some View {
        HStack(spacing: 4) {
            ForEach(rowTags) { tag in
                Button {
                    state.toggleTagFilter(tag)
                } label: {
                    TagPill(tag: tag, selected: state.tagFilter == tag.id)
                }
                .buttonStyle(.plain)
                .help("Filter by “\(tag.name)”")
            }
        }
    }

    @ViewBuilder
    private var tagButton: some View {
        if state.canStar(session) {
            Menu {
                tagMenuItems
            } label: {
                Image(systemName: rowTags.isEmpty ? "tag" : "tag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(rowTags.isEmpty ? Color.secondary : rowTags[0].color.color)
                    .opacity(rowTags.isEmpty && !isHovering ? 0 : 1)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Tag this session")
        }
    }

    @ViewBuilder
    private var tagMenuItems: some View {
        if !state.allTags.isEmpty {
            ForEach(state.allTags) { tag in
                Button {
                    state.toggleTag(tag, on: session)
                } label: {
                    if state.hasTag(tag, on: session) {
                        Label(tag.name, systemImage: "checkmark")
                    } else {
                        Text(tag.name)
                    }
                }
            }
            Divider()
        }
        Button("New Tag…") { state.beginNewTag(for: session) }
    }

    /// Filled and coloured once starred; otherwise it only appears on hover so unstarred rows
    /// stay visually quiet.
    @ViewBuilder
    private var starButton: some View {
        if state.canStar(session) {
            let starred = state.isStarred(session)
            Button {
                state.toggleStar(session)
            } label: {
                Image(systemName: starred ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(starred ? Color.yellow : Color.secondary)
                    .opacity(starred || isHovering ? 1 : 0)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(starred ? "Remove star" : "Star this session")
        }
    }

    /// The copy button is always visible: reclaiming the resume command is the whole point.
    @ViewBuilder
    private var copyButton: some View {
        if session.resumeCommand != nil {
            Button {
                state.copyResumeCommand(session)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy “\(session.resumeCommand ?? "")”")
        }
    }

    private var metadataLine: String {
        var parts: [String] = []

        // Rows in the Starred section come from every project, so name it inline.
        if showsProjectName, !session.displayPath.isEmpty {
            parts.append((session.directory as NSString).lastPathComponent)
        }

        parts.append(session.kind.displayName)

        if let process = session.process {
            parts.append(process.host.rawValue)
            if let tty = process.tty { parts.append(tty) }
            if session.isPaused { parts.append("paused") }
            parts.append("up \(Format.duration(process.elapsed))")
        } else if session.isInterrupted {
            parts.append("interrupted")
            if session.interruption?.wasPaused == true { parts.append("was paused") }
            parts.append(Format.relative(session.lastActive))
            if session.directoryWasRelocated { parts.append("moved") }
            if !session.directoryExists { parts.append("folder missing") }
        } else {
            parts.append(Format.relative(session.lastActive))
            if session.directoryWasRelocated { parts.append("moved") }
            if !session.directoryExists { parts.append("folder missing") }
            if let size = session.record?.byteSize, size > 0 {
                parts.append(Format.compactBytes(size))
            }
        }

        if let id = session.record?.id { parts.append(String(id.prefix(8))) }

        return parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    private var ramColor: Color {
        let megabytes = Double(session.ramBytes) / 1_048_576
        if megabytes >= 250 { return .red }
        if megabytes >= 120 { return .orange }
        return .secondary
    }

    private var hasActions: Bool {
        session.isLive || session.record != nil
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if session.isLive {
                if session.isPaused {
                    actionButton("Unpause", help: "Continue this session in its existing window") {
                        state.unpause(session)
                    }
                } else {
                    actionButton("Pause", help: "Freeze this session and its children; it stays in this group") {
                        state.pause(session)
                    }
                }
                actionButton("Free", help: "Quit this session and its child processes, keeping the window open") {
                    state.free(session)
                }
                if session.process?.host == .terminalApp {
                    actionButton("Focus", help: "Bring this Terminal window to the front") {
                        state.focus(session)
                    }
                }
            } else if session.isInterrupted {
                actionButton("Resume", help: "Open a new terminal and continue this session from disk") {
                    state.reopen(session)
                }
                .disabled(!session.directoryExists)
                actionButton("Dismiss", help: "Remove this row from the live group without deleting the transcript") {
                    state.free(session)
                }
            } else if session.record != nil {
                actionButton("Resume", help: "Open a new Terminal window running this session") {
                    state.reopen(session)
                }
                .disabled(!session.directoryExists)
            }
        }
        .font(.system(size: 11, weight: .medium))
    }

    private func actionButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if session.isLive {
            if session.isPaused {
                Button("Unpause") { state.unpause(session) }
            } else {
                Button("Pause") { state.pause(session) }
            }
            Button("Free (keep window)") { state.free(session) }
            Button("Free and close window") { state.free(session, closeWindow: true) }
            Divider()
            if session.process?.host == .terminalApp {
                Button("Focus window") { state.focus(session) }
            }
        } else if session.isInterrupted {
            Button("Resume in new Terminal window") { state.reopen(session) }
            Button("Dismiss from live list") { state.free(session) }
        } else if session.record != nil {
            Button("Resume in new Terminal window") { state.reopen(session) }
        }

        if session.record != nil {
            Divider()
            Button(state.isStarred(session) ? "Remove star" : "Star this session") {
                state.toggleStar(session)
            }
            Menu("Tags") { tagMenuItems }
        }

        if let record = session.record {
            Divider()
            Button("Copy resume command (with cd)") { state.copyResumeCommand(session) }
            if let short = session.shortResumeCommand {
                Button("Copy resume command only") { Pasteboard.copy(short) }
            }
            Button("Copy session id") { Pasteboard.copy(record.id) }
            Button("Copy directory") { Pasteboard.copy(session.directory) }
            Divider()
            Button("Reveal transcript in Finder") {
                NSWorkspace.shared.selectFile(record.filePath, inFileViewerRootedAtPath: "")
            }
        }
    }
}
