import Foundation
import AppKit

/// Starts a NEW agent session: opens the user's terminal (Settings → General →
/// Terminal App) in a project directory and runs the agent CLI with no session id.
///
/// Binary lookup reuses each agent's own resolver (custom path, else the probed
/// install), exactly as Resume does, so a new session runs the same CLI a resumed
/// one would. Three agents need more than the bare binary:
/// - Cursor: a `cursor` binary takes the `agent` subcommand;
/// - Pi: a configured sessions root is passed as `--session-dir`;
/// - Qwen: a configured storage root is passed as `QWEN_HOME`/`QWEN_RUNTIME_DIR`.
/// Without the last two, the new session would be written where Agent Sessions
/// does not look.
@MainActor
enum NewSessionLauncher {
    /// The stored default-agent choice: `automatic` or a `SessionSource` raw value.
    static let automatic = "auto"

    struct LaunchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Agents that can start a session from a terminal and are turned on, in registry order.
    static var availableSources: [SessionSource] {
        SessionSourceRegistry.ordered
            .map(\.descriptor.source)
            .filter { $0.descriptor.supportsResume && AgentEnablement.isEnabled($0) }
    }

    /// The agent a plain click uses. A fixed default wins while it is available;
    /// otherwise (Automatic) the agent of the project's most recent session, then
    /// the first available agent.
    static func defaultSource(projectLatest: SessionSource?,
                              available: [SessionSource]? = nil,
                              defaults: UserDefaults = .standard) -> SessionSource? {
        let available = available ?? availableSources
        let raw = defaults.string(forKey: PreferencesKey.NewSession.defaultAgent) ?? automatic
        if raw != automatic, let fixed = SessionSource(rawValue: raw), available.contains(fixed) {
            return fixed
        }
        if let latest = projectLatest, available.contains(latest) { return latest }
        return available.first
    }

    /// Opens the configured terminal in `directory` running a new `source` session,
    /// then remembers it so the list can select the session once its file appears.
    static func launch(_ source: SessionSource, in directory: URL) async throws {
        let customPath = customBinaryPath(for: source)
        let resolved = await Task.detached(priority: .userInitiated) {
            resolveBinary(for: source, customPath: customPath)
        }.value
        guard let binary = resolved else {
            throw LaunchError(message: String(
                localized: "\(source.displayName) CLI was not found. Set its path in Settings.",
                comment: "Error when starting a new session: the agent's command-line tool is missing. The argument is the agent name."))
        }

        let core = coreCommand(for: source, binary: binary)
        let shellCommand = "cd \(ShellQuoting.quote(directory.path)) && \(core)"
        switch ResumePreferenceHelpers.resolveTerminalKind() {
        case .iterm2:
            try AgentTerminalLauncher.launchInITerm(shellCommand: shellCommand, domain: "NewSessionLauncher")
        case .ghostty:
            try await AgentTerminalLauncher.launchInGhostty(shellCommand: core, cwd: directory.path, domain: "NewSessionLauncher")
        case .warp:
            try await AgentTerminalLauncher.launchInWarp(shellCommand: core, cwd: directory.path, kind: .warp)
        case .warpPreview:
            try await AgentTerminalLauncher.launchInWarp(shellCommand: core, cwd: directory.path, kind: .warpPreview)
        case .terminalApp, .unknown:
            try AgentTerminalLauncher.launchInTerminal(shellCommand: shellCommand, domain: "NewSessionLauncher")
        }
        NewSessionTracker.shared.started(source: source, directory: directory)
    }

