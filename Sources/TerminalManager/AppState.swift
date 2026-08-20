import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    @Published private(set) var sessions: [ManagedSession] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published var query: String = ""
    @Published var showArchived: Bool = false {
        didSet {
            guard memory.showArchived != showArchived else { return }
            memory.showArchived = showArchived
            memory.save()
        }
    }
    @Published var openAtLogin: Bool = false
    @Published private var expansionOverrides: [String: Bool] = [:]
    @Published private var favorites = Favorites.load()
    @Published private var tagStore = TagStore.load()
    /// When set, the list shows only sessions that carry this tag.
    @Published var tagFilter: String?
    /// Inline composer for creating or renaming a tag.
    @Published var tagDraft: TagDraft?

    private var memory: AppMemory
    /// Session ids the user Freed this launch. Until the process actually disappears they must
    /// not be written back into the interrupted roster, or a reboot would resurrect a Free.
    private var recentlyFreed: Set<String> = []
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 8
    private var started = false
    private var refreshGeneration = 0
    private var wakeTask: Task<Void, Never>?
    private var wakeObservers: [NSObjectProtocol] = []

    var liveSessions: [ManagedSession] { sessions.filter(\.isLive) }
    var interruptedSessions: [ManagedSession] { sessions.filter(\.isInterrupted) }
    var archivedSessions: [ManagedSession] { sessions.filter { !$0.isLive && !$0.isInterrupted } }

    init() {
        let loaded = AppMemory.load()
        memory = loaded
        showArchived = loaded.showArchived
        expansionOverrides = loaded.expansion
        openAtLogin = LoginItem.isEnabled
    }

    var totalRAM: Int { liveSessions.reduce(0) { $0 + $1.ramBytes } }

    var statusTitle: String {
        "\(liveSessions.count) · \(Format.compactBytes(totalRAM))"
    }

    /// The list the UI renders: live first, archived only when asked for or when searching.
    var visibleSessions: [ManagedSession] {
        // Saved sessions join the list when explicitly requested, and always while searching.
        // Starred ones are always present: a session you deliberately flagged is exactly the one
        // you want to find again after freeing it.
        var base = (showArchived || isSearching || tagFilter != nil)
            ? sessions
            : sessions.filter { $0.isLive || $0.isInterrupted || isStarred($0) }

        if let tagID = tagFilter {
            base = base.filter { tags(for: $0).contains { $0.id == tagID } }
        }

        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return base }

        let terms = trimmed.split(separator: " ").map(String.init)
        return base.filter { session in
            let haystack = session.searchText + " " + tags(for: session).map { $0.name.lowercased() }.joined(separator: " ")
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Sessions organised into project sections for the list.
    var visibleGroups: [ProjectGroup] {
        ProjectGroup.build(from: visibleSessions, starred: favorites.ids, tags: tagStore)
    }

    // MARK: - Starring

    func isStarred(_ session: ManagedSession) -> Bool {
        guard let id = session.record?.id else { return false }
        return favorites.contains(id)
    }

    func canStar(_ session: ManagedSession) -> Bool { session.record != nil }

    func toggleStar(_ session: ManagedSession) {
        guard let id = session.record?.id else { return }
        favorites.toggle(id)
    }

    var starredCount: Int { favorites.ids.count }

    // MARK: - Tags

    var allTags: [Tag] { tagStore.tags }

    func tags(for session: ManagedSession) -> [Tag] {
        guard let id = session.record?.id else { return [] }
        return tagStore.tags(for: id)
    }

    func hasTag(_ tag: Tag, on session: ManagedSession) -> Bool {
        guard let id = session.record?.id else { return false }
        return tagStore.contains(tag, on: id)
    }

    func toggleTag(_ tag: Tag, on session: ManagedSession) {
        guard let id = session.record?.id else { return }
        tagStore.toggle(tag, on: id)
    }

    func beginNewTag(for session: ManagedSession) {
        guard session.record != nil else { return }
        tagDraft = TagDraft(sessionID: session.record?.id, existing: nil, name: "", color: tagStore.nextColor())
    }

    func beginRename(_ tag: Tag) {
        tagDraft = TagDraft(sessionID: nil, existing: tag, name: tag.name, color: tag.color)
    }

    func commitTagDraft() {
        guard let draft = tagDraft else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let existing = draft.existing {
            tagStore.rename(existing, to: name)
            tagStore.recolor(existing, to: draft.color)
        } else if let tag = tagStore.create(name: name, color: draft.color) {
            if let sessionID = draft.sessionID {
                if !tagStore.contains(tag, on: sessionID) {
                    tagStore.toggle(tag, on: sessionID)
                }
            }
        }
        tagDraft = nil
    }

    func cancelTagDraft() { tagDraft = nil }

    func updateDraftName(_ name: String) {
        guard var draft = tagDraft else { return }
        draft.name = name
        tagDraft = draft
    }

    func updateDraftColor(_ color: TagColor) {
        guard var draft = tagDraft else { return }
        draft.color = color
        tagDraft = draft
    }

    func recolor(_ tag: Tag, to color: TagColor) {
        tagStore.recolor(tag, to: color)
    }

    func deleteTag(_ tag: Tag) {
        if tagFilter == tag.id { tagFilter = nil }
        tagStore.delete(tag)
    }

    func toggleTagFilter(_ tag: Tag) {
        tagFilter = tagFilter == tag.id ? nil : tag.id
    }

    /// Sections start expanded when they contain something running, or whenever a search is
    /// active, so results are never hidden behind a collapsed header.
    func isExpanded(_ group: ProjectGroup) -> Bool {
        if isSearching || tagFilter != nil { return true }
        if group.isStarredSection { return expansionOverrides[group.key] ?? true }
        if let override = expansionOverrides[group.key] { return override }
        return group.liveCount > 0 || group.interruptedCount > 0
    }

    func toggleExpansion(_ group: ProjectGroup) {
        expansionOverrides[group.key] = !isExpanded(group)
        memory.expansion = expansionOverrides
        memory.save()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        openAtLogin = LoginItem.isEnabled
    }

    func start() {
        openAtLogin = LoginItem.isEnabled
        refresh(force: true)
        guard !started else { return }
        started = true

        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        observeWake()
    }

    /// Rescan live terminals. `force` starts a new scan even if one is already in flight, which
    /// is what you want after sleep when `ps`/`lsof` may have wedged the previous pass.
    func refresh(force: Bool = false) {
        guard force || !isRefreshing else { return }
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        let remembered = memory.remembered

        Task.detached(priority: .userInitiated) {
            guard let processes = ProcessScanner.scan() else {
                await MainActor.run { [weak self] in
                    guard let self, self.refreshGeneration == generation else { return }
                    self.isRefreshing = false
                }
                return
            }

            let windows = TerminalBridge.windows()
            let records = SessionIndex.loadAll()
            let merged = SessionMatcher.merge(
                processes: processes,
                windows: windows,
                records: records,
                remembered: remembered
            )

            await MainActor.run { [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                self.syncRoster(from: merged)
                self.sessions = merged
                self.isRefreshing = false
            }
        }
    }

    private func observeWake() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        for name in names {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleWakeRefresh() }
            }
            wakeObservers.append(token)
        }

        let screensaver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleWakeRefresh() }
        }
        wakeObservers.append(screensaver)
    }

    private func scheduleWakeRefresh() {
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh(force: true)
        }
    }

    // MARK: - Actions

    /// Terminates the session's process tree, leaving the terminal window open at a shell prompt.
    /// For an interrupted row (process already gone) this just dismisses it from the live group.
    func free(_ session: ManagedSession, closeWindow: Bool = false) {
        if let id = session.record?.id {
            memory.forget(id)
            recentlyFreed.insert(id)
        }
        guard let process = session.process else {
            sessions.removeAll { $0.id == session.id }
            return
        }
        let tty = process.tty

        Task.detached(priority: .userInitiated) {
            ProcessKiller.terminateTree(root: process.pid, descendants: process.descendants)

            if closeWindow, let tty {
                try? await Task.sleep(nanoseconds: 600_000_000)
                TerminalBridge.close(tty: tty)
            }

            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run { [weak self] in self?.refresh(force: true) }
        }
    }

    /// SIGSTOP the session's process tree. It stays in the live list, holding RAM, until unpaused.
    func pause(_ session: ManagedSession) {
        guard let process = session.process, !process.isStopped else { return }
        Task.detached(priority: .userInitiated) {
            ProcessKiller.stopTree(root: process.pid, descendants: process.descendants)
            await MainActor.run { [weak self] in self?.refresh(force: true) }
        }
    }

    /// SIGCONT the session's process tree so it continues in the same window.
    func unpause(_ session: ManagedSession) {
        guard let process = session.process, process.isStopped else { return }
        Task.detached(priority: .userInitiated) {
            ProcessKiller.continueTree(root: process.pid, descendants: process.descendants)
            await MainActor.run { [weak self] in self?.refresh(force: true) }
        }
    }

    /// Frees every live session except the one this app was launched from, if any.
    func freeAll(except keep: Set<String> = []) {
        let targets = liveSessions.filter { !keep.contains($0.id) }
        for session in targets { free(session) }
    }

    func focus(_ session: ManagedSession) {
        guard let tty = session.process?.tty else { return }
        TerminalBridge.focus(tty: tty)
    }

    func reopen(_ session: ManagedSession) {
        guard let command = session.resumeCommand else { return }
        TerminalBridge.resume(command: command)
    }

    func copyResumeCommand(_ session: ManagedSession) {
        guard let command = session.resumeCommand else { return }
        Pasteboard.copy(command)
    }

    /// Upsert live sessions into the persisted roster, skipping anything the user just Freed.
    private func syncRoster(from sessions: [ManagedSession]) {
        let live = sessions.filter(\.isLive)
        let liveIDs = Set(live.compactMap { $0.record?.id })
        recentlyFreed = recentlyFreed.intersection(liveIDs)
        let skip = recentlyFreed
        memory.rememberLive(live.filter { session in
            guard let id = session.record?.id else { return false }
            return !skip.contains(id)
        })
    }
}

enum Format {
    static func compactBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    static func relative(_ date: Date) -> String {
        guard date > .distantPast else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
