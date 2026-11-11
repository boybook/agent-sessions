import XCTest
@testable import AgentSessions

/// `visibleRows` (filter a fully expanded build) must equal building with the
/// collapsed set, so a disclosure click can re-filter in place.
final class SubagentHierarchyVisibilityTests: XCTestCase {
    private func session(_ id: String, parent: String?, minutesAgo: Int) -> Session {
        let date = Date(timeIntervalSince1970: 1_800_000_000 - Double(minutesAgo) * 60)
        return Session(id: id, source: .claude, startTime: date, endTime: date, model: "m",
                       filePath: "/tmp/\(id).jsonl", fileSizeBytes: 1, eventCount: 1, events: [],
                       cwd: "/tmp", repoName: nil, lightweightTitle: id,
                       parentSessionID: parent,
                       relationshipKind: parent == nil ? nil : .subagent)
    }

    func testFilteringTheExpandedBuildEqualsBuildingCollapsed() {
        var generator = SystemRandomNumberGenerator()
        for trial in 0..<60 {
            // A random forest: each session's parent is an earlier session or none.
            var sessions: [Session] = []
            let count = Int.random(in: 1...40, using: &generator)
            for i in 0..<count {
                let parent: String? = (i > 0 && Bool.random(using: &generator))
                    ? "t\(trial)-\(Int.random(in: 0..<i, using: &generator))" : nil
                sessions.append(session("t\(trial)-\(i)", parent: parent, minutesAgo: Int.random(in: 0...500, using: &generator)))
            }
            let expanded = SubagentHierarchyBuilder.build(sessions: sessions, collapsedParents: [], hierarchyEnabled: true)
            let parents = expanded.rowMeta.filter { $0.value.hasChildren }.map(\.key)
            let collapsed = Set(parents.filter { _ in Bool.random(using: &generator) })

            let direct = SubagentHierarchyBuilder.build(sessions: sessions, collapsedParents: collapsed, hierarchyEnabled: true)
            let filtered = SubagentHierarchyBuilder.visibleRows(expanded.sessions, rowMeta: expanded.rowMeta, collapsedParents: collapsed)

            XCTAssertEqual(filtered.map(\.id), direct.sessions.map(\.id), "trial \(trial), collapsed \(collapsed.sorted())")
            for row in filtered {
                XCTAssertEqual(expanded.rowMeta[row.id], direct.rowMeta[row.id], "meta for \(row.id) in trial \(trial)")
            }
        }
    }

    func testNothingCollapsedReturnsTheExpandedRows() {
        let sessions = [session("p", parent: nil, minutesAgo: 0), session("c", parent: "p", minutesAgo: 1)]
        let expanded = SubagentHierarchyBuilder.build(sessions: sessions, collapsedParents: [], hierarchyEnabled: true)
        XCTAssertEqual(SubagentHierarchyBuilder.visibleRows(expanded.sessions, rowMeta: expanded.rowMeta, collapsedParents: []).map(\.id),
                       ["p", "c"])
        XCTAssertEqual(SubagentHierarchyBuilder.visibleRows(expanded.sessions, rowMeta: expanded.rowMeta, collapsedParents: ["p"]).map(\.id),
                       ["p"])
    }
}