    /// Lets the user pick any folder; nil when cancelled.
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "New Session", comment: "Open-panel button that starts a new agent session in the chosen folder.")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could Not Start a New Session", comment: "Alert title when launching a new agent session fails.")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - Command

    private static func customBinaryPath(for source: SessionSource) -> String? {
        let raw: String
        switch source {
        case .codex: raw = CodexResumeSettings.shared.binaryOverride
        case .claude: raw = ClaudeResumeSettings.shared.binaryPath
        case .antigravity: raw = AntigravityCLISettings.shared.binaryOverride
        case .opencode: raw = OpenCodeSettings.shared.binaryPath
        case .hermes: raw = HermesSettings.shared.binaryPath
        case .copilot: raw = CopilotSettings.shared.binaryPath
        case .cursor: raw = CursorSettings.shared.binaryPath
        case .pi: raw = PiSettings.shared.binaryPath
        case .kimi: raw = KimiSettings.shared.binaryPath
        case .grok: raw = GrokSettings.shared.binaryPath
        case .qwen: raw = QwenSettings.shared.binaryPath
        case .devin: raw = DevinSettings.shared.binaryPath
        case .fx: raw = FxSettings.shared.binaryPath
        case .droid, .openclaw, .cline, .deepseekHarness: raw = ""
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The resolvers spawn processes and stat the file system, so this runs off-main.
    nonisolated private static func resolveBinary(for source: SessionSource, customPath: String?) -> URL? {
        switch source {
        case .codex: return CodexCLIEnvironment().resolveBinary(customPath: customPath)
        case .claude: return ClaudeCLIEnvironment().resolveBinary(customPath: customPath)
        case .antigravity:
            // Probe, not a name lookup: a bare `agy` can be the desktop app's launcher.
            if case .success(let result) = AntigravityCLIEnvironment().probe(customPath: customPath) {
                return result.binaryURL
            }
            return nil
        case .opencode: return OpenCodeCLIEnvironment().resolveBinary(customPath: customPath)
        case .hermes: return HermesCLIEnvironment().resolveBinary(customPath: customPath)
        case .copilot: return CopilotCLIEnvironment().resolveBinary(customPath: customPath)
        case .cursor: return CursorCLIEnvironment().resolveBinary(customPath: customPath)
        case .pi: return PiCLIEnvironment().resolveBinary(customPath: customPath)
        case .kimi: return KimiCLIEnvironment().resolveBinary(customPath: customPath)
        case .grok: return GrokCLIEnvironment().resolveBinary(customPath: customPath)
        case .qwen: return QwenCLIEnvironment().resolveBinary(customPath: customPath)
        case .devin: return DevinCLIEnvironment().resolveBinary(customPath: customPath)
        case .fx: return FxCLIEnvironment().resolveBinary(customPath: customPath)
        case .droid, .openclaw, .cline, .deepseekHarness: return nil
        }
    }

    static func coreCommand(for source: SessionSource, binary: URL) -> String {
        var command = ShellQuoting.quote(binary.path)
        switch source {
        case .cursor where binary.lastPathComponent == "cursor":
            command += " agent"
        case .pi:
            if let dir = piSessionDirectory() {
                command += " --session-dir \(ShellQuoting.quote(dir.path))"
            }
        case .qwen:
            switch QwenResumeEligibility.configuredStorageContext().environmentOverride {
            case .qwenHome(let dir)?:
                command = "QWEN_HOME=\(ShellQuoting.quote(dir.path)) \(command)"
            case .runtimeDirectory(let dir)?:
                command = "QWEN_RUNTIME_DIR=\(ShellQuoting.quote(dir.path)) \(command)"
            case nil:
                break
            }
        default:
            break
        }
        return command
    }

    /// Mirrors `PiSettings.configuredSessionDirectory()`, which resume uses.
    private static func piSessionDirectory(defaults: UserDefaults = .standard) -> URL? {
        let raw = defaults.string(forKey: PreferencesKey.Paths.piSessionsRootOverride)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return PiSessionDiscovery(customRoot: (raw as NSString).expandingTildeInPath).sessionsRoot()
    }
}

/// Remembers the most recent new session until its transcript shows up in the list,
/// so the list can select it. One at a time; a launch nobody picks up expires.
@MainActor
final class NewSessionTracker {
    static let shared = NewSessionTracker()

    struct Pending {
        let source: SessionSource
        let directory: String
        let launchedAt: Date
    }

    private(set) var pending: Pending?
    /// Some CLIs write their transcript only after the first prompt, so wait a while.
    private let lifetime: TimeInterval = 30 * 60

    func started(source: SessionSource, directory: URL) {
        pending = Pending(source: source,
                          directory: directory.standardizedFileURL.resolvingSymlinksInPath().path,
                          launchedAt: Date())
    }

    /// The first row that is the pending session, consuming the pending launch.
    /// O(rows) and only while a launch is pending.
    func claim(in rows: [Session]) -> Session? {
        guard let pending else { return nil }
        guard Date().timeIntervalSince(pending.launchedAt) < lifetime else {
            self.pending = nil
            return nil
        }
        let earliest = pending.launchedAt.addingTimeInterval(-5)
        let match = rows.first { row in
            guard row.source == pending.source, (row.startTime ?? row.modifiedAt) >= earliest else { return false }
            if row.rowProjectIdentity?.canonicalRootPath == pending.directory { return true }
            guard let cwd = row.cwd, !cwd.isEmpty else { return false }
            let path = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
            return path == pending.directory || path.hasPrefix(pending.directory + "/")
        }
        if match != nil { self.pending = nil }
        return match
    }
}
