import Foundation

/// One project section of the grouped session list.
struct SessionProjectGroup: Identifiable, Sendable {
    /// Stable key, persisted for the collapse state: `path:<canonical root>` for a
    /// provable project, `name:<label>` for a labelled row without one (Desktop
    /// chats), or `SessionProjectGrouping.noProjectID`.
    let id: String
    /// Project name; empty for the no-project group (the view localizes it).
    let title: String
    /// Distinguishes projects that share `title` (`…/parent`); nil otherwise.
    let subtitle: String?
    /// The exact project, for "Filter by Project"; nil without a provable root.
    let selection: ProjectSelection?
    /// Rows in list order, subagent children kept under their parent.
    let rows: [Session]
    /// Top-level sessions in the group (subagent children not counted).
    let sessionCount: Int
    /// Agent of the group's most recently modified top-level session (the
    /// "Automatic" choice for New Session).
    let latestSource: SessionSource?
    /// The rows a section shows before "Show more": the first few sessions plus
    /// everything from today, in list order. Equals `rows` when nothing is hidden.
    let previewRows: [Session]
    /// Top-level sessions left out of `previewRows` (0: nothing to show more of).
    let hiddenSessionCount: Int
    /// The one-line "Show N more" row that ends a truncated section: a placeholder
    /// row, not a session (see `SessionProjectGrouping.isShowMoreRow`). It lives in
    /// the section itself, so it lines up and spaces like the sessions above it.
    let showMoreRow: Session?

    var isNoProject: Bool { id == SessionProjectGrouping.noProjectID }
}

/// Splits the already filtered, sorted and hierarchy-flattened session rows into
/// project sections. Pure and thread-safe: it runs inside `SessionRowsBuilder.build`,
/// off the main actor on the heavy rebuild path.
///
/// Groups appear in the order of their first row, so the list's sort decides the
/// section order (newest activity first by default, A–Z when sorted by Project).
/// A subagent child (`depth > 0`) stays in its parent's section.
enum SessionProjectGrouping {
    static let noProjectID = "none"
    private static let showMorePrefix = "show-more:"

    static func isShowMoreRow(_ id: String) -> Bool { id.hasPrefix(showMorePrefix) }

    /// The project section a "Show more" row belongs to.
    static func groupID(forShowMoreRow id: String) -> String? {
        isShowMoreRow(id) ? String(id.dropFirst(showMorePrefix.count)) : nil
    }

    private static func makeShowMoreRow(groupID: String, hiddenCount: Int) -> Session {
        let epoch = Date(timeIntervalSince1970: 0)
        return Session(id: showMorePrefix + groupID, source: .codex, startTime: epoch, endTime: epoch,
                       model: nil, filePath: "", fileSizeBytes: nil, eventCount: hiddenCount, events: [],
                       cwd: nil, repoName: nil, lightweightTitle: nil)
    }
    /// Sessions a section always shows before "Show more".
    static let previewMinimum = 5

    static func build(rows: [Session],
                      rowMeta: [String: SubagentRowMeta],
                      now: Date = Date(),
                      calendar: Calendar = .current) -> [SessionProjectGroup] {
        guard !rows.isEmpty else { return [] }

        struct Bucket {
            let key: ProjectKey
            var rows: [Session] = []
            var sessionCount = 0
            var latest: Session?
            var preview: [Session] = []
            var hiddenCount = 0
            var lastTopLevelShown = true
        }
        let startOfToday = calendar.startOfDay(for: now)
        // Buckets live in an array and are mutated in place by index: copying one out
        // of a dictionary to update it would copy its row arrays on every row.
        var buckets: [Bucket] = []
        var indexByID: [String: Int] = [:]
        var parentIndex: Int?

        for row in rows {
            let depth = rowMeta[row.id]?.depth ?? 0
            let index: Int
            if depth > 0, let parentIndex {
                index = parentIndex
            } else {
                let key = projectKey(for: row)
                if let existing = indexByID[key.id] {
                    index = existing
                } else {
                    index = buckets.count
                    indexByID[key.id] = index
                    buckets.append(Bucket(key: key))
                }
                parentIndex = index
            }

            buckets[index].rows.append(row)
            if depth == 0 {
                // Preview: the first few sessions and all of today's; a subagent
                // child follows its parent.
                let shown = buckets[index].sessionCount < previewMinimum || row.modifiedAt >= startOfToday
                buckets[index].lastTopLevelShown = shown
                if !shown { buckets[index].hiddenCount += 1 }
                buckets[index].sessionCount += 1
                if (buckets[index].latest?.modifiedAt ?? .distantPast) < row.modifiedAt {
                    buckets[index].latest = row
                }
            }
            if buckets[index].lastTopLevelShown { buckets[index].preview.append(row) }
        }

        // Projects that share a name get the shortest parent-path suffix that tells
        // them apart (`…/parent`), formatted like the project filter badge.
        var parentsByTitle: [String: [(id: String, parents: [String])]] = [:]
        for bucket in buckets {
            let id = bucket.key.id
            guard let identity = bucket.key.identity else { continue }
            let title = bucket.key.title
            parentsByTitle[title, default: []].append((id, parentComponents(of: identity.canonicalRootPath)))
        }
        var subtitles: [String: String] = [:]
        for (_, entries) in parentsByTitle where entries.count > 1 {
            for entry in entries {
                let rivals = entries.filter { $0.id != entry.id }.map(\.parents)
                subtitles[entry.id] = distinguishingSuffix(own: entry.parents, rivals: rivals)
            }
        }

        return buckets.map { bucket in
            let id = bucket.key.id
            let key = bucket.key
            let subtitle = subtitles[id]
            return SessionProjectGroup(
                id: id,
                title: key.title,
                subtitle: subtitle,
                selection: key.identity.map {
                    ProjectSelection(identity: $0, displayName: key.title, disambiguationPath: subtitle)
                },
                rows: bucket.rows,
                sessionCount: bucket.sessionCount,
                latestSource: bucket.latest?.source,
                // Hiding a single session saves nothing: the "Show more" row takes its place.
                previewRows: bucket.hiddenCount > 1 ? bucket.preview : bucket.rows,
                hiddenSessionCount: bucket.hiddenCount > 1 ? bucket.hiddenCount : 0,
                showMoreRow: bucket.hiddenCount > 1 ? makeShowMoreRow(groupID: id, hiddenCount: bucket.hiddenCount) : nil
            )
        }
    }

