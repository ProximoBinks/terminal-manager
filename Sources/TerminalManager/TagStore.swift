import SwiftUI

enum TagColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red:    return Color(red: 0.89, green: 0.29, blue: 0.32)
        case .orange: return Color(red: 0.92, green: 0.52, blue: 0.20)
        case .yellow: return Color(red: 0.82, green: 0.66, blue: 0.12)
        case .green:  return Color(red: 0.28, green: 0.64, blue: 0.38)
        case .teal:   return Color(red: 0.18, green: 0.62, blue: 0.62)
        case .blue:   return Color(red: 0.27, green: 0.51, blue: 0.90)
        case .purple: return Color(red: 0.56, green: 0.40, blue: 0.85)
        case .pink:   return Color(red: 0.85, green: 0.35, blue: 0.58)
        case .gray:   return Color(red: 0.52, green: 0.54, blue: 0.58)
        }
    }
}

struct Tag: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var color: TagColor
}

struct TagDraft: Equatable {
    var sessionID: String?
    var existing: Tag?
    var name: String
    var color: TagColor

    var isRename: Bool { existing != nil }
}

/// Named colour labels, persisted by session id the same way stars are.
struct TagStore: Codable {
    var tags: [Tag] = []
    /// session id → tag ids
    var assignments: [String: [String]] = [:]

    private static var storeURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("tags.json")
    }

    static func load() -> TagStore {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(TagStore.self, from: data)
        else { return TagStore() }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    func tags(for sessionID: String) -> [Tag] {
        let assigned = Set(assignments[sessionID] ?? [])
        return tags.filter { assigned.contains($0.id) }
    }

    func contains(_ tag: Tag, on sessionID: String) -> Bool {
        assignments[sessionID]?.contains(tag.id) ?? false
    }

    mutating func toggle(_ tag: Tag, on sessionID: String) {
        var current = assignments[sessionID] ?? []
        if let index = current.firstIndex(of: tag.id) {
            current.remove(at: index)
        } else {
            current.append(tag.id)
        }
        assignments[sessionID] = current.isEmpty ? nil : current
        save()
    }

    /// Creates a tag, or returns an existing one with the same name (ignoring case).
    @discardableResult
    mutating func create(name: String, color: TagColor) -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = tags.first(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            return existing
        }
        let tag = Tag(id: UUID().uuidString, name: trimmed, color: color)
        tags.append(tag)
        save()
        return tag
    }

    func nextColor() -> TagColor {
        let used = Set(tags.map(\.color))
        return TagColor.allCases.first { !used.contains($0) } ?? .blue
    }

    mutating func rename(_ tag: Tag, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = tags.firstIndex(where: { $0.id == tag.id }) else { return }
        tags[index].name = trimmed
        save()
    }

    mutating func recolor(_ tag: Tag, to color: TagColor) {
        guard let index = tags.firstIndex(where: { $0.id == tag.id }) else { return }
        tags[index].color = color
        save()
    }

    mutating func delete(_ tag: Tag) {
        tags.removeAll { $0.id == tag.id }
        for key in assignments.keys {
            assignments[key]?.removeAll { $0 == tag.id }
            if assignments[key]?.isEmpty == true { assignments[key] = nil }
        }
        save()
    }
}

struct TagPill: View {
    let tag: Tag
    var selected: Bool = false

    var body: some View {
        Text(tag.name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(selected ? Color.white : tag.color.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(selected ? tag.color.color : tag.color.color.opacity(0.18))
            )
            .lineLimit(1)
    }
}
