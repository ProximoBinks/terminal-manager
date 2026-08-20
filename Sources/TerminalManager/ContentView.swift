import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmingFreeAll = false
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showingSettings {
                SettingsView()
            } else {
                searchField
                if !state.allTags.isEmpty {
                    tagFilterBar
                }
                Divider()
                list
                if state.tagDraft != nil {
                    Divider()
                    tagComposer
                }
                Divider()
                footer
            }
        }
        .frame(width: 440, height: 580)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if showingSettings {
                Button {
                    showingSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Back")

                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(state.liveSessions.count) live sessions")
                        .font(.system(size: 13, weight: .semibold))
                    Text(headerSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    state.refresh(force: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Reload")
                    }
                    .opacity(state.isRefreshing ? 0.5 : 1)
                }
                .buttonStyle(.borderless)
                .help("Rescan live terminals. Use this after sleep if the list looks empty.")

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var headerSubtitle: String {
        var parts = [
            "\(Format.compactBytes(state.totalRAM)) in use"
        ]
        if state.interruptedSessions.count > 0 {
            parts.append("\(state.interruptedSessions.count) interrupted")
        }
        parts.append("\(state.archivedSessions.count) saved")
        if state.starredCount > 0 { parts.append("\(state.starredCount) starred") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

            TextField("Search projects, titles, tags, session ids…", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if state.isSearching {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if state.visibleGroups.isEmpty {
                    emptyState
                } else {
                    ForEach(state.visibleGroups) { group in
                        Section {
                            if state.isExpanded(group) {
                                ForEach(group.sessions) { session in
                                    SessionRow(session: session, showsProjectName: group.isStarredSection)
                                    Divider().padding(.leading, 32)
                                }
                            }
                        } header: {
                            ProjectHeader(group: group)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: (state.isSearching || state.tagFilter != nil) ? "magnifyingglass" : "checkmark.circle")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text((state.isSearching || state.tagFilter != nil) ? "No matches" : "No sessions running")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !state.isSearching && state.tagFilter == nil {
                Text("Star a session to keep it here after you free it")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Show saved", isOn: $state.showArchived)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            Spacer()

            if confirmingFreeAll {
                Button("Cancel") { confirmingFreeAll = false }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button("Free \(state.liveSessions.count) sessions") {
                    state.freeAll()
                    confirmingFreeAll = false
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
            } else {
                Button("Free all") { confirmingFreeAll = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(state.liveSessions.isEmpty)
            }

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Tags

    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.allTags) { tag in
                    Button {
                        state.toggleTagFilter(tag)
                    } label: {
                        TagPill(tag: tag, selected: state.tagFilter == tag.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename…") { state.beginRename(tag) }
                        Menu("Colour") {
                            ForEach(TagColor.allCases) { color in
                                Button(color.rawValue.capitalized) {
                                    state.recolor(tag, to: color)
                                }
                            }
                        }
                        Button("Delete tag", role: .destructive) {
                            state.deleteTag(tag)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private var tagComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.tagDraft?.isRename == true ? "Rename tag" : "New tag")
                .font(.system(size: 11, weight: .semibold))

            TextField("Name", text: Binding(
                get: { state.tagDraft?.name ?? "" },
                set: { state.updateDraftName($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .onSubmit { state.commitTagDraft() }

            HStack(spacing: 7) {
                ForEach(TagColor.allCases) { color in
                    Button {
                        state.updateDraftColor(color)
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 14, height: 14)
                            .overlay {
                                if state.tagDraft?.color == color {
                                    Circle().stroke(Color.primary, lineWidth: 1.5)
                                        .frame(width: 18, height: 18)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(color.rawValue.capitalized)
                }

                Spacer()

                Button("Cancel") { state.cancelTagDraft() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))

                Button(state.tagDraft?.isRename == true ? "Save" : "Add") {
                    state.commitTagDraft()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
                .disabled((state.tagDraft?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Collapsible section header naming the project and summarising what it is costing.
struct ProjectHeader: View {
    let group: ProjectGroup
    @EnvironmentObject private var state: AppState
    @State private var isHovering = false

    var body: some View {
        Button {
            state.toggleExpansion(group)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.isExpanded(group) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                if group.isStarredSection {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                }

                if let tag = group.starredTag {
                    TagPill(tag: tag, selected: state.tagFilter == tag.id)
                } else {
                    Text(group.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }

                if group.liveCount > 0 {
                    Text("\(group.liveCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green))
                }

                if group.interruptedCount > 0 {
                    Text("\(group.interruptedCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                }

                Spacer(minLength: 6)

                if group.ramBytes > 0 {
                    Text(Format.compactBytes(group.ramBytes))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text("\(group.sessions.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 16, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .help(group.path)
        .onHover { isHovering = $0 }
    }
}