    private static func parentComponents(of canonicalRootPath: String) -> [String] {
        URL(fileURLWithPath: canonicalRootPath).deletingLastPathComponent().pathComponents
            .filter { $0 != "/" }
    }

    /// Shortest trailing run of parent directories no rival shares; the full parent
    /// path when none distinguishes.
    private static func distinguishingSuffix(own: [String], rivals: [[String]]) -> String {
        let depth = max(own.count, 1)
        for length in 1...depth {
            let suffix = Array(own.suffix(length))
            guard !suffix.isEmpty else { continue }
            if rivals.allSatisfy({ Array($0.suffix(length)) != suffix }) {
                return "…/" + suffix.joined(separator: "/")
            }
        }
        return "/" + own.joined(separator: "/")
    }

    // MARK: - Per-session project key (memoized)

    struct ProjectKey: Sendable {
        let id: String
        let title: String
        let identity: ProjectIdentity?
    }

    /// The project a row belongs to. Resolving it can stat `.git` and normalize
    /// paths, so it is memoized per session id, modification time and working
    /// directory: a live poll re-resolves only the sessions that changed.
    static func projectKey(for row: Session) -> ProjectKey {
        let cacheKey = CacheKey(id: row.id, modifiedAt: row.modifiedAt, cwd: row.cwd)
        if let cached = keyCache.value(for: cacheKey) { return cached }
        let key = resolveProjectKey(for: row)
        keyCache.store(key, for: cacheKey)
        return key
    }

    private static func resolveProjectKey(for row: Session) -> ProjectKey {
        let label: String? = {
            let raw: String?
            if row.source == .antigravity {
                raw = row.rowRepoName
            } else if let name = row.rowRepoName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                raw = name
            } else {
                raw = row.rowRepoDisplay
            }
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty, trimmed != "—" else { return nil }
            return trimmed
        }()
        if let identity = row.rowProjectIdentity {
            // The root's own name, so a session started in a subfolder or a
            // worktree still titles its project's section by the project.
            let rootName = URL(fileURLWithPath: identity.canonicalRootPath).lastPathComponent
            let title = rootName.isEmpty ? (label ?? identity.canonicalRootPath) : rootName
            return ProjectKey(id: "path:" + identity.canonicalRootPath, title: title, identity: identity)
        }
        if let label {
            return ProjectKey(id: "name:" + label, title: label, identity: nil)
        }
        return ProjectKey(id: noProjectID, title: "", identity: nil)
    }

    private struct CacheKey: Hashable {
        let id: String
        let modifiedAt: Date
        let cwd: String?
    }

    private static let keyCache = KeyCache()

    private final class KeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CacheKey: ProjectKey] = [:]
        /// Bounds memory across very long sessions; a reset only costs one re-resolve.
        private let limit = 100_000

        func value(for key: CacheKey) -> ProjectKey? {
            lock.lock(); defer { lock.unlock() }
            return storage[key]
        }

        func store(_ value: ProjectKey, for key: CacheKey) {
            lock.lock(); defer { lock.unlock() }
            if storage.count >= limit { storage.removeAll(keepingCapacity: true) }
            storage[key] = value
        }
    }
}
