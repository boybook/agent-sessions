import Foundation
import AppKit

/// Runs CLI agent sessions inside tmux (Settings → General → tmux). Off by default.
///
/// With it on, a launch types `tmux new-session …` into the user's terminal instead
/// of the bare agent command. The agent then keeps running when the terminal window
/// closes and can be reattached from anywhere (`tmux attach`, also over SSH).
/// Sessions live on the user's default tmux server and carry the `@agent_sessions`
/// session option, which is how the app tells them from the user's own.
///
/// A tmux name never encodes a conversation: `/resume` or `/branch` inside a pane
/// switches conversations without tmux knowing. The app maps pane → agent process →
/// conversation on every look-up instead; a pane's tty is its agent process's tty.
enum TmuxIntegration {
    static let enabledKey = "TmuxIntegrationEnabled"
    static let managedOption = "@agent_sessions"
    static let sessionNamePrefix = "as-"

    /// The user turned the feature on. Says nothing about tmux being installed.
    static func isRequested(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// The feature is on and tmux was found.
    static var isActive: Bool {
        guard !AppRuntime.isRunningTests, isRequested() else { return false }
        return TmuxLocator.path() != nil
    }
}

// MARK: - Locating tmux

enum TmuxLocator {
    struct Installation: Equatable, Sendable {
        let path: String
        let version: String?
    }

    /// Where package managers put tmux. Checked before asking a login shell, so the
    /// common case costs a few `stat`s.
    static let candidatePaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
        "/run/current-system/sw/bin/tmux",
        "~/.nix-profile/bin/tmux"
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: String?? = nil

