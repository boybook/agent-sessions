import SwiftUI
import AppKit

extension PreferencesView {
    var openCodeTab: some View {
        PreferencesForm {
            if !openCodeAgentEnabled {
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
                    get: { opencodeSettings.binaryPath.isEmpty ? 0 : 1 },
                    set: { idx in
                        if idx == 0 {
                            // Auto: clear override
                            opencodeSettings.setBinaryPath("")
                            scheduleOpenCodeProbe()
                        } else {
                            // Custom: open file picker
                            pickOpenCodeBinary()
                        }
                    }
                )) {
                    Text("Auto").tag(0)
                    Text("Custom").tag(1)
                }
                .pickerStyle(.segmented)
                .help("Use the auto-detected OpenCode CLI or supply a custom path")

                // Auto row (detected path + version + actions)
                if opencodeSettings.binaryPath.isEmpty {
                    LabeledContent {
                        Text(opencodeVersionString ?? "unknown").monospaced()
                    } label: {
                        Text("Detected:")
                        if let path = opencodeResolvedPath {
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                    }

                    // Show helpful message if binary not found
                    if opencodeProbeState == .failure && opencodeVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("OpenCode CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install via pip: pip install opencode-ai")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Check Version") { probeOpenCode() }
                            .help("Query the detected OpenCode CLI for its version")
                        Button(agentUpdateButtonTitle(for: .opencode)) { runAgentUpdateFlow(for: .opencode) }
                            .help("Check for a newer OpenCode CLI version and optionally update it")
                            .disabled(isAgentUpdateBusy(.opencode))
                        Button("Copy Path") {
                            if let p = opencodeResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .help("Copy the detected OpenCode CLI path to clipboard")
                        .disabled(opencodeResolvedPath == nil)
                        Button("Reveal") {
                            if let p = opencodeResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .help("Reveal the detected OpenCode CLI binary in Finder")
                        .disabled(opencodeResolvedPath == nil)
                    }
                } else {
                    // Custom mode: text field for override
                    HStack(spacing: 8) {
                        TextField("/path/to/opencode", text: Binding(get: { opencodeSettings.binaryPath }, set: { opencodeSettings.setBinaryPath($0) }),
                                  prompt: Text("/path/to/opencode"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { scheduleOpenCodeProbe() }
                            .onChange(of: opencodeSettings.binaryPath) { _, _ in scheduleOpenCodeProbe() }
                            .help("Enter the full path to a custom OpenCode CLI binary")
                        Button("Choose…", action: pickOpenCodeBinary)
                            .help("Select the OpenCode CLI binary from the filesystem")
                        Button("Clear") {
                            opencodeSettings.setBinaryPath("")
                        }
                        .help("Remove the custom binary override")
                    }
                }
            }
            .disabled(!openCodeAgentEnabled)

            // Storage backend indicator
            Section {
                LabeledContent("Status") {
                    Text(OpenCodePresenceIntegrationModel.shared.status)
                }
            } header: {
                Text("Live Sessions")
            } footer: {
                Text("Terminal sessions: exact selected conversation and working/idle state through the automatic TUI integration. Desktop: working sessions only; OpenCode does not expose its selected idle conversation.")
            }
            .disabled(!openCodeAgentEnabled)

            Section("Session Storage") {
                openCodeStorageBackendRow
            }
            .disabled(!openCodeAgentEnabled)

            // Sessions Directory (OpenCode)
            Section("Sessions Directory") {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Custom path (optional)", text: $opencodeSessionsPath,
                                  prompt: Text(verbatim: "~/.local/share/opencode/storage/session"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateOpenCodeSessionsPath()
                                commitOpenCodeSessionsPathIfValid()
                            }
                            .onChange(of: opencodeSessionsPath) { _, _ in
                                validateOpenCodeSessionsPath()
                                opencodeSessionsPathDebounce?.cancel()
                                let work = DispatchWorkItem { commitOpenCodeSessionsPathIfValid() }
                                opencodeSessionsPathDebounce = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                            }
                            .help("Override the OpenCode sessions directory. Leave blank to use the default location")

                        Button("Choose…", action: pickOpenCodeSessionsFolder)
                            .help("Browse for a directory to store OpenCode session logs")
                    }
                } label: {
                    Text("Custom path (optional)")
                    Text("Default: ~/.local/share/opencode/storage/session")
                }

                if !opencodeSessionsPathValid {
                    Label("Path must point to an existing folder", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .disabled(!openCodeAgentEnabled)

            // Resume
            Section("Resume") {
                Toggle("If resume fails, try continue in working directory", isOn: Binding(
                    get: { opencodeSettings.fallbackPolicy == .resumeThenContinue },
                    set: { opencodeSettings.setFallbackPolicy($0 ? .resumeThenContinue : .resumeOnly) }
                ))
                .help("When enabled, falls back to opencode --continue if --resume is unavailable")
            }
            .disabled(!openCodeAgentEnabled)
        }
        .onAppear {
            scheduleOpenCodeProbe()
        }
    }

    // MARK: - Storage backend row

    @ViewBuilder
    var openCodeStorageBackendRow: some View {
        let customRoot = opencodeSessionsPath.isEmpty ? nil : opencodeSessionsPath
        let backend = OpenCodeBackendDetector.detect(customRoot: customRoot)
        VStack(alignment: .leading, spacing: 4) {
            switch backend {
            case .sqlite:
                let dbURL = OpenCodeBackendDetector.dbURL(customRoot: customRoot)
                let size = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int) ?? 0
                let sizeMB = String(format: "%.1f MB", Double(size) / 1_000_000.0)
                HStack(spacing: 6) {
                    Image(systemName: "cylinder.fill")
                        .foregroundStyle(.green)
                    Text("SQLite (\(sizeMB))")
                        .foregroundStyle(.primary)
                }
                Text(dbURL.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .json:
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(.secondary)
                    Text("JSON (legacy)")
                        .foregroundStyle(.secondary)
                }
            case .none:
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Not found")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - OpenCode Probe

    func probeOpenCode() {
        if opencodeProbeState == .probing { return }
        opencodeProbeState = .probing
        opencodeVersionString = nil
        opencodeResolvedPath = nil
        let override = opencodeSettings.binaryPath.isEmpty ? nil : opencodeSettings.binaryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let env = OpenCodeCLIEnvironment()
            let result = env.probe(customPath: override)
            DispatchQueue.main.async {
                switch result {
                case .success(let res):
                    self.opencodeVersionString = res.versionString
                    self.opencodeResolvedPath = res.binaryURL.path
                    self.opencodeProbeState = .success
                    self.openCodeCLIAvailable = true
                case .failure:
                    self.opencodeVersionString = nil
                    self.opencodeResolvedPath = nil
                    self.opencodeProbeState = .failure
                    self.openCodeCLIAvailable = false
                }
            }
        }
    }

    func scheduleOpenCodeProbe() {
        opencodeProbeDebounce?.cancel()
        let work = DispatchWorkItem { probeOpenCode() }
        opencodeProbeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - OpenCode Pickers

    func pickOpenCodeBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select OpenCode CLI Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the opencode executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        // Suggest common locations
        if let homeDir = FileManager.default.homeDirectoryForCurrentUser as URL? {
            panel.directoryURL = homeDir.appendingPathComponent(".local/bin")
        }

        if panel.runModal() == .OK, let url = panel.url {
            opencodeSettings.setBinaryPath(url.path)
            scheduleOpenCodeProbe()
        }
    }

    func pickOpenCodeSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select OpenCode Sessions Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose a folder where OpenCode session logs are stored", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        // Start at current override or default
        if !opencodeSessionsPath.isEmpty {
            let expanded = (opencodeSessionsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else if let homeDir = FileManager.default.homeDirectoryForCurrentUser as URL? {
            panel.directoryURL = homeDir.appendingPathComponent(".local/share/opencode/storage/session")
        }

        if panel.runModal() == .OK, let url = panel.url {
            opencodeSessionsPath = url.path
            validateOpenCodeSessionsPath()
            commitOpenCodeSessionsPathIfValid()
        }
    }

    // MARK: - OpenCode Path Validation

    func validateOpenCodeSessionsPath() {
        guard !opencodeSessionsPath.isEmpty else {
            opencodeSessionsPathValid = true
            return
        }
        let expanded = (opencodeSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        opencodeSessionsPathValid = exists && isDir.boolValue
    }

    func commitOpenCodeSessionsPathIfValid() {
        guard opencodeSessionsPathValid else { return }
        // The @AppStorage binding will automatically persist the value
        // OpenCodeSessionIndexer listens to UserDefaults changes and triggers its own refresh
    }
}
