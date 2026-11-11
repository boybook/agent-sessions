import SwiftUI

/// Header row of one project section in the grouped session list. The Table draws
/// the disclosure chevron and the section row itself; this is only its content.
struct SessionProjectGroupHeader: View {
    let group: SessionProjectGroup
    /// Filters the list to this project; nil when the group has no provable root.
    let filter: (() -> Void)?
    let collapseAll: () -> Void
    let expandAll: () -> Void
    /// Starts a new session in the project with the given agent; nil when the
    /// group has no directory to start in (No Project, Desktop chat labels).
    var startSession: ((SessionSource) -> Void)? = nil
    /// What a click on ⊕ uses (Settings → General → New Sessions).
    var defaultSource: SessionSource? = nil
    /// Every agent offered in the context menu.
    var sources: [SessionSource] = []

    @State private var isHoveringNew = false

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
            if let startSession, let defaultSource {
                // Always visible but faint, full strength on hover: a hover-only
                // control would be undiscoverable.
                Button { startSession(defaultSource) } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(isHoveringNew ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
                        .imageScale(.medium)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringNew = $0 }
                .help(Text("New \(defaultSource.displayName) session in \(group.title)"))
                .accessibilityLabel(Text("New Session"))
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let startSession, !sources.isEmpty {
                Menu("New Session") {
                    ForEach(sources, id: \.self) { source in
                        Button(source.displayName) { startSession(source) }
                    }
                }
                Divider()
            }
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

/// The "Session" cell of a section's "Show N more sessions" placeholder row. The
/// row sits inside the project's section, so it lines up with the session titles.
struct SessionProjectGroupShowMoreRow: View {
    let hiddenCount: Int
    let showAll: () -> Void

    var body: some View {
        Button(action: showAll) {
            HStack(spacing: 4) {
                Text("Show \(hiddenCount) more sessions")
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Show every session in this project"))
    }
}

extension View {
    /// Blanks a cell on a section's "Show more" placeholder row: only the Session
    /// column draws there.
    func blankOnShowMoreRow(_ session: Session) -> some View {
        let isPlaceholder = SessionProjectGrouping.isShowMoreRow(session.id)
        return opacity(isPlaceholder ? 0 : 1)
            .allowsHitTesting(!isPlaceholder)
            .accessibilityHidden(isPlaceholder)
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
