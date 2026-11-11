import SwiftUI
import AppKit

extension PreferencesView {

	    var codexCLITab: some View {
	        PreferencesForm {
	            if !codexAgentEnabled {
	                Section {
	                    PreferenceCallout {
	                        Text("This agent is disabled in General → Active CLI agents.")
	                            .font(.caption)
	                            .foregroundStyle(.secondary)
	                    }
	                }
	            }

	            Section("Codex CLI Binary") {
	                Picker("Binary Source", selection: Binding(
	                    get: { codexBinaryOverride.isEmpty ? 0 : 1 },
	                    set: { idx in
	                        if idx == 0 {
	                            // Auto: clear override
	                            codexBinaryOverride = ""
	                            validateBinaryOverride()
	                            resumeSettings.setBinaryOverride("")
	                            scheduleCodexProbe()
	                        } else {
	                            // Custom: open file picker
	                            pickCodexBinary()
	                        }
	                    }
	                )) {
	                    Text("Auto").tag(0)
	                    Text("Custom").tag(1)
	                }
	                .pickerStyle(.segmented)
	                .help("Choose the Codex binary automatically or specify a custom executable")

	                if codexBinaryOverride.isEmpty {
	                    // Auto mode: show detected binary
	                    LabeledContent {
	                        Text(probeVersion?.description ?? "unknown").monospaced()
	                    } label: {
	                        Text("Detected:")
	                        if let path = resolvedCodexPath {
	                            Text(path).lineLimit(1).truncationMode(.middle)
	                        }
	                    }

	                    // Show helpful message if binary not found
	                    if probeState == .failure && probeVersion == nil {
	                        PreferenceCallout {
	                            VStack(alignment: .leading, spacing: 4) {
	                                Text("Codex CLI not found")
	                                    .font(.caption)
	                                    .fontWeight(.medium)
	                                Text("Install via npm: npm install -g @openai/codex-cli")
	                                    .font(.caption2)
	                                    .foregroundStyle(.secondary)
	                            }
	                        }
	                    }

	                    HStack {
	                        Spacer()
	                        Button("Check Version") { probeCodex() }
	                            .help("Query the currently detected Codex binary for its version")
	                        Button(agentUpdateButtonTitle(for: .codex)) { runAgentUpdateFlow(for: .codex) }
	                            .help("Check for a newer Codex CLI version and optionally update it")
	                            .disabled(isAgentUpdateBusy(.codex))
	                        Button("Copy Path") {
	                            if let p = resolvedCodexPath {
	                                NSPasteboard.general.clearContents()
	                                NSPasteboard.general.setString(p, forType: .string)
	                            }
	                        }
	                        .help("Copy the detected Codex binary path to clipboard")
	                        .disabled(resolvedCodexPath == nil)
	                        Button("Reveal") {
	                            if let p = resolvedCodexPath {
	                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
	                            }
	                        }
	                        .help("Reveal the detected Codex binary in Finder")
	                        .disabled(resolvedCodexPath == nil)
	                    }
	                } else {
	                    // Custom mode: text field for override
	                    HStack(spacing: 8) {
	                        TextField("/path/to/codex", text: $codexBinaryOverride, prompt: Text("/path/to/codex"))
	                            .labelsHidden()
	                            .textFieldStyle(.roundedBorder)
	                            .onSubmit { validateBinaryOverride(); commitCodexBinaryIfValid() }
	                            .onChange(of: codexBinaryOverride) { _, _ in validateBinaryOverride(); commitCodexBinaryIfValid() }
	                            .help("Enter the full path to a custom Codex binary")
	                        Button("Choose…", action: pickCodexBinary)
	                            .help("Select the Codex binary from the filesystem")
	                        Button("Clear") {
	                            codexBinaryOverride = ""
	                            validateBinaryOverride()
	                            resumeSettings.setBinaryOverride("")
	                            scheduleCodexProbe()
	                        }
	                        .help("Remove the custom binary override")
	                    }
	                    if !codexBinaryValid {
	                        Label("Must be an executable file", systemImage: "exclamationmark.triangle.fill")
	                            .foregroundStyle(.red)
	                    }
	                }
	            }
	            .disabled(!codexAgentEnabled)

	            Section("Sessions Directory") {
	                LabeledContent {
	                    HStack(spacing: 8) {
	                        TextField("Custom path (optional)", text: $codexPath,
	                                  prompt: Text(verbatim: "~/.codex/sessions"))
	                            .labelsHidden()
	                            .textFieldStyle(.roundedBorder)
	                            .onSubmit {
	                                validateCodexPath()
	                                commitCodexPathIfValid()
	                            }
	                            .onChange(of: codexPath) { _, _ in
	                                validateCodexPath()
	                                // Debounce commit on typing to avoid thrash
	                                codexPathDebounce?.cancel()
	                                let work = DispatchWorkItem { commitCodexPathIfValid() }
	                                codexPathDebounce = work
	                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
	                            }
	                            .help("Override the Codex sessions directory. Leave blank to use the default location")

	                        Button("Choose…", action: pickCodexFolder)
	                            .help("Browse for a directory to store Codex session logs")
	                    }
	                } label: {
	                    Text("Custom path (optional)")
	                    Text("Default: $CODEX_HOME/sessions or ~/.codex/sessions")
	                }

	                if !codexPathValid {
	                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
	                        .foregroundStyle(.red)
	                }
	            }
	            .disabled(!codexAgentEnabled)
	        }
	    }

