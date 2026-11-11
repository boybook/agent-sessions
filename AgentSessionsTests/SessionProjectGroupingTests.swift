import XCTest
@testable import AgentSessions

final class SessionProjectGroupingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionProjectGroupingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A Git checkout at `root/<components>`; returns its standardized path.
    private func repo(_ components: String...) throws -> String {
        var url = root!
        for c in components { url.appendPathComponent(c, isDirectory: true) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git", isDirectory: true),
                                                withIntermediateDirectories: true)
        return url.standardizedFileURL.path
    }

    private func session(_ id: String, cwd: String?, minutesAgo: Double = 0) -> Session {
        let date = Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60)
        return Session(
            id: id,
            source: .codex,
            startTime: date,
            endTime: date,
            model: "test-model",
            filePath: "/tmp/\(id).jsonl",
            fileSizeBytes: 1024,
            eventCount: 1,
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: "Session \(id)"
        )
    }

    func testGroupsFollowFirstAppearanceAndKeepRowOrder() throws {
        let alpha = try repo("alpha")
        let beta = try repo("beta")
        let rows = [
            session("a1", cwd: alpha),
            session("b1", cwd: beta + "/Sources"),
            session("a2", cwd: alpha + "/docs"),
            session("b2", cwd: beta),
        ]
        let groups = SessionProjectGrouping.build(rows: rows, rowMeta: [:])

        XCTAssertEqual(groups.map(\.title), ["alpha", "beta"])
        XCTAssertEqual(groups.map { $0.rows.map(\.id) }, [["a1", "a2"], ["b1", "b2"]])
        XCTAssertEqual(groups.map(\.sessionCount), [2, 2])
        XCTAssertEqual(groups[0].selection?.identity.canonicalRootPath, alpha)
        XCTAssertNil(groups[0].subtitle)
        // Every row lands in exactly one group.
        XCTAssertEqual(groups.flatMap(\.rows).count, rows.count)
    }

    func testSubagentChildStaysWithParentAndIsNotCounted() throws {
        let alpha = try repo("alpha")
        let beta = try repo("beta")
        let rows = [
            session("parent", cwd: alpha),
            session("child", cwd: beta),
            session("other", cwd: beta),
        ]
        let meta: [String: SubagentRowMeta] = [
            "parent": SubagentRowMeta(depth: 0, hasChildren: true, childCount: 1),
            "child": SubagentRowMeta(depth: 1, hasChildren: false, childCount: 0),
        ]
        let groups = SessionProjectGrouping.build(rows: rows, rowMeta: meta)

        XCTAssertEqual(groups.map { $0.rows.map(\.id) }, [["parent", "child"], ["other"]])
        XCTAssertEqual(groups.map(\.sessionCount), [1, 1])
    }

    func testRowsWithoutProjectShareTheNoProjectGroup() {
        let rows = [session("x", cwd: nil), session("y", cwd: "")]
        let groups = SessionProjectGrouping.build(rows: rows, rowMeta: [:])

        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isNoProject)
        XCTAssertNil(groups[0].selection)
        XCTAssertEqual(groups[0].rows.map(\.id), ["x", "y"])
    }

    func testSameNamedProjectsAreSeparateAndDisambiguated() throws {
        let work = try repo("work", "app")
        let home = try repo("home", "app")
        let rows = [session("w", cwd: work), session("h", cwd: home)]
        let groups = SessionProjectGrouping.build(rows: rows, rowMeta: [:])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.title), ["app", "app"])
        XCTAssertNotEqual(groups[0].id, groups[1].id)
        XCTAssertEqual(groups[0].subtitle, "…/work")
        XCTAssertEqual(groups[1].subtitle, "…/home")
    }

    func testEmptyRowsProduceNoGroups() {
        XCTAssertTrue(SessionProjectGrouping.build(rows: [], rowMeta: [:]).isEmpty)
    }

    func testRowsBuilderGroupsOnlyWhenAsked() throws {
        let alpha = try repo("alpha")
        let rows = [session("a1", cwd: alpha), session("n", cwd: nil)]
        func input(_ group: Bool) -> SessionRowsBuilder.RowsInput {
            SessionRowsBuilder.RowsInput(
                nextRows: rows, allSessions: rows, previousCachedRows: [],
                collapsedParents: [], showSubagentHierarchy: false, searchActive: false,
                isHierarchyBrowsing: false, presences: [], directJoinFallbackKeys: [],
                groupByProject: group)
        }
        XCTAssertTrue(SessionRowsBuilder.build(input: input(false)).projectGroups.isEmpty)
        let grouped = SessionRowsBuilder.build(input: input(true))
        XCTAssertEqual(grouped.projectGroups.flatMap(\.rows).map(\.id), grouped.cachedRows.map(\.id))
    }

    func testCollapseStoreRoundTrips() {
        let defaults = UserDefaults(suiteName: "SessionProjectGroupingTests-\(UUID().uuidString)")!
        XCTAssertEqual(SessionProjectGroupCollapseStore.load(defaults), [])
        SessionProjectGroupCollapseStore.save(["path:/a", "none"], defaults)
        XCTAssertEqual(SessionProjectGroupCollapseStore.load(defaults), ["path:/a", "none"])
        SessionProjectGroupCollapseStore.save([], defaults)
        XCTAssertEqual(SessionProjectGroupCollapseStore.load(defaults), [])
    }
}
