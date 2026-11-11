import XCTest
@testable import AgentSessions

@MainActor
final class NewSessionLauncherTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "NewSessionLauncherTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func session(_ id: String, source: SessionSource = .claude, cwd: String?, start: Date) -> Session {
        Session(id: id, source: source, startTime: start, endTime: start, model: "m",
                filePath: "/tmp/\(id).jsonl", fileSizeBytes: 1, eventCount: 1, events: [],
                cwd: cwd, repoName: nil, lightweightTitle: id)
    }

    // MARK: Default agent

    func testAutomaticUsesTheProjectsLatestAgent() {
        let available: [SessionSource] = [.codex, .claude]
        XCTAssertEqual(NewSessionLauncher.defaultSource(projectLatest: .claude, available: available, defaults: defaults), .claude)
    }

    func testAutomaticFallsBackToFirstAvailable() {
        let available: [SessionSource] = [.codex, .claude]
        XCTAssertEqual(NewSessionLauncher.defaultSource(projectLatest: nil, available: available, defaults: defaults), .codex)
        // A latest agent that is not launchable (disabled, or never resumable) is skipped.
        XCTAssertEqual(NewSessionLauncher.defaultSource(projectLatest: .cline, available: available, defaults: defaults), .codex)
    }

    func testFixedDefaultWinsWhileAvailable() {
        defaults.set(SessionSource.codex.rawValue, forKey: PreferencesKey.NewSession.defaultAgent)
        XCTAssertEqual(NewSessionLauncher.defaultSource(projectLatest: .claude, available: [.codex, .claude], defaults: defaults), .codex)
        // Once the fixed agent is unavailable, Automatic's rules apply.
        XCTAssertEqual(NewSessionLauncher.defaultSource(projectLatest: .claude, available: [.claude], defaults: defaults), .claude)
    }

    func testNoAvailableAgentGivesNil() {
        XCTAssertNil(NewSessionLauncher.defaultSource(projectLatest: .claude, available: [], defaults: defaults))
    }

    // MARK: Command

    func testCommandQuotesTheBinaryAndAddsCursorsAgentSubcommand() {
        XCTAssertEqual(NewSessionLauncher.coreCommand(for: .claude, binary: URL(fileURLWithPath: "/opt/my tools/claude")),
                       "'/opt/my tools/claude'")
        XCTAssertTrue(NewSessionLauncher.coreCommand(for: .cursor, binary: URL(fileURLWithPath: "/usr/local/bin/cursor"))
            .hasSuffix(" agent"))
        XCTAssertFalse(NewSessionLauncher.coreCommand(for: .cursor, binary: URL(fileURLWithPath: "/usr/local/bin/agent"))
            .hasSuffix(" agent"))
    }

    // MARK: Tracker

    func testTrackerClaimsTheNewSessionInTheLaunchDirectoryOnce() {
        let tracker = NewSessionTracker()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        tracker.started(source: .claude, directory: dir)

        let old = session("old", cwd: dir.path, start: Date().addingTimeInterval(-3600))
        let otherAgent = session("codex", source: .codex, cwd: dir.path, start: Date())
        let elsewhere = session("else", cwd: "/tmp", start: Date())
        let created = session("new", cwd: dir.appendingPathComponent("Sources").path, start: Date())

        XCTAssertNil(tracker.claim(in: [old, otherAgent, elsewhere]))
        XCTAssertNotNil(tracker.pending)
        XCTAssertEqual(tracker.claim(in: [old, created])?.id, "new")
        XCTAssertNil(tracker.pending)
        XCTAssertNil(tracker.claim(in: [created]))
    }
}
