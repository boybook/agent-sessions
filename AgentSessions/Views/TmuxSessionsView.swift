import SwiftUI
import AppKit

// MARK: - Management window (View → tmux Sessions)

/// Every tmux session Agent Sessions started, plus any other tmux session with a
/// live agent in it. Each row shows the conversation running there *now*, read
/// from the agent process, so it follows /resume and /branch inside the pane.
struct TmuxSessionsView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    @Environment(CodexActiveSessionsModel.self) private var activeSessions
    @AppStorage(TmuxIntegration.enabledKey) private var enabled = false

    @State private var panes: [TmuxPane] = []
    @State private var tmuxFound: Bool?
    @State private var selection: TmuxSessionRow.ID?
    @State private var pendingClose: [TmuxSessionRow] = []
    @State private var consumerID = UUID()

    var body: some View {
        Group {
            if tmuxFound == false || !enabled {
                Form { TmuxPreferencesSection(showsManageButton: false) }
                    .formStyle(.grouped)
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label("No tmux Sessions", systemImage: "terminal")
                } description: {
                    Text("Resume a session or start a new one to run it in tmux.")
                }
            } else {
                table
            }
        }
        .frame(minWidth: 620, minHeight: 280)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    pendingClose = idleDetachedRows
                } label: {
                    Label("Close Idle Sessions", systemImage: "xmark.circle")
                }
                .help("Close tmux sessions started by Agent Sessions that no terminal shows and whose agent is idle or gone")
                .disabled(idleDetachedRows.isEmpty)

                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        .alert(closeAlertTitle, isPresented: Binding(
            get: { !pendingClose.isEmpty },
            set: { if !$0 { pendingClose = [] } }
        )) {
            Button("Close", role: .destructive) {
                let names = pendingClose.map(\.name)
                pendingClose = []
                Task {
                    await Task.detached { names.forEach { TmuxCommand.killSession($0) } }.value
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) { pendingClose = [] }
        } message: {
            Text("Any agent still running in it stops.")
        }
        .task(id: enabled) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .onAppear { activeSessions.setUnifiedConsumerVisible(true, consumerID: consumerID) }
        .onDisappear { activeSessions.setUnifiedConsumerVisible(false, consumerID: consumerID) }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("tmux Session") { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 12, design: .monospaced))
                    if !row.isManaged {
                        Text("Other")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Not started by Agent Sessions")
                    }
                }
            }
            .width(min: 120, ideal: 150)
            TableColumn("Running") { row in
                if let agent = row.agents.first {
                    HStack(spacing: 6) {
                        Text(agent.source.descriptor.shortLabel)
                            .foregroundStyle(.secondary)
                        Text(agent.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(agent.title)
                } else {
                    Text(row.command.isEmpty ? "—" : row.command)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("Folder") { row in
                Text(row.folderName)
                    .lineLimit(1)
                    .help(row.folder)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Status") { row in
                HStack(spacing: 6) {
                    if let state = row.agents.first?.state {
                        Circle()
                            .fill(state == .activeWorking ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(state == .activeWorking ? "Working" : "Idle")
                    }
                    Text(row.attachedClients > 0 ? "Attached" : "Detached")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: TmuxSessionRow.ID.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                Button("Show in Terminal") { show(row) }
                Button("Copy Attach Command") { copyAttachCommand(row) }
                Divider()
                Button("Close Session…", role: .destructive) { pendingClose = [row] }
            }
        } primaryAction: { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) { show(row) }
        }
    }

    // MARK: Rows

    private var rows: [TmuxSessionRow] {
        let presenceByTTY = Dictionary(
            activeSessions.presences.compactMap { presence -> (String, CodexActivePresence)? in
                guard let tty = TmuxCommand.normalizedTTY(presence.tty) else { return nil }
                return (tty, presence)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // The same join keys the live dots in the main list use.
        var sessionsByPath: [String: Session] = [:]
        var sessionsByID: [String: Session] = [:]
        for session in unified.allSessions where activeSessions.supportsLiveSessions(for: session.source) {
            sessionsByPath[CodexActiveSessionsModel.normalizePath(session.filePath)] = session
            for id in CodexActiveSessionsModel.liveSessionIDCandidates(for: session) {
                sessionsByID["\(session.source.rawValue):\(id)"] = session
            }
        }

        let grouped = Dictionary(grouping: panes, by: \.sessionName)
        return grouped.compactMap { name, sessionPanes -> TmuxSessionRow? in
            let agents: [TmuxSessionRow.Agent] = sessionPanes.compactMap { pane in
                guard let tty = TmuxCommand.normalizedTTY(pane.tty), let presence = presenceByTTY[tty] else { return nil }
                let session = presence.sessionLogPath.flatMap { sessionsByPath[CodexActiveSessionsModel.normalizePath($0)] }
                    ?? presence.sessionId.flatMap { sessionsByID["\(presence.source.rawValue):\($0)"] }
                let title = session?.listTitle
                    ?? String(localized: "Untitled session", comment: "tmux Sessions window: a running agent whose conversation has no title yet")
                return TmuxSessionRow.Agent(pane: pane, source: presence.source, title: title,
                                            state: activeSessions.liveState(for: presence))
            }
            let first = sessionPanes[0]
            let managed = sessionPanes.contains(where: \.isManaged)
            guard managed || !agents.isEmpty else { return nil }
            return TmuxSessionRow(name: name,
                                  isManaged: managed,
                                  attachedClients: first.attachedClients,
                                  created: first.sessionCreated,
                                  folder: (agents.first?.pane ?? first).currentPath,
                                  command: first.currentCommand,
                                  panes: sessionPanes,
                                  agents: agents)
        }
        .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    private var idleDetachedRows: [TmuxSessionRow] {
        rows.filter { row in
            row.isManaged && row.attachedClients == 0 && row.agents.allSatisfy { $0.state != .activeWorking }
        }
    }

    private var closeAlertTitle: String {
        if pendingClose.count == 1, let row = pendingClose.first {
            return String(localized: "Close tmux session “\(row.name)”?",
                          comment: "Confirmation title before ending one tmux session")
        }
        return String(localized: "Close \(pendingClose.count) tmux sessions?",
                      comment: "Confirmation title before ending several tmux sessions")
    }

    private func refresh() async {
        let result = await Task.detached(priority: .utility) { () -> ([TmuxPane], Bool) in
            guard TmuxLocator.path() != nil else { return ([], false) }
            return (TmuxCommand.listPanes(), true)
        }.value
        panes = result.0
        tmuxFound = result.1
    }

    private func show(_ row: TmuxSessionRow) {
        guard let pane = row.agents.first?.pane ?? row.panes.first else { return }
        Task { @MainActor in
            do {
                try await TmuxFocus.show(pane)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func copyAttachCommand(_ row: TmuxSessionRow) {
        let command = "tmux attach -t \(ShellQuoting.quoteIfNeeded(TmuxCommand.exactTarget(row.name)))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

struct TmuxSessionRow: Identifiable {
    struct Agent {
        let pane: TmuxPane
        let source: SessionSource
        let title: String
        let state: CodexLiveState
    }

    let name: String
    let isManaged: Bool
    let attachedClients: Int
    let created: Date?
    let folder: String
    let command: String
    let panes: [TmuxPane]
    let agents: [Agent]

    var id: String { name }
    var folderName: String { folder.isEmpty ? "—" : URL(fileURLWithPath: folder).lastPathComponent }
}

// MARK: - Settings → General

/// The tmux switch, its status, how to install tmux when it is missing, and what
/// the feature does. Each item is its own Form row so Settings lays it out natively.
struct TmuxPreferencesSection: View {
    var showsManageButton = true

    @AppStorage(TmuxIntegration.enabledKey) private var enabled = false
    @State private var installation: TmuxLocator.Installation?
    @State private var checked = false
    @State private var checking = false
    @State private var homebrew: String?

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Text("Run CLI Sessions in tmux")
                Text("Resume and New Session start agents inside tmux, so they keep running after the terminal window closes.")
            }
            .disabled(checked && installation == nil && !enabled)

            if checked {
                if let installation {
                    LabeledContent("tmux") {
                        Text(installation.version ?? installation.path)
                            .foregroundStyle(.secondary)
                            .help(installation.path)
                    }
                } else {
                    installGuide
                }
            }

            if showsManageButton, enabled, installation != nil {
                LabeledContent {
                    Button("Manage tmux Sessions…") { Self.openManagementWindow() }
                } label: {
                    Text("tmux Sessions")
                }
            }

            DisclosureGroup("How it works") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("tmux keeps terminal programs running in the background, independent of any terminal window.")
                    bullet("Each CLI session Agent Sessions starts gets its own tmux session, named “as-” plus the project folder. Closing the terminal window only detaches it; the agent keeps working.")
                    bullet("Resume on a session that is already running brings its tmux pane back instead of starting a second copy. Agent Sessions follows /resume and /branch inside the pane.")
                    bullet("From any terminal, including over SSH, “tmux attach -t <name>” reattaches and “tmux ls” lists sessions. Inside tmux, press Control-B then D to detach.")
                    bullet("Agent Sessions reads the tmux screen to show whether an agent is working or idle, in any terminal app.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        } header: {
            Text("tmux")
        }
        .task { await check() }
    }

    @ViewBuilder
    private var installGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(enabled ? "tmux was not found. Sessions open without tmux until it is installed."
                          : "tmux is not installed on this Mac.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if let homebrew {
                Text("Install it with Homebrew:")
                    .font(.callout)
                Text(verbatim: "brew install tmux")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                HStack {
                    Button("Install in Terminal") {
                        Task {
                            try? await AgentTerminalLauncher.launchInPreferredTerminal(
                                shellCommand: "\(ShellQuoting.quote(homebrew)) install tmux",
                                cwd: nil, wrapInTmux: false)
                        }
                    }
                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install tmux", forType: .string)
                    }
                    Spacer()
                    checkAgainButton
                }
            } else {
                Text("Install Homebrew first, then run “brew install tmux” in Terminal. MacPorts users can run “sudo port install tmux”.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link("Homebrew", destination: URL(string: "https://brew.sh")!)
                    Link("Installing tmux", destination: URL(string: "https://github.com/tmux/tmux/wiki/Installing")!)
                    Spacer()
                    checkAgainButton
                }
            }
        }
    }

    private var checkAgainButton: some View {
        Button(checking ? "Checking…" : "Check Again") { Task { await check(refresh: true) } }
            .disabled(checking)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func check(refresh: Bool = false) async {
        checking = true
        let result = await Task.detached(priority: .userInitiated) { () -> (TmuxLocator.Installation?, String?) in
            let found = refresh ? TmuxLocator.refresh() : TmuxLocator.installation()
            return (found, TmuxLocator.homebrewPath())
        }.value
        installation = result.0
        homebrew = result.1
        checked = true
        checking = false
    }

    /// The window lives in the app's SwiftUI scenes; Settings is an AppKit window,
    /// so the main window opens it on our behalf.
    @MainActor
    static func openManagementWindow() {
        if AppWindowRouter.isAgentSessionsWindowVisible {
            NotificationCenter.default.post(name: .showTmuxSessionsWindow, object: nil)
        } else {
            AppWindowRouter.showAgentSessionsWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .showTmuxSessionsWindow, object: nil)
            }
        }
    }
}