	    var claudeResumeTab: some View {
	        PreferencesForm {
	            if !claudeAgentEnabled {
	                Section {
	                    PreferenceCallout {
	                        Text("This agent is disabled in General → Active CLI agents.")
	                            .font(.caption)
	                            .foregroundStyle(.secondary)
	                    }
	                }
	            }

	            // Binary Source
	            Section {
	                // Binary source segmented: Auto | Custom
	                Picker("Binary Source", selection: Binding(
	                    get: { claudeSettings.binaryPath.isEmpty ? 0 : 1 },
	                    set: { idx in
	                        if idx == 0 {
	                            // Auto: clear override
	                            claudeSettings.setBinaryPath("")
	                            scheduleClaudeProbe()
	                        } else {
	                            // Custom: open file picker
	                            pickClaudeBinary()
	                        }
	                    }
	                )) {
	                    Text("Auto").tag(0)
	                    Text("Custom").tag(1)
	                }
	                .pickerStyle(.segmented)
	                .help("Use the auto-detected Claude CLI or supply a custom path")

	                // Auto row (detected path + version + actions)
	                if claudeSettings.binaryPath.isEmpty {
	                    LabeledContent {
	                        Text(claudeVersionString ?? "unknown").monospaced()
	                    } label: {
	                        Text("Detected:")
	                        if let path = claudeResolvedPath {
	                            Text(path).lineLimit(1).truncationMode(.middle)
	                        }
	                    }

	                    // Show helpful message if binary not found
	                    if claudeProbeState == .failure && claudeVersionString == nil {
	                        PreferenceCallout {
	                            VStack(alignment: .leading, spacing: 4) {
	                                Text("Claude CLI not found")
	                                    .font(.caption)
	                                    .fontWeight(.medium)
	                                Text("Download from claude.ai/download or install via npm: npm install -g @anthropic/claude-cli")
	                                    .font(.caption2)
	                                    .foregroundStyle(.secondary)
	                            }
	                        }
	                    }

	                    HStack {
	                        Spacer()
	                        Button("Check Version") { probeClaude() }
	                            .help("Query the detected Claude CLI for its version")
	                        Button(agentUpdateButtonTitle(for: .claude)) { runAgentUpdateFlow(for: .claude) }
	                            .help("Check package-managed Claude installs, or run Claude Code's built-in updater for ~/.local installs")
	                            .disabled(isAgentUpdateBusy(.claude))
	                        Button("Copy Path") {
	                            if let p = claudeResolvedPath {
	                                NSPasteboard.general.clearContents()
	                                NSPasteboard.general.setString(p, forType: .string)
	                            }
	                        }
	                        .help("Copy the detected Claude CLI path to clipboard")
	                        .disabled(claudeResolvedPath == nil)
	                        Button("Reveal") {
	                            if let p = claudeResolvedPath {
	                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
	                            }
	                        }
	                        .help("Reveal the detected Claude CLI binary in Finder")
	                        .disabled(claudeResolvedPath == nil)
	                    }
	                } else {
	                    // Custom mode: text field for override
	                    HStack(spacing: 8) {
	                        TextField("/path/to/claude", text: Binding(get: { claudeSettings.binaryPath }, set: { claudeSettings.setBinaryPath($0) }),
	                                  prompt: Text("/path/to/claude"))
	                            .labelsHidden()
	                            .textFieldStyle(.roundedBorder)
	                            .onSubmit { scheduleClaudeProbe() }
	                            .onChange(of: claudeSettings.binaryPath) { _, _ in scheduleClaudeProbe() }
	                            .help("Enter the full path to a custom Claude CLI binary")
	                        Button("Choose…", action: pickClaudeBinary)
	                            .help("Select the Claude CLI binary from the filesystem")
	                        Button("Clear") {
	                            claudeSettings.setBinaryPath("")
	                        }
	                        .help("Remove the custom binary override")
	                    }
	                }
	            }
	            .disabled(!claudeAgentEnabled)

	            // Sessions Directory (Claude)
	            Section("Sessions Directory") {
	                LabeledContent {
	                    HStack(spacing: 8) {
	                        TextField("Custom path (optional)", text: $claudePath,
	                                  prompt: Text(verbatim: "~/.claude"))
	                            .labelsHidden()
	                            .textFieldStyle(.roundedBorder)
	                            .onSubmit {
	                                validateClaudePath()
	                                commitClaudePathIfValid()
	                            }
	                            .onChange(of: claudePath) { _, _ in
	                                validateClaudePath()
	                                claudePathDebounce?.cancel()
	                                let work = DispatchWorkItem { commitClaudePathIfValid() }
	                                claudePathDebounce = work
	                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
	                            }
	                            .help("Override the Claude sessions directory. Leave blank to use the default location")

	                        Button("Choose…", action: pickClaudeFolder)
	                            .help("Browse for a directory to store Claude session logs")
	                    }
	                } label: {
	                    Text("Custom path (optional)")
	                    Text("Default: ~/.claude")
	                }

	                if !claudePathValid {
	                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
	                        .foregroundStyle(.red)
	                }
	            }
	            .disabled(!claudeAgentEnabled)

	            // Usage Tracking moved to Unified Window tab.

	            // Probe cleanup controls moved to Usage Tracking → Usage Terminal Probes
	        }
	    }

