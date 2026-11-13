import XCTest
@testable import AgentSessions

final class TmuxIntegrationTests: XCTestCase {
    // MARK: Launch command

    func testLeadingDirectoryReadsTheQuotedCdPrefix() {
        XCTAssertEqual(TmuxLaunch.leadingDirectory(of: "cd '/Users/me/My Project' && 'claude' --resume x"),
                       "/Users/me/My Project")
        XCTAssertEqual(TmuxLaunch.leadingDirectory(of: "cd '/tmp/it'\\''s' && codex"), "/tmp/it's")
        XCTAssertNil(TmuxLaunch.leadingDirectory(of: "'claude' --continue"))
        XCTAssertNil(TmuxLaunch.leadingDirectory(of: "cd '/tmp/unterminated"))
    }

    func testSessionNameUsesTheFolderAndAvoidsTakenNames() {
        XCTAssertEqual(TmuxLaunch.sessionName(for: "/Users/me/agent.sessions", existing: []), "as-agent_sessions")
        XCTAssertEqual(TmuxLaunch.sessionName(for: "/Users/me/app", existing: ["as-app", "as-app-2"]), "as-app-3")
        XCTAssertEqual(TmuxLaunch.sessionName(for: nil, existing: []), "as-session")
        XCTAssertEqual(TmuxLaunch.sessionName(for: "/x/a:b c", existing: []), "as-a_b_c")
    }

    func testWrappedCommandStartsAMarkedSessionRunningTheOriginalCommand() {
        let command = TmuxLaunch.wrappedCommand("cd '/p' && 'claude' --resume abc",
                                                tmuxPath: "/opt/homebrew/bin/tmux",
                                                sessionName: "as-p",
                                                directory: "/p")
        XCTAssertTrue(command.hasPrefix("'/opt/homebrew/bin/tmux' new-session -s 'as-p' -c '/p' -e \"PATH=$PATH\" /bin/sh -c '"))
        XCTAssertTrue(command.hasSuffix("\\; set-option -q @agent_sessions 1"))
        // The original command survives quoting inside the sh -c script.
        XCTAssertTrue(command.contains("cd '\\''/p'\\'' && '\\''claude'\\'' --resume abc"))
    }