    /// The tmux executable, resolved once and cached. May spawn a login shell the
    /// first time when tmux is not in a standard location.
    static func path() -> String? {
        lock.lock()
        if let cached = cache {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let found = resolve()
        lock.lock()
        cache = .some(found)
        lock.unlock()
        return found
    }

    /// Forgets the cached result and looks again (after the user installs tmux).
    @discardableResult
    static func refresh() -> Installation? {
        lock.lock()
        cache = nil
        lock.unlock()
        guard let path = path() else { return nil }
        return Installation(path: path, version: version(at: path))
    }

    static func installation() -> Installation? {
        guard let path = path() else { return nil }
        return Installation(path: path, version: version(at: path))
    }

    static func version(at path: String) -> String? {
        guard let out = TmuxCommand.runExecutable(path, ["-V"], timeout: 3), out.status == 0 else { return nil }
        let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Homebrew, for the install guide.
    static func homebrewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static func resolve() -> String? {
        for candidate in candidatePaths {
            let expanded = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let out = TmuxCommand.runExecutable(shell, ["-lc", "command -v tmux"], timeout: 5),
              out.status == 0 else { return nil }
        let path = out.stdout.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}

// MARK: - Panes and clients

struct TmuxPane: Equatable, Sendable, Identifiable {
    let sessionName: String
    let sessionID: String
    let windowIndex: Int
    let paneID: String
    let tty: String
    let panePID: Int
    /// Clients (terminals) currently showing this pane's session.
    let attachedClients: Int
    /// Started by Agent Sessions (carries `@agent_sessions`).
    let isManaged: Bool
    let currentPath: String
    let currentCommand: String
    let sessionCreated: Date?

    var id: String { paneID }
}

struct TmuxClient: Equatable, Sendable {
    let tty: String
    let sessionName: String
    let pid: Int
}

enum TmuxCommand {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static let fieldSeparator = "\u{1F}"
    static let captureMarker = "@@AGENT_SESSIONS_PANE@@"
    /// The iTerm tail probe keeps this much text; tmux captures match it.
    static let captureTailLimit = 4000

    static let listPanesFormat = [
        "#{session_name}", "#{session_id}", "#{window_index}", "#{pane_id}", "#{pane_tty}",
        "#{pane_pid}", "#{session_attached}", "#{\(TmuxIntegration.managedOption)}",
        "#{pane_current_path}", "#{pane_current_command}", "#{session_created}"
    ].joined(separator: fieldSeparator)

    static var listPanesArguments: [String] { ["list-panes", "-a", "-F", listPanesFormat] }

    static func parsePanes(_ output: String) -> [TmuxPane] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.components(separatedBy: fieldSeparator)
            guard f.count >= 11, !f[3].isEmpty else { return nil }
            return TmuxPane(
                sessionName: f[0],
                sessionID: f[1],
                windowIndex: Int(f[2]) ?? 0,
                paneID: f[3],
                tty: f[4],
                panePID: Int(f[5]) ?? 0,
                attachedClients: Int(f[6]) ?? 0,
                isManaged: !f[7].isEmpty && f[7] != "0",
                currentPath: f[8],
                currentCommand: f[9],
                sessionCreated: TimeInterval(f[10]).map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    static func parseClients(_ output: String) -> [TmuxClient] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.components(separatedBy: fieldSeparator)
            guard f.count >= 3, !f[0].isEmpty else { return nil }
            return TmuxClient(tty: f[0], sessionName: f[1], pid: Int(f[2]) ?? 0)
        }
    }

    /// One tmux invocation that prints each pane after a marker line. tmux stops at
    /// the first pane that no longer exists, so the result may be partial.
    static func captureArguments(paneIDs: [String]) -> [String] {
        var args: [String] = []
        for (index, paneID) in paneIDs.enumerated() {
            if index > 0 { args.append(";") }
            args += ["display-message", "-p", "\(captureMarker)\(paneID)", ";",
                     "capture-pane", "-p", "-t", paneID]
        }
        return args
    }

    static func parseCaptures(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentPane: String?
        var lines: [Substring] = []
        func flush() {
            guard let pane = currentPane else { return }
            let text = lines.joined(separator: "\n")
            result[pane] = String(text.suffix(captureTailLimit))
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(captureMarker) {
                flush()
                currentPane = String(line.dropFirst(captureMarker.count))
                lines = []
            } else {
                lines.append(line)
            }
        }
        flush()
        return result
    }

    static func listPanes() -> [TmuxPane] {
        guard let out = run(listPanesArguments), out.status == 0 else { return [] }
        return parsePanes(out.stdout)
    }

    static func listClients() -> [TmuxClient] {
        let format = ["#{client_tty}", "#{session_name}", "#{client_pid}"].joined(separator: fieldSeparator)
        guard let out = run(["list-clients", "-F", format]), out.status == 0 else { return [] }
        return parseClients(out.stdout)
    }

    static func sessionNames() -> Set<String> {
        guard let out = run(["list-sessions", "-F", "#{session_name}"]), out.status == 0 else { return [] }
        return Set(out.stdout.split(whereSeparator: \.isNewline).map(String.init))
    }

    static func pane(forTTY tty: String) -> TmuxPane? {
        guard let wanted = normalizedTTY(tty) else { return nil }
        return listPanes().first { normalizedTTY($0.tty) == wanted }
    }

    @discardableResult
    static func killSession(_ name: String) -> Bool {
        run(["kill-session", "-t", exactTarget(name)])?.status == 0
    }

    @discardableResult
    static func selectPane(_ paneID: String) -> Bool {
        run(["select-window", "-t", paneID, ";", "select-pane", "-t", paneID])?.status == 0
    }

    /// `=name` matches the session name exactly instead of by prefix.
    static func exactTarget(_ sessionName: String) -> String { "=\(sessionName)" }

    static func normalizedTTY(_ raw: String?) -> String? {
        CodexActiveSessionsModel.normalizedTTY(raw)
    }

    static func run(_ arguments: [String], timeout: TimeInterval = 3) -> Output? {
        guard let path = TmuxLocator.path() else { return nil }
        return runExecutable(path, arguments, timeout: timeout)
    }

    /// Runs a short-lived command with a hard timeout. Talks to the default tmux
    /// server even when Agent Sessions itself was started from inside tmux.
    static func runExecutable(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        process.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let killer = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let errData = TmuxLockedBox<Data>(Data())
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errData.store(errPipe.fileHandleForReading.readDataToEndOfFile())
            errGroup.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errGroup.wait()
        process.waitUntilExit()
        killer.cancel()
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData.load(), as: UTF8.self))
    }
}

/// Minimal lock-protected box for handing a value across threads.
private final class TmuxLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func store(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func load() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Launching inside tmux

enum TmuxLaunch {
    /// The shell command the terminal runs when tmux is on; `shellCommand` unchanged
    /// otherwise. `cwd` is the launch folder when the command does not start with
    /// `cd '<folder>' &&` (Ghostty and Warp get the folder separately).
    @MainActor
    static func wrapIfEnabled(_ shellCommand: String, cwd: String?) -> String {
        guard TmuxIntegration.isActive, let tmux = TmuxLocator.path() else { return shellCommand }
        let directory = cwd ?? leadingDirectory(of: shellCommand)
        let name = sessionName(for: directory, existing: TmuxCommand.sessionNames())
        return wrappedCommand(shellCommand, tmuxPath: tmux, sessionName: name, directory: directory)
    }

    /// `tmux new-session` running `shellCommand` in a new session marked as ours.
    ///
    /// The agent runs under `/bin/sh -c` with the terminal shell's PATH (`-e` is
    /// expanded by that shell), so it finds the same CLI a plain launch would, even
    /// when the tmux server was started from an older environment. When the command
    /// fails, the pane waits for Return so its error stays readable.
    static func wrappedCommand(_ shellCommand: String, tmuxPath: String, sessionName: String, directory: String?) -> String {
        let exitedPrefix = String(localized: "The command exited with status",
                                  comment: "Printed in the terminal when an agent run inside tmux fails; followed by the exit status number.")
        let pressReturn = String(localized: "Press Return to close.",
                                 comment: "Printed in the terminal after a failed agent run inside tmux.")
        let script = """
        \(shellCommand)
        status=$?
        if [ "$status" -ne 0 ] && [ "$status" -ne 130 ]; then printf '\\n[Agent Sessions] %s %s\\n%s\\n' \(ShellQuoting.quote(exitedPrefix)) "$status" \(ShellQuoting.quote(pressReturn)); read _; fi
        """
        var parts = [ShellQuoting.quote(tmuxPath), "new-session", "-s", ShellQuoting.quote(sessionName)]
        if let directory, !directory.isEmpty {
            parts += ["-c", ShellQuoting.quote(directory)]
        }
        parts += ["-e", "\"PATH=$PATH\"", "/bin/sh", "-c", ShellQuoting.quote(script),
                  "\\;", "set-option", "-q", TmuxIntegration.managedOption, "1"]
        return parts.joined(separator: " ")
    }

    /// `as-<folder>`, then `as-<folder>-2`, … — readable in `tmux ls` and over SSH.
    static func sessionName(for directory: String?, existing: Set<String>) -> String {
        let folder = directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        var base = TmuxIntegration.sessionNamePrefix + sanitize(folder.isEmpty ? "session" : folder)
        if base.count > 40 { base = String(base.prefix(40)) }
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    /// tmux reserves `.` and `:` in targets; whitespace makes names awkward to type.
    static func sanitize(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { scalar -> Character in
            if scalar == "." || scalar == ":" || CharacterSet.whitespacesAndNewlines.contains(scalar) { return "_" }
            return Character(scalar)
        }
        return String(mapped)
    }

    /// The folder in a `cd '<folder>' && …` command, as every resume and new-session
    /// builder writes it (single-quoted with `ShellQuoting.quote`).
    static func leadingDirectory(of shellCommand: String) -> String? {
        guard shellCommand.hasPrefix("cd '") else { return nil }
        var result = ""
        var index = shellCommand.index(shellCommand.startIndex, offsetBy: 4)
        while index < shellCommand.endIndex {
            let char = shellCommand[index]
            if char == "'" {
                let rest = shellCommand[index...]
                if rest.hasPrefix("'\\''") {
                    result.append("'")
                    index = shellCommand.index(index, offsetBy: 4)
                    continue
                }
                return rest.dropFirst().hasPrefix(" &&") ? result : nil
            }
            result.append(char)
            index = shellCommand.index(after: index)
        }
        return nil
    }

    /// Command that attaches a terminal to an existing session.
    static func attachCommand(sessionName: String, tmuxPath: String) -> String {
        [ShellQuoting.quote(tmuxPath), "attach-session", "-t", ShellQuoting.quote(TmuxCommand.exactTarget(sessionName))]
            .joined(separator: " ")
    }
}

// MARK: - Bringing a pane forward

@MainActor
enum TmuxFocus {
    /// Shows `pane`: selects its window and pane, then brings forward a terminal
    /// already showing its session, or opens a new terminal tab attached to it.
    static func show(_ pane: TmuxPane) async throws {
        let clients = await Task.detached(priority: .userInitiated) { () -> [TmuxClient] in
            TmuxCommand.selectPane(pane.paneID)
            return TmuxCommand.listClients().filter { $0.sessionName == pane.sessionName }
        }.value
        for client in clients {
            if await focusTerminal(showingTTY: client.tty, clientPID: client.pid) { return }
        }
        guard let tmux = TmuxLocator.path() else { return }
        try await AgentTerminalLauncher.launchInPreferredTerminal(
            shellCommand: TmuxLaunch.attachCommand(sessionName: pane.sessionName, tmuxPath: tmux),
            cwd: pane.currentPath.isEmpty ? nil : pane.currentPath,
            wrapInTmux: false
        )
    }

    /// Looks up the pane running on `tty` (an agent process's terminal) and shows it.
    /// Returns false when that tty is not a tmux pane.
    static func showPane(forTTY tty: String) async -> Bool {
        let pane = await Task.detached(priority: .userInitiated) { TmuxCommand.pane(forTTY: tty) }.value
        guard let pane else { return false }
        do {
            try await show(pane)
        } catch {
            NSSound.beep()
        }
        return true
    }

    /// Terminal.app and iTerm2 select a tab by tty. Other terminals cannot, so the
    /// app owning the tmux client is brought forward as is.
    private static func focusTerminal(showingTTY tty: String, clientPID: Int) async -> Bool {
        if isRunning("com.apple.Terminal"), await focusTerminalApp(tty: tty) { return true }
        if isRunning("com.googlecode.iterm2") {
            let focused = await Task.detached {
                CodexActiveSessionsModel.tryFocusITerm2(itermSessionId: nil, tty: tty)
            }.value
            if focused { return true }
        }
        let app = await Task.detached { owningApplicationPID(of: clientPID) }.value
        if let app, let running = NSRunningApplication(processIdentifier: pid_t(app)) {
            return running.activate()
        }
        return false
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func focusTerminalApp(tty: String) async -> Bool {
        let script = [
            "on run argv",
            "set targetTTY to item 1 of argv",
            "tell application \"Terminal\"",
            "repeat with w in windows",
            "repeat with t in tabs of w",
            "if tty of t is targetTTY then",
            "set selected tab of w to t",
            "set index of w to 1",
            "activate",
            "return \"ok\"",
            "end if",
            "end repeat",
            "end repeat",
            "end tell",
            "return \"no\"",
            "end run"
        ]
        let arguments = script.flatMap { ["-e", $0] } + [tty]
        let out = await Task.detached {
            TmuxCommand.runExecutable("/usr/bin/osascript", arguments, timeout: 5)
        }.value
        return out?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    /// Walks up from the tmux client process to the first regular GUI app.
    nonisolated static func owningApplicationPID(of pid: Int) -> Int? {
        guard pid > 0, let out = TmuxCommand.runExecutable("/bin/ps", ["-A", "-o", "pid=,ppid="], timeout: 3) else { return nil }
        var parent: [Int: Int] = [:]
        for line in out.stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, let child = Int(fields[0]), let up = Int(fields[1]) else { continue }
            parent[child] = up
        }
        var current = pid
        for _ in 0..<32 {
            guard let up = parent[current], up > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: pid_t(up)), app.activationPolicy == .regular {
                return up
            }
            current = up
        }
        return nil
    }
}
