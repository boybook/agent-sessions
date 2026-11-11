import SwiftUI
import AppKit

extension PreferencesView {
    var copilotCLITab: some View {
        PreferencesForm {
            if !copilotAgentEnabled {
                Section {
                    PreferenceCallout {
                        Text("This agent is disabled in General → Active CLI agents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("GitHub Copilot CLI Binary") {
                Picker("Binary Source", selection: Binding(
                    get: { copilotSettings.binaryPath.isEmpty ? 0 : 1 },
                    set: { idx in
                        if idx == 0 {
                            copilotSettings.setBinaryPath("")
                            scheduleCopilotProbe()
                        } else {
                            pickCopilotBinary()
                        }
                    }
                )) {
                    Text("Auto").tag(0)
                    Text("Custom").tag(1)
                }
                .pickerStyle(.segmented)
                .help("Use the auto-detected Copilot CLI or supply a custom path")

                if copilotSettings.binaryPath.isEmpty {
                    LabeledContent {
                        Text(copilotVersionString ?? "unknown").monospaced()
                    } label: {
                        Text("Detected:")
                        if let path = copilotResolvedPath {
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                    }

                    if copilotProbeState == .failure && copilotVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("GitHub Copilot CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install via Homebrew or download from GitHub Copilot CLI releases.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Check Version") { probeCopilot() }
                            .help("Query the detected Copilot CLI for its version")
                        Button(agentUpdateButtonTitle(for: .copilot)) { runAgentUpdateFlow(for: .copilot) }
                            .help("Check for a newer GitHub Copilot CLI version and optionally update it")
                            .disabled(isAgentUpdateBusy(.copilot))
                        Button("Copy Path") {
                            if let p = copilotResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .help("Copy the detected Copilot CLI path to clipboard")
                        .disabled(copilotResolvedPath == nil)
                        Button("Reveal") {
                            if let p = copilotResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .help("Reveal the detected Copilot CLI binary in Finder")
                        .disabled(copilotResolvedPath == nil)
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("/path/to/copilot", text: Binding(get: { copilotSettings.binaryPath }, set: { copilotSettings.setBinaryPath($0) }),
                                  prompt: Text("/path/to/copilot"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { scheduleCopilotProbe() }
                            .onChange(of: copilotSettings.binaryPath) { _, _ in scheduleCopilotProbe() }
                            .help("Enter the full path to a custom GitHub Copilot CLI binary")
                        Button("Choose…", action: pickCopilotBinary)
                            .help("Select the GitHub Copilot CLI binary from the filesystem")
                    }
                    if !copilotSettings.binaryPath.isEmpty, copilotProbeState == .failure {
                        Text("Invalid Copilot binary path.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(!copilotAgentEnabled)

            Section("Sessions Folder") {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Storage Root", text: $copilotSessionsPath, prompt: Text("~/.copilot/session-state"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateCopilotSessionsPath()
                                commitCopilotSessionsPathIfValid()
                            }
                            .onChange(of: copilotSessionsPath) { _, _ in
                                copilotSessionsPathDebounce?.cancel()
                                let work = DispatchWorkItem {
                                    validateCopilotSessionsPath()
                                    commitCopilotSessionsPathIfValid()
                                }
                                copilotSessionsPathDebounce = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                            }
                            .help("Override where Agent Sessions scans for Copilot session-state JSONL files")
                        Button("Choose…", action: pickCopilotSessionsFolder)
                            .help("Pick a folder to scan for Copilot sessions")
                    }
                } label: {
                    Text("Storage Root")
                    if copilotSessionsPathValid {
                        Text("Default: ~/.copilot/session-state")
                    }
                }

                if !copilotSessionsPathValid {
                    Text("Folder does not exist or is not a directory.")
                        .foregroundStyle(.red)
                }
            }
            .disabled(!copilotAgentEnabled)
        }
        .onAppear {
            scheduleCopilotProbe()
        }
    }

    // MARK: - Copilot Probe

    func probeCopilot() {
        if copilotProbeState == .probing { return }
        copilotProbeState = .probing
        copilotVersionString = nil
        copilotResolvedPath = nil
        let override = copilotSettings.binaryPath.isEmpty ? nil : copilotSettings.binaryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let env = CopilotCLIEnvironment()
            let result = env.probe(customPath: override)
            DispatchQueue.main.async {
                switch result {
                case .success(let res):
                    self.copilotVersionString = res.versionString
                    self.copilotResolvedPath = res.binaryURL.path
                    self.copilotProbeState = .success
                    self.copilotCLIAvailable = true
                case .failure:
                    self.copilotVersionString = nil
                    self.copilotResolvedPath = nil
                    self.copilotProbeState = .failure
                    self.copilotCLIAvailable = false
                }
            }
        }
    }

    // MARK: - Copilot Pickers

    func pickCopilotBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select GitHub Copilot CLI Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the copilot executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        // Suggest common locations
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            copilotSettings.setBinaryPath(url.path)
            scheduleCopilotProbe()
        }
    }

    func pickCopilotSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Copilot Sessions Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose a folder where Copilot session-state logs are stored", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if !copilotSessionsPath.isEmpty {
            let expanded = (copilotSessionsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else if let homeDir = FileManager.default.homeDirectoryForCurrentUser as URL? {
            panel.directoryURL = homeDir.appendingPathComponent(".copilot/session-state")
        }

        if panel.runModal() == .OK, let url = panel.url {
            copilotSessionsPath = url.path
            validateCopilotSessionsPath()
            commitCopilotSessionsPathIfValid()
        }
    }

    // MARK: - Copilot Path Validation

    func validateCopilotSessionsPath() {
        guard !copilotSessionsPath.isEmpty else {
            copilotSessionsPathValid = true
            return
        }
        let expanded = (copilotSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        copilotSessionsPathValid = exists && isDir.boolValue
    }

    func commitCopilotSessionsPathIfValid() {
        guard copilotSessionsPathValid else { return }
        // @AppStorage persists automatically; indexers update on refresh.
    }
}
