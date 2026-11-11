import SwiftUI

/// Header row of one project section in the grouped session list. The Table draws
/// the disclosure chevron and the section row itself; this is only its content.
struct SessionProjectGroupHeader: View {
    let group: SessionProjectGroup
    /// Filters the list to this project; nil when the group has no provable root.
    let filter: (() -> Void)?
    let collapseAll: () -> Void
    let expandAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.isNoProject ? "questionmark.folder" : "folder")
                .foregroundStyle(.secondary)
                .imageScale(.medium)
            title
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
            if let subtitle = group.subtitle {
                Text(verbatim: subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            // Beside the title: a section header row is only as wide as its content.
            Text(group.sessionCount, format: .number)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let filter {
                Button("Filter by Project: \(group.title)", action: filter)
                Divider()
            }
            Button("Collapse All Projects", action: collapseAll)
            Button("Expand All Projects", action: expandAll)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: Text {
        group.isNoProject ? Text("No Project") : Text(verbatim: group.title)
    }
}

/// Persists which project sections are collapsed, keyed by `SessionProjectGroup.id`.
enum SessionProjectGroupCollapseStore {
    static func load(_ defaults: UserDefaults = .standard) -> Set<String> {
        guard let raw = defaults.string(forKey: PreferencesKey.Unified.collapsedProjectGroups),
              !raw.isEmpty else { return [] }
        return Set(raw.split(separator: "\n").map(String.init))
    }

    static func save(_ ids: Set<String>, _ defaults: UserDefaults = .standard) {
        if ids.isEmpty {
            defaults.removeObject(forKey: PreferencesKey.Unified.collapsedProjectGroups)
        } else {
            defaults.set(ids.sorted().joined(separator: "\n"), forKey: PreferencesKey.Unified.collapsedProjectGroups)
        }
    }
}
