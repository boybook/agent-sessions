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
        XCTAssertEqual(groups.map(\.latestSource), [.codex, .codex])
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

    // MARK: Show more

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func dated(_ id: String, cwd: String, hoursAgo: Double) -> Session {
        let date = now.addingTimeInterval(-hoursAgo * 3600)
        return Session(id: id, source: .codex, startTime: date, endTime: date, model: "m",
                       filePath: "/tmp/\(id).jsonl", fileSizeBytes: 1, eventCount: 1, events: [],
                       cwd: cwd, repoName: nil, lightweightTitle: id)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testLongSectionShowsFirstFiveThenAShowMoreRow() throws {
        let alpha = try repo("alpha")
        let rows = (0..<8).map { dated("s\($0)", cwd: alpha, hoursAgo: 48 + Double($0)) }
        let group = try XCTUnwrap(SessionProjectGrouping.build(rows: rows, rowMeta: [:], now: now, calendar: utc).first)

        XCTAssertEqual(group.previewRows.map(\.id), ["s0", "s1", "s2", "s3", "s4"])
        XCTAssertEqual(group.hiddenSessionCount, 3)
        XCTAssertEqual(group.rows.count, 8)
        let more = try XCTUnwrap(group.showMoreRow)
        XCTAssertTrue(SessionProjectGrouping.isShowMoreRow(more.id))
        XCTAssertEqual(SessionProjectGrouping.groupID(forShowMoreRow: more.id), group.id)
        XCTAssertFalse(SessionProjectGrouping.isShowMoreRow("s0"))
    }

    func testEverySessionFromTodayStaysVisible() throws {
        let alpha = try repo("alpha")
        // 7 sessions today (all after midnight UTC), then 3 older ones.
        let today = (0..<7).map { dated("t\($0)", cwd: alpha, hoursAgo: Double($0) * 0.1) }
        let older = (0..<3).map { dated("o\($0)", cwd: alpha, hoursAgo: 72 + Double($0)) }
        let group = try XCTUnwrap(SessionProjectGrouping.build(rows: today + older, rowMeta: [:], now: now, calendar: utc).first)

        XCTAssertEqual(group.previewRows.map(\.id), today.map(\.id))
        XCTAssertEqual(group.hiddenSessionCount, 3)
    }

    func testHidingASingleSessionIsNotWorthAShowMoreRow() throws {
        let alpha = try repo("alpha")
        let rows = (0..<6).map { dated("s\($0)", cwd: alpha, hoursAgo: 48 + Double($0)) }
        let group = try XCTUnwrap(SessionProjectGrouping.build(rows: rows, rowMeta: [:], now: now, calendar: utc).first)

        XCTAssertEqual(group.hiddenSessionCount, 0)
        XCTAssertNil(group.showMoreRow)
        XCTAssertEqual(group.previewRows.count, 6)
    }

    func testHiddenParentHidesItsSubagentChildren() throws {
        let alpha = try repo("alpha")
        var rows = (0..<7).map { dated("s\($0)", cwd: alpha, hoursAgo: 48 + Double($0)) }
        rows.insert(dated("child", cwd: alpha, hoursAgo: 60), at: 6) // child of s5, which is hidden
        let meta = ["child": SubagentRowMeta(depth: 1, hasChildren: false, childCount: 0)]
        let group = try XCTUnwrap(SessionProjectGrouping.build(rows: rows, rowMeta: meta, now: now, calendar: utc).first)

        XCTAssertEqual(group.previewRows.map(\.id), ["s0", "s1", "s2", "s3", "s4"])
        XCTAssertEqual(group.hiddenSessionCount, 2)
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
