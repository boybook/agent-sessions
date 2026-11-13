import SwiftUI
import CoreServices

extension PreferencesView {

    var generalTab: some View {
        PreferencesForm {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { indexer.appAppearance },
                    set: { indexer.setAppearance($0) }
                )) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .help("Choose the overall app appearance")
            }

            Section {
                // Terminal app preference for both Codex and Claude resumes
                Picker(selection: Binding(
                    get: {
                        let kind = ResumePreferenceHelpers.resolveTerminalKind()
                        if detectedTerminals.contains(where: { $0.kind == kind }) {
                            return kind
                        }
                        return detectedTerminals.first?.kind ?? .terminalApp
                    },
                    set: { kind in
                        ResumePreferenceHelpers.setTerminalKind(kind)
                        let preferITerm = (kind == .iterm2)
                        let codexMode: CodexLaunchMode
                        switch kind {
                        case .iterm2:      codexMode = .iterm
                        case .warp:        codexMode = .warp
                        case .warpPreview: codexMode = .warpPreview
                        case .ghostty:     codexMode = .ghostty
                        default:           codexMode = .terminal
                        }
                        resumeSettings.setLaunchMode(codexMode)
                        claudeSettings.setPreferITerm(preferITerm)
                        opencodeSettings.setPreferITerm(preferITerm)
                        copilotSettings.setPreferITerm(preferITerm)
                        antigravitySettings.setPreferITerm(preferITerm)
                        cursorSettings.setPreferITerm(preferITerm)
                        piSettings.setPreferITerm(preferITerm)
                    }
                )) {
                    ForEach(detectedTerminals) { terminal in
                        Text(terminal.displayName).tag(terminal.kind)
                    }
                } label: {
                    Text("Terminal App")
                    Text("Affects Resume actions in the Sessions window for all CLI agents.")
                }
                .help("Choose which terminal application handles Resume for all CLI agents")
            } header: {
                Text("Resume")
            }

            TmuxPreferencesSection()

            Section {
                Picker(selection: $newSessionDefaultAgent) {
                    Text("Automatic").tag(NewSessionLauncher.automatic)
                    Divider()
                    ForEach(NewSessionLauncher.availableSources, id: \.self) { source in
                        Text(source.displayName).tag(source.rawValue)
                    }
                } label: {
                    Text("Default Agent")
                    Text("Automatic uses the agent of the project's most recent session.")
                }
                .help("The agent a new session starts with. Right-click a project, or use the toolbar menu, to pick another one.")
            } header: {
                Text("New Sessions")
            } footer: {
                Text("New sessions open in the Terminal App above, in the project's root folder.")
            }

            Section {
                // One row per registry entry, in registry order. The row label is the
                // descriptor's `shortLabel` ("Codex", "Copilot", "Kimi Code", …) and the
                // toggle binding comes from `agentEnablementBinding(for:)`'s exhaustive switch.
                let enabledCount = SessionSource.allCases.filter { agentEnablementBinding(for: $0).wrappedValue }.count

                ForEach(SessionSourceRegistry.ordered, id: \.descriptor.source) { adapter in
                    agentEnableToggle(title: adapter.descriptor.shortLabel,
                                      source: adapter.descriptor.source,
                                      isOn: agentEnablementBinding(for: adapter.descriptor.source),
                                      enabledCount: enabledCount)
                }
            } header: {
                Text("Active CLI agents")
            } footer: {
                Text("Disabled agents are hidden across the app and background work is paused.")
            }
        }
        .onAppear {
            if detectedTerminals.isEmpty {
                Task.detached {
                    let terminals = detectInstalledTerminals()
                    await MainActor.run {
                        detectedTerminals = terminals
                    }
                }
            }
        }
    }

    var agentCockpitTab: some View {
        PreferencesForm {
            Section {
                // The same show/hide as View → Quota Meter. Hiding is always allowed;
                // showing needs live session detection, which feeds the meter.
                Toggle(isOn: Binding(
                    get: { quotaMeterVisibility.isVisible },
                    set: { shouldShow in
                        QuotaMeterPresentationCoordinator.shared.setQuotaMeterVisible(shouldShow)
                        quotaMeterVisibility.refresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { quotaMeterVisibility.refresh() }
                    }
                )) {
                    Text("Show Quota Meter")
                    if !codexActiveSessionsEnabled {
                        Text("Enable live session detection (Beta) in Settings → Quota Meter.")
                    }
                }
                .disabled(!codexActiveSessionsEnabled && !quotaMeterVisibility.isVisible)
                .help("Show or hide the Quota Meter.")
            }

            Section("Appearance") {
                Toggle(isOn: $cockpitReduceTransparency) {
                    Text("Reduce transparency")
                    Text("Also respects macOS System Settings > Accessibility > Display > Reduce transparency.")
                }
                .help("Uses a denser window background for better readability over dark or busy wallpapers.")
            }

            Section {
                Toggle("Enable live session detection (Beta)", isOn: $codexActiveSessionsEnabled)
                    .help("Beta feature. Tracks live/open Codex and Claude sessions, feeds the Quota Meter's session rows, and powers live dots/focus actions in Sessions.")

                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Active registry directory (optional)", text: $codexActiveRegistryRootOverride,
                                  prompt: Text(verbatim: "~/.codex/active"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { validateCodexActiveRegistryRootOverride() }
                            .onChange(of: codexActiveRegistryRootOverride) { _, _ in
                                validateCodexActiveRegistryRootOverride()
                                codexActiveRegistryRootDebounce?.cancel()
                                let work = DispatchWorkItem { validateCodexActiveRegistryRootOverride() }
                                codexActiveRegistryRootDebounce = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                            }
                            .help("Override the directory used for active-session presence files. Leave blank to use $CODEX_HOME/active or ~/.codex/active.")

                        Button("Choose…", action: pickCodexActiveRegistryFolder)
                            .help("Browse for a directory containing active-session presence JSON files")
                    }
                } label: {
                    Text("Active registry directory (optional)")
                    Text("Default: $CODEX_HOME/active or ~/.codex/active")
                }

                if !codexActiveRegistryRootValid {
                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Live Sessions BETA")
            } footer: {
                Text("Status: Beta. Scope in this release: Codex + Claude live/open detection.")
            }

            Section("Quota Meter") {
                Picker(selection: Binding(
                    get: { QuotaMeterPlacement.current(raw: quotaMeterPlacementRaw) },
                    set: { quotaMeterPlacementRaw = $0.rawValue }
                )) {
                    ForEach(QuotaMeterPlacement.allCases) { placement in
                        Text(placement.title).tag(placement)
                    }
                } label: {
                    Text("Show Quota Meter in")
                    Text(QuotaMeterPlacement.current(raw: quotaMeterPlacementRaw).detail)
                }
                .pickerStyle(.segmented)
                .help("Show the Quota Meter in the notch or on the desktop.")

                if QuotaMeterPlacement.current(raw: quotaMeterPlacementRaw) != .floating {
                    Picker(selection: Binding(
                        get: { QuotaMeterNotchStyle.current(raw: quotaMeterNotchStyleRaw) },
                        set: { quotaMeterNotchStyleRaw = $0.rawValue }
                    )) {
                        ForEach(QuotaMeterNotchStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    } label: {
                        Text("Notch Style")
                        Text(QuotaMeterNotchStyle.current(raw: quotaMeterNotchStyleRaw).detail)
                    }
                    .pickerStyle(.segmented)
                    .help("Choose how much of the menu bar the collapsed notch uses.")
                }

                Toggle(isOn: $usageLimitCockpitProjectionEnabled) {
                    Text("Show 5h run-out token")
                    Text("Quota Meter run-out tokens use fresh 5h usage velocity and can show longer before-reset ETAs than notification alerts. This display setting is independent of notification delivery.")
                }
                .help("Show a compact token such as ▸2h in the Quota Meter when fresh 5h usage samples project exhaustion before reset.")

                Picker("Size", selection: $quotaMeterEnlarged) {
                    Text("Standard").tag(false)
                    Text("Enlarged").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Enlarged raises every Quota Meter font by one point (provider rows and Session Runway alike) for easier reading, keeping the same relative scale.")

                Picker(selection: Binding(
                    get: { QuotaMeterChrome.current(raw: quotaMeterChromeRaw) },
                    set: { quotaMeterChromeRaw = $0.rawValue }
                )) {
                    ForEach(QuotaMeterChrome.allCases) { chrome in
                        Text(chrome.title).tag(chrome)
                    }
                } label: {
                    Text("Toolbar")
                    Text(QuotaMeterChrome.current(raw: quotaMeterChromeRaw).detail)
                }
                .pickerStyle(.segmented)
                .help("Controls when the Quota Meter toolbar and reset-credits line appear.")
            }
        }
    }

    var advancedTab: some View {
        PreferencesForm {
            Section("Saved Sessions") {
                Toggle("Save also keeps locally", isOn: $starPinsSessions)
                    .help("When enabled, saving a session also archives its source files into Agent Sessions storage so it cannot disappear when the upstream CLI prunes history.")
                Picker("Stop syncing after inactivity", selection: $stopSyncAfterInactivityMinutes) {
                    Text("10 min").tag(10)
                    Text("30 min").tag(30)
                    Text("60 min").tag(60)
                }
                .help("After a saved session stops changing upstream for this long, Agent Sessions stops syncing the local copy. If it changes later, syncing resumes.")
                Toggle("Remove from Saved deletes local copy", isOn: $unstarRemovesArchive)
                    .help("When enabled, removing a session from Saved also deletes the local archive copy. By default, removing from Saved is non-destructive.")
            }

            Section {
                Toggle("Index full tool I/O for recent sessions", isOn: Binding(
                    get: {
                        UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex) == nil
                            ? false
                            : UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableRecentToolIOIndex)
                    },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Advanced.enableRecentToolIOIndex) }
                ))
                .help("Build a token-based index over tool inputs and outputs for sessions from the last 90 days. Improves Instant search but may increase disk usage and indexing time. Older indexed tool I/O is retained up to 25 MB.")

                Toggle(isOn: Binding(
                    get: {
                        UserDefaults.standard.object(forKey: PreferencesKey.Advanced.enableDeepToolOutputSearch) == nil
                            ? false
                            : UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableDeepToolOutputSearch)
                    },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Advanced.enableDeepToolOutputSearch) }
                )) {
                    Text("Include large tool outputs in global search")
                    Text("This finds additional matches inside large tool outputs that may not appear in Instant search. Leaving this off keeps search more responsive.")
                }
                .help("When enabled, global search continues scanning large tool outputs in the background after showing indexed results. This can be noticeably slower on large histories.")
            } header: {
                Text("Search")
            }

            Section {
                Toggle("Hide Dock icon", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: PreferencesKey.Advanced.hideDockIcon) as? Bool ?? false },
                    set: { DockIconPreferenceController.setDockIconHidden($0) }
                ))
                .help("Removes Agent Sessions from the Dock while the Quota Meter in the notch, or a pinned Quota Meter on the desktop, keeps the app reachable. Hiding the Dock icon without either moves the Quota Meter to the notch.")
            }

            Section("Claude Archived Sessions") {
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.allowClaudeArchiveRestore) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Advanced.allowClaudeArchiveRestore) }
                )) {
                    Text("Allow restoring archived Claude sessions")
                    Text("Off by default. Agent Sessions only writes to Claude's files when this is enabled.")
                }
                .help("Agent Sessions is otherwise read-only. Enabling this lets it modify Claude Desktop's session metadata to un-archive a session. Best done while Claude Desktop is quit, since Claude may overwrite the change. Your transcripts are never altered.")
            }

            Section {
                Button("Rebuild Core Index…") {
                    showCoreIndexRebuildConfirm = true
                }
                .help("Clear and rebuild the core sessions index. Use only when indexing appears corrupted.")
            } header: {
                Text("Indexing")
            } footer: {
                Text("This is an advanced repair action and can be CPU-intensive.")
            }
        }
    }

    var unifiedTab: some View {
        PreferencesForm {
            Section {
                Picker("Modified Date", selection: $modifiedDisplay) {
                    ForEach(SessionIndexer.ModifiedDisplay.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: modifiedDisplay) { _, newValue in
                    indexer.setModifiedDisplay(newValue)
                }
                .help("Switch between relative and absolute modified timestamps")
            }

            Section("Appearance") {
                Picker(selection: Binding(
                    get: { stripMonochromeGlobal ? 1 : 0 },
                    set: { stripMonochromeGlobal = ($0 == 1) }
                )) {
                    Text("Color").tag(0)
                    Text("Monochrome").tag(1)
                } label: {
                    Text("Agent Accents")
                    Text("Affects usage strips, source labels, and Agent column colors in Sessions.")
                }
                .pickerStyle(.segmented)
                .help("Choose colored or monochrome styling for agent accents")
            }

            Section("Session View") {
                let key = PreferencesKey.Unified.sessionViewAutoScrollTarget
                Picker("Auto-scroll in Session View", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: key) ?? SessionViewAutoScrollTarget.lastUserPrompt.rawValue },
                    set: { UserDefaults.standard.set($0, forKey: key) }
                )) {
                    ForEach(SessionViewAutoScrollTarget.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("When opening a session without a search query, choose which prompt to jump to in Session view")

                Toggle("Show Transcript Window", isOn: $unifiedShowTranscriptWindow)
                    .help("Show or hide the Transcript window in the Unified Window")

                Toggle("Show inline image thumbnails in Session view", isOn: $inlineSessionImageThumbnailsEnabled)
                    .help("Show small image thumbnails inline in Session view. Thumbnails load after scrolling stops to reduce CPU and I/O during fast scroll.")

                Toggle("Show harness context in Session view", isOn: $sessionShowContext)
                    .help("Show text the agent’s harness added: instructions, environment, skill files")
            }

            Section("Columns") {
                Toggle("Session titles", isOn: $columnVisibility.showTitleColumn)
                    .help("Show or hide the Session title column in the Sessions list")
                Toggle("Project names", isOn: $columnVisibility.showProjectColumn)
                    .help("Show or hide the Project column in the Sessions list")
                Toggle("Source column", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showSourceColumn) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showSourceColumn) }
                ))
                .help("Show or hide the Agent source column in the Unified list")
                Toggle("Message counts", isOn: $columnVisibility.showMsgsColumn)
                    .help("Show or hide message counts in the Sessions list")
                Toggle("Last Active", isOn: $columnVisibility.showModifiedColumn)
                    .help("Show or hide the modified date column")
                Toggle("Size column", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: PreferencesKey.Unified.showSizeColumn) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showSizeColumn) }
                ))
                .help("Show or hide the file size column in the Unified list")
                Toggle("Save", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: PreferencesKey.Unified.showStarColumn) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showStarColumn) }
                ))
                .help("Show or hide the Save button. Saved sessions can be kept locally to prevent upstream pruning from removing them.")
            }

            Section("Filters") {
                Toggle("Hide 0-message sessions", isOn: $hideZeroMessageSessionsPref)
                    .onChange(of: hideZeroMessageSessionsPref) { _, _ in indexer.recomputeNow() }
                    .help("Exclude sessions that contain no user or assistant messages")
                Toggle("Hide 1–2 message sessions", isOn: $hideLowMessageSessionsPref)
                    .onChange(of: hideLowMessageSessionsPref) { _, _ in indexer.recomputeNow() }
                    .help("Exclude sessions with only one or two messages (but keep 0-message sessions unless also excluded above)")
                Toggle("Hide housekeeping-only sessions", isOn: Binding(
                    get: { !showHousekeepingSessions },
                    set: { showHousekeepingSessions = !$0 }
                ))
                .onChange(of: showHousekeepingSessions) { _, _ in indexer.recomputeNow() }
                .help("Exclude sessions that contain no assistant output and no meaningful prompt content (for example Codex rollouts that only captured preamble, or Claude local-command-only transcripts)")
                Toggle("Hide sessions without tool calls (strict)", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.hasCommandsOnly) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.hasCommandsOnly) }
                ))
                .help("Exclude sessions that contain no recorded tool/command calls. Strict: Claude and Antigravity are excluded unless tool calls are present in the parsed transcript.")
                Toggle("Skip preambles when parsing (Codex + Claude)", isOn: Binding(
                    get: {
                        let d = UserDefaults.standard
                        if d.object(forKey: PreferencesKey.Unified.skipAgentsPreamble) == nil { return true }
                        return d.bool(forKey: PreferencesKey.Unified.skipAgentsPreamble)
                    },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.skipAgentsPreamble); indexer.recomputeNow() }
                ))
                .help("Ignore Codex Agents.md instructions and Claude local-command caveats when deriving titles and jumping to the first prompt (content remains visible)")
            }

            Section("Rich Transcript") {
                Toggle("Enable review cards for Codex internal review JSON", isOn: $transcriptEnableReviewCards)
                    .help("When enabled, recognized Codex internal review payloads render as summary cards instead of raw JSON.")
                Toggle("Enable file-link click targets in transcript", isOn: $transcriptEnableLinkification)
                    .help("Turn file path references like Foo.swift:56 into clickable links that open in your editor.")
                Toggle("Show line numbers for code and diff blocks", isOn: $transcriptEnableCodeDiffLineNumbers)
                    .help("Show per-block line numbers for semantic code and diff transcript blocks.")
                Picker("Preferred Editor", selection: Binding(
                    get: { IDEOpener.Target(rawValue: transcriptPreferredIDETargetRaw) ?? .systemDefault },
                    set: { transcriptPreferredIDETargetRaw = $0.rawValue }
                )) {
                    Text("System Default").tag(IDEOpener.Target.systemDefault)
                    Text("Cursor").tag(IDEOpener.Target.cursor)
                    Text("VS Code").tag(IDEOpener.Target.vscode)
                }
                .pickerStyle(.segmented)
                .help("Choose which app receives transcript file links.")
                TextField("Editor CLI Override", text: $transcriptIDEBinaryOverridePath,
                          prompt: Text("Optional binary path (for Cursor/VS Code)"))
                    .help("Optional override for the editor CLI binary used for line-targeted opens.")
            }
        }
    }

}