    /// Runs the generated command for real on a private tmux socket.
    func testWrappedCommandRunsInTmux() throws {
        guard let tmux = TmuxLocator.path() else { throw XCTSkip("tmux is not installed") }
        let socket = "as-tests-\(UUID().uuidString.prefix(8))"
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("tmux-\(socket).txt")
        defer {
            _ = TmuxCommand.runExecutable(tmux, ["-L", socket, "kill-server"], timeout: 3)
            try? FileManager.default.removeItem(at: marker)
        }
        let inner = "cd \(ShellQuoting.quote(NSTemporaryDirectory())) && printf ok > \(ShellQuoting.quote(marker.path)); sleep 5"
        var command = TmuxLaunch.wrappedCommand(inner, tmuxPath: tmux, sessionName: "as-test", directory: nil)
        // Detached and on the private socket, so the test touches no real session.
        command = command.replacingOccurrences(of: "new-session", with: "-L \(socket) new-session -d")
        let out = TmuxCommand.runExecutable("/bin/sh", ["-c", command], timeout: 5)
        XCTAssertEqual(out?.status, 0, out?.stderr ?? "")

        let options = TmuxCommand.runExecutable(tmux, ["-L", socket, "show-options", "-t", "as-test", "-v", "@agent_sessions"], timeout: 3)
        XCTAssertEqual(options?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, (try? String(contentsOf: marker, encoding: .utf8)) != "ok" {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(try? String(contentsOf: marker, encoding: .utf8), "ok")
    }

    func testAttachCommandTargetsTheExactName() {
        XCTAssertEqual(TmuxLaunch.attachCommand(sessionName: "as-app", tmuxPath: "/usr/local/bin/tmux"),
                       "'/usr/local/bin/tmux' attach-session -t '=as-app'")
    }

    // MARK: Parsing

    func testParsePanes() {
        let sep = TmuxCommand.fieldSeparator
        let output = [
            ["as-app", "$1", "0", "%3", "/dev/ttys004", "123", "1", "1", "/Users/me/app", "claude", "1794536546"],
            ["mine", "$2", "1", "%7", "/dev/ttys009", "456", "0", "", "/tmp", "zsh", "1794536000"]
        ].map { $0.joined(separator: sep) }.joined(separator: "\n") + "\n"
        let panes = TmuxCommand.parsePanes(output)
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[0].paneID, "%3")
        XCTAssertEqual(panes[0].tty, "/dev/ttys004")
        XCTAssertEqual(panes[0].attachedClients, 1)
        XCTAssertTrue(panes[0].isManaged)
        XCTAssertEqual(panes[0].sessionCreated, Date(timeIntervalSince1970: 1794536546))
        XCTAssertFalse(panes[1].isManaged)
        XCTAssertEqual(panes[1].windowIndex, 1)
    }

    func testCaptureArgumentsAndParsing() {
        XCTAssertEqual(TmuxCommand.captureArguments(paneIDs: ["%1", "%2"]), [
            "display-message", "-p", "\(TmuxCommand.captureMarker)%1", ";", "capture-pane", "-p", "-t", "%1", ";",
            "display-message", "-p", "\(TmuxCommand.captureMarker)%2", ";", "capture-pane", "-p", "-t", "%2"
        ])
        let output = "\(TmuxCommand.captureMarker)%1\nline a\nline b\n\(TmuxCommand.captureMarker)%2\n> prompt\n"
        let captures = TmuxCommand.parseCaptures(output)
        XCTAssertEqual(captures["%1"], "line a\nline b")
        XCTAssertEqual(captures["%2"], "> prompt\n")
    }

    func testCaptureKeepsOnlyTheTail() {
        let long = String(repeating: "x", count: TmuxCommand.captureTailLimit + 100)
        let captures = TmuxCommand.parseCaptures("\(TmuxCommand.captureMarker)%1\n\(long)")
        XCTAssertEqual(captures["%1"]?.count, TmuxCommand.captureTailLimit)
    }

    // MARK: Live state

    func testTmuxTailDecidesTheLiveStateWithoutITerm() {
        var presence = CodexActivePresence()
        presence.source = .claude
        presence.sessionId = "s1"
        presence.pid = 42
        presence.tty = "ttys004"
        let key = CodexActiveSessionsModel.presenceKey(for: presence)
        let working = CodexActiveSessionsModel.ITermProbeResult(tail: "✻ Thinking… (esc to interrupt)", isProcessing: nil, isAtShellPrompt: nil)
        let result = CodexActiveSessionsModel.classifyLiveStates(
            for: [presence], now: Date(), probeITerm: false, previousLiveStates: [:],
            probedITermPresenceKeys: [], batchProbeResults: [:], tmuxProbeResults: [key: working])
        XCTAssertEqual(result.liveStates[key], .activeWorking)
    }

    // MARK: Claude process registry

    func testClaudeRegistryGivesTheCurrentConversation() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("claude-reg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: config) }
        let sessions = config.appendingPathComponent("sessions")
        let project = config.appendingPathComponent("projects/-Users-me-my-app")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = project.appendingPathComponent("6340905b-aaaa.jsonl")
        try Data().write(to: log)
        let entry = #"{"pid":4242,"sessionId":"6340905b-aaaa","cwd":"/Users/me/my.app","status":"busy"}"#
        try entry.write(to: sessions.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        try #"{"pid":7,"sessionId":"x","status":"idle"}"#.write(to: sessions.appendingPathComponent("8.json"), atomically: true, encoding: .utf8)

        // Given the projects folder as root, as the session scan roots are.
        let found = CodexActiveSessionsModel.claudeProcessRegistryEntry(pid: 4242, roots: [config.appendingPathComponent("projects").path])
        XCTAssertEqual(found?.sessionID, "6340905b-aaaa")
        XCTAssertEqual(found?.liveState, .activeWorking)
        XCTAssertEqual(found?.logPath, log.path)
        // A file whose pid does not match its name is ignored.
        XCTAssertNil(CodexActiveSessionsModel.claudeProcessRegistryEntry(pid: 8, roots: [config.path]))
        XCTAssertNil(CodexActiveSessionsModel.claudeProcessRegistryEntry(pid: 9, roots: [config.path]))
    }

    // MARK: Claude CLI probe

    func testClaudeHelpFromAWrapperDoesNotDisableResume() {
        let wrapper = "Usage: claude-wrapper [command | upstream args]\nRun without arguments to start Claude Code."
        XCTAssertTrue(ClaudeCLIEnvironment.flagSupport(helpText: wrapper) == (true, true))
        let claude = "  -c, --continue   Continue the most recent conversation\n  -r, --resume [value]  Resume"
        XCTAssertTrue(ClaudeCLIEnvironment.flagSupport(helpText: claude) == (true, true))
        let continueOnly = "  -c, --continue   Continue the most recent conversation"
        XCTAssertTrue(ClaudeCLIEnvironment.flagSupport(helpText: continueOnly) == (false, true))
    }
}
