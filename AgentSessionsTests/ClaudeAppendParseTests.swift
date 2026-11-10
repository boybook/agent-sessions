import XCTest
@testable import AgentSessions

/// A live Claude session is continued from a parse checkpoint instead of re-parsed.
/// The continued session must equal a full parse of the grown file.
final class ClaudeAppendParseTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeAppendParseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func assertSameSession(_ a: Session, _ b: Session, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.events.count, b.events.count, message, file: file, line: line)
        for (x, y) in zip(a.events, b.events) where !Self.sameEvent(x, y) {
            return XCTFail("\(message): event \(x.id) differs from \(y.id)", file: file, line: line)
        }
        XCTAssertEqual(a.eventCount, b.eventCount, message, file: file, line: line)
        XCTAssertEqual(a.title, b.title, message, file: file, line: line)
        XCTAssertEqual(a.model, b.model, message, file: file, line: line)
        XCTAssertEqual(a.cwd, b.cwd, message, file: file, line: line)
        XCTAssertEqual(a.startTime, b.startTime, message, file: file, line: line)
        XCTAssertEqual(a.endTime, b.endTime, message, file: file, line: line)
        XCTAssertEqual(a.customTitle, b.customTitle, message, file: file, line: line)
        XCTAssertEqual(a.codexInternalSessionIDHint, b.codexInternalSessionIDHint, message, file: file, line: line)
    }

    /// Field-by-field equality, with `rawJSON` compared as JSON: it is a
    /// re-serialized dictionary, so key order differs between parses of one file.
    private static func sameEvent(_ x: SessionEvent, _ y: SessionEvent) -> Bool {
        let mx = Mirror(reflecting: x).children, my = Mirror(reflecting: y).children
        for (cx, cy) in zip(mx, my) {
            if cx.label == "rawJSON" {
                guard let sx = cx.value as? String, let sy = cy.value as? String else { return false }
                if sx == sy { continue }
                guard let dx = Data(base64Encoded: sx), let dy = Data(base64Encoded: sy),
                      let ox = try? JSONSerialization.jsonObject(with: dx) as? NSObject,
                      let oy = try? JSONSerialization.jsonObject(with: dy) as? NSObject,
                      ox.isEqual(oy) else { return false }
            } else if String(reflecting: cx.value) != String(reflecting: cy.value) {
                return false
            }
        }
        return true
    }

    /// Splits `source` at every `stride`-th line boundary (plus mid-line), parses
    /// the head with a checkpoint, appends the rest in two writes, and compares.
    private func checkEquivalence(source: URL, stride: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = try Data(contentsOf: source)
        var boundaries: [Int] = [0]
        for (i, b) in bytes.enumerated() where b == 0x0A { boundaries.append(i + 1) }
        let url = tempDir.appendingPathComponent("session.jsonl")

        for (n, cut) in boundaries.enumerated() where n % stride == 0 && cut < bytes.count {
            try? FileManager.default.removeItem(at: url)
            try bytes.prefix(cut).write(to: url)
            var (_, checkpoint) = try XCTUnwrap(ClaudeSessionParser.parseFileFullCheckpointed(at: url, forcedID: "s"))
            // Second write lands mid-line: the partial line must wait for its newline.
            let mid = cut + (bytes.count - cut) / 2
            for range in [cut..<mid, mid..<bytes.count] where !range.isEmpty {
                try append(bytes.subdata(in: range), to: url)
                switch ClaudeSessionParser.parseFileAppend(at: url, forcedID: "s", checkpoint: checkpoint) {
                case .appended(_, let next): checkpoint = next
                case .unchanged: break
                case .fallbackToFullParse: return XCTFail("unexpected fallback at cut \(cut)", file: file, line: line)
                }
            }
            // Event IDs derive from the file path: compare against a full parse of the same file.
            let expected = try XCTUnwrap(ClaudeSessionParser.parseFileFull(at: url, forcedID: "s"))
            XCTAssertEqual(checkpoint.byteOffset, UInt64(boundaries.last!), file: file, line: line)
            // The final checkpoint's state, finished, is what the last append published.
            let resumed = checkpoint.state.makeSession(forcedID: "s", size: bytes.count)
            assertSameSession(resumed, expected, "cut \(cut)", file: file, line: line)
        }
    }

    func testAppendMatchesFullParseAtEveryLineBoundary() throws {
        try checkEquivalence(source: FixturePaths.stage0FixtureURL("agents/claude/small.jsonl"), stride: 1)
    }

    func testAppendMatchesFullParseOnSchemaDriftFixture() throws {
        try checkEquivalence(source: FixturePaths.stage0FixtureURL("agents/claude/schema_drift.jsonl"), stride: 1)
    }

    func testAppendResultEqualsFullParseOfGrownFile() throws {
        let source = FixturePaths.stage0FixtureURL("agents/claude/small.jsonl")
        let bytes = try Data(contentsOf: source)
        let half = bytes.prefix(through: bytes.prefix(bytes.count / 2).lastIndex(of: 0x0A)!)
        let url = tempDir.appendingPathComponent("grow.jsonl")
        try Data(half).write(to: url)
        let (_, checkpoint) = try XCTUnwrap(ClaudeSessionParser.parseFileFullCheckpointed(at: url, forcedID: "g"))
        if case .unchanged = ClaudeSessionParser.parseFileAppend(at: url, forcedID: "g", checkpoint: checkpoint) {} else {
            XCTFail("no growth must be .unchanged")
        }
        try append(bytes.subdata(in: half.count..<bytes.count), to: url)
        guard case .appended(let appended, _) = ClaudeSessionParser.parseFileAppend(at: url, forcedID: "g", checkpoint: checkpoint) else {
            return XCTFail("growth must append")
        }
        let full = try XCTUnwrap(ClaudeSessionParser.parseFileFull(at: url, forcedID: "g"))
        assertSameSession(appended, full, "grown file")
        XCTAssertEqual(appended.fileSizeBytes, full.fileSizeBytes)
    }

    func testReplacedFileFallsBackToFullParse() throws {
        let source = FixturePaths.stage0FixtureURL("agents/claude/small.jsonl")
        let url = tempDir.appendingPathComponent("replace.jsonl")
        try Data(contentsOf: source).write(to: url)
        let (_, checkpoint) = try XCTUnwrap(ClaudeSessionParser.parseFileFullCheckpointed(at: url, forcedID: "r"))
        // Atomic replace: new inode.
        let replacement = tempDir.appendingPathComponent("replace.tmp")
        try Data(contentsOf: source).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        if case .fallbackToFullParse = ClaudeSessionParser.parseFileAppend(at: url, forcedID: "r", checkpoint: checkpoint) {} else {
            XCTFail("a replaced file must fall back to a full parse")
        }
    }

    /// Opt-in check against a real (large) session: AS_CLAUDE_APPEND_FILE=/path/to/session.jsonl
    func testRealSessionEquivalenceWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["AS_CLAUDE_APPEND_FILE"], !path.isEmpty else {
            throw XCTSkip("set AS_CLAUDE_APPEND_FILE to run")
        }
        let copy = tempDir.appendingPathComponent("real.jsonl")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        let bytes = try Data(contentsOf: copy)
        for fraction in [0.5, 0.9, 0.999] {
            let cut = bytes.prefix(Int(Double(bytes.count) * fraction)).lastIndex(of: 0x0A)! + 1
            let url = tempDir.appendingPathComponent("real-cut.jsonl")
            try bytes.prefix(cut).write(to: url)
            let (_, checkpoint) = try XCTUnwrap(ClaudeSessionParser.parseFileFullCheckpointed(at: url, forcedID: "x"))
            try append(bytes.subdata(in: cut..<bytes.count), to: url)
            guard case .appended(let session, _) = ClaudeSessionParser.parseFileAppend(at: url, forcedID: "x", checkpoint: checkpoint) else {
                return XCTFail("append failed at \(fraction)")
            }
            let expected = try XCTUnwrap(ClaudeSessionParser.parseFileFull(at: url, forcedID: "x"))
            assertSameSession(session, expected, "real cut \(fraction)")
            try? FileManager.default.removeItem(at: url)
        }
    }
}