private extension PreferencesView {
    /// THE one place this pane names the `…AgentEnabled` `@AppStorage` properties.
    /// Exhaustive on purpose: a new source must say which preference its row reads
    /// instead of falling through a `default:` onto somebody else's toggle.
    func agentEnablementBinding(for source: SessionSource) -> Binding<Bool> {
        switch source {
        case .codex:       return $codexAgentEnabled
        case .claude:      return $claudeAgentEnabled
        case .antigravity: return $antigravityAgentEnabled
        case .opencode:    return $openCodeAgentEnabled
        case .hermes:      return $hermesAgentEnabled
        case .copilot:     return $copilotAgentEnabled
        case .droid:       return $droidAgentEnabled
        case .openclaw:    return $openClawAgentEnabled
        case .cursor:      return $cursorAgentEnabled
        case .pi:          return $piAgentEnabled
        case .kimi:        return $kimiAgentEnabled
        case .grok:        return $grokAgentEnabled
        case .qwen:        return $qwenAgentEnabled
        case .devin:       return $devinAgentEnabled
        case .fx:          return $fxAgentEnabled
        case .cline:       return $clineAgentEnabled
        case .deepseekHarness: return $deepSeekHarnessAgentEnabled
        }
    }

    func agentEnableToggle(title: String, source: SessionSource, isOn: Binding<Bool>, enabledCount: Int) -> some View {
        let availability = AgentEnablement.availabilityStatus(for: source)
        let isCurrentlyOn = isOn.wrappedValue
        let canDisable = !(enabledCount == 1 && isCurrentlyOn)
        let canEnable = availability.isAvailable || isCurrentlyOn
        let accent = Color.agentColor(for: source, monochrome: stripMonochromeGlobal)

        return Toggle(isOn: Binding(
            get: { isOn.wrappedValue },
            set: { newValue in
                _ = AgentEnablement.setEnabled(source, enabled: newValue)
            }
        )) {
            Text(title)
                .foregroundStyle(accent)
                .opacity(isCurrentlyOn ? 1.0 : 0.6)
            Text(availability.statusText)
        }
        .disabled(!(canDisable && canEnable))
    }
}

// MARK: - Terminal detection helpers

struct DetectedTerminal: Identifiable {
    let kind: TerminalKind
    var id: String { kind.rawValue }
    var displayName: String { kind.displayName }
}

private func detectInstalledTerminals() -> [DetectedTerminal] {
    let candidates: [TerminalKind] = [.terminalApp, .iterm2, .warp, .warpPreview, .ghostty]
    return candidates.filter { kind in
        guard let bundle = kind.bundleIdentifier else { return false }
        return isTerminalInstalled(bundleId: bundle)
    }.map { DetectedTerminal(kind: $0) }
}

private func isTerminalInstalled(bundleId: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    process.arguments = ["kMDItemCFBundleIdentifier == '\(bundleId)'"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitForExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