	    var antigravityCLITab: some View {
	        PreferencesForm {
	            if !antigravityAgentEnabled {
	                Section {
	                    PreferenceCallout {
	                        Text("This agent is disabled in General → Active CLI agents.")
	                            .font(.caption)
	                            .foregroundStyle(.secondary)
	                    }
	                }
	            }

	            // Binary Source
	            Section {
	                // Binary source segmented: Auto | Custom
	                Picker("Binary Source", selection: Binding(
	                    get: { antigravitySettings.binaryOverride.isEmpty ? 0 : 1 },
	                    set: { idx in
	                        if idx == 0 {
	                            // Auto: clear override
	                            antigravitySettings.setBinaryOverride("")
	                            scheduleAntigravityProbe()
	                        } else {
	                            // Custom: open file picker
	                            pickAntigravityBinary()
	                        }
	                    }
	                )) {
	                    Text("Auto").tag(0)
	                    Text("Custom").tag(1)
	                }
	                .pickerStyle(.segmented)
	                .help("Use the auto-detected Antigravity CLI or supply a custom path")

	                // Auto row (detected path + version + actions)
	                if antigravitySettings.binaryOverride.isEmpty {
	                    LabeledContent {
	                        Text(antigravityVersionString ?? "unknown").monospaced()
	                    } label: {
	                        Text("Detected:")
	                        if let path = antigravityResolvedPath {
	                            Text(path).lineLimit(1).truncationMode(.middle)
	                        }
	                    }

	                    // Show helpful message if binary not found
	                    if antigravityProbeState == .failure && antigravityVersionString == nil {
	                        PreferenceCallout {
	                            VStack(alignment: .leading, spacing: 4) {
	                                Text("Antigravity CLI not found")
	                                    .font(.caption)
	                                    .fontWeight(.medium)
	                                Text("Binary name: agy · Install with the Antigravity CLI install script")
	                                    .font(.caption2)
	                                    .foregroundStyle(.secondary)
	                            }
	                        }
	                    }

	                    HStack {
	                        Spacer()
	                        Button("Check Version") { probeAntigravity() }
	                            .help("Query the detected Antigravity CLI for its version")
	                        Button(agentUpdateButtonTitle(for: .antigravity)) { runAgentUpdateFlow(for: .antigravity) }
	                            .help("Check for a newer Antigravity CLI version and optionally update it")
	                            .disabled(isAgentUpdateBusy(.antigravity))
	                        Button("Copy Path") {
	                            if let p = antigravityResolvedPath {
	                                NSPasteboard.general.clearContents()
	                                NSPasteboard.general.setString(p, forType: .string)
	                            }
	                        }
	                        .help("Copy the detected Antigravity CLI path to clipboard")
	                        .disabled(antigravityResolvedPath == nil)
	                        Button("Reveal") {
	                            if let p = antigravityResolvedPath {
	                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
	                            }
	                        }
	                        .help("Reveal the detected Antigravity CLI binary in Finder")
	                        .disabled(antigravityResolvedPath == nil)
	                    }
	                } else {
	                    // Custom mode: text field for override
	                    HStack(spacing: 8) {
	                        TextField("/path/to/agy", text: Binding(get: { antigravitySettings.binaryOverride }, set: { antigravitySettings.setBinaryOverride($0) }),
	                                  prompt: Text("/path/to/agy"))
	                            .labelsHidden()
	                            .textFieldStyle(.roundedBorder)
	                            .onSubmit { scheduleAntigravityProbe() }
	                            .onChange(of: antigravitySettings.binaryOverride) { _, _ in scheduleAntigravityProbe() }
	                            .help("Enter the full path to a custom Antigravity CLI binary")
	                        Button("Choose…", action: pickAntigravityBinary)
	                            .help("Select the Antigravity CLI binary from the filesystem")
	                        Button("Clear") {
	                            antigravitySettings.setBinaryOverride("")
	                        }
	                        .help("Remove the custom binary override")
	                    }
	                }
	            }
	            .disabled(!antigravityAgentEnabled)

	            // Sessions Directory (Antigravity)
	            Section {
	                LabeledContent {
	                    HStack(spacing: 8) {
	                        TextField("Custom path (optional)", text: $antigravitySessionsPath,
	                                  prompt: Text(verbatim: "~/.gemini/antigravity/brain"))
	                            .labelsHidden()
	                            .textFieldStyle(.roundedBorder)
	                            .onSubmit {
	                                validateAntigravitySessionsPath()
	                                commitAntigravitySessionsPathIfValid()
	                            }
	                            .onChange(of: antigravitySessionsPath) { _, _ in
	                                validateAntigravitySessionsPath()
	                                antigravitySessionsPathDebounce?.cancel()
	                                let work = DispatchWorkItem { commitAntigravitySessionsPathIfValid() }
	                                antigravitySessionsPathDebounce = work
	                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
	                            }
	                            .help("Override the Antigravity brain directory, where the markdown artifacts live. CLI transcripts are always read from their own default location. Leave blank to use the defaults")

	                        Button("Choose…", action: pickAntigravitySessionsFolder)
	                            .help("Browse for a directory that stores Antigravity artifacts")
	                    }
	                } label: {
	                    Text("Custom path (optional)")
	                    Text("Brain directory: ~/.gemini/antigravity/brain")
	                }

	                if !antigravitySessionsPathValid {
	                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
	                        .foregroundStyle(.red)
	                }
	            } header: {
	                Text("Sessions Directory")
	            } footer: {
	                Text("A custom path replaces the brain directory only. CLI transcripts are always read from ~/.gemini/antigravity-cli/brain.")
	            }
	            .disabled(!antigravityAgentEnabled)
	        }
	    }

    // MARK: - Antigravity Pickers

    func pickAntigravitySessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Antigravity Artifact Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the folder where Antigravity brain artifacts are stored", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        // Start at current override or default
        if !antigravitySessionsPath.isEmpty {
            let expanded = (antigravitySessionsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else if let homeDir = FileManager.default.homeDirectoryForCurrentUser as URL? {
            panel.directoryURL = homeDir.appendingPathComponent(".gemini/antigravity/brain")
        }

        if panel.runModal() == .OK, let url = panel.url {
            antigravitySessionsPath = url.path
            validateAntigravitySessionsPath()
            commitAntigravitySessionsPathIfValid()
        }
    }

    // MARK: - Antigravity Path Validation

    func validateAntigravitySessionsPath() {
        guard !antigravitySessionsPath.isEmpty else {
            antigravitySessionsPathValid = true
            return
        }
        let expanded = (antigravitySessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        antigravitySessionsPathValid = exists && isDir.boolValue
    }

    func commitAntigravitySessionsPathIfValid() {
        guard antigravitySessionsPathValid else { return }
        // The @AppStorage binding will automatically persist the value
        // Antigravity indexer listens to UserDefaults changes and triggers its own refresh.
    }

}
