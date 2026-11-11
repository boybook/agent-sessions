import SwiftUI
import AppKit

extension PreferencesView {
    var grokTab: some View {
        PreferencesForm {
            if !grokAgentEnabled {
                Section {
                    PreferenceCallout {
                        Text("This agent is disabled in General -> Active CLI agents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("Binary Source", selection: Binding(
                    get: { grokSettings.binaryPath.isEmpty ? 0 : 1 },
                    set: { idx in
                        if idx == 0 {
                            grokSettings.setBinaryPath("")
                            scheduleGrokProbe()
                        } else {
                            pickGrokBinary()
                        }
                    }
                )) {
                    Text("Auto").tag(0)
                    Text("Custom").tag(1)
                }
                .pickerStyle(.segmented)
                .help("Use the auto-detected Grok CLI or supply a custom path")

                if grokSettings.binaryPath.isEmpty {
                    LabeledContent("Detected:") {
                        Text(grokVersionString ?? "unknown").monospaced()
                    }
                    if let path = grokResolvedPath {
                        LabeledContent("Resolved Path") {
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                    }

                    if grokProbeState == .failure && grokVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Grok CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install it from code.grok.com and ensure `grok` is on PATH.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Check Version") { probeGrok() }
                            .help("Query the detected Grok CLI for its version")
                        Button("Copy Path") {
                            if let p = grokResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .help("Copy the detected Grok CLI path to clipboard")
                        .disabled(grokResolvedPath == nil)
                        Button("Reveal") {
                            if let p = grokResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .help("Reveal the detected Grok CLI binary in Finder")
                        .disabled(grokResolvedPath == nil)
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("/path/to/grok", text: Binding(get: { grokSettings.binaryPath }, set: { grokSettings.setBinaryPath($0) }),
                                  prompt: Text("/path/to/grok"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { scheduleGrokProbe() }
                            .onChange(of: grokSettings.binaryPath) { _, _ in scheduleGrokProbe() }
                            .help("Enter the full path to a custom Grok CLI binary")
                        Button("Choose...", action: pickGrokBinary)
                            .help("Select the Grok CLI binary from the filesystem")
                    }
                    if !grokSettings.binaryPath.isEmpty, grokProbeState == .failure {
                        Text("Invalid Grok binary path.")
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Grok CLI Binary")
            } footer: {
                Text("Used for both the copied resume command and Resume in Terminal. Grok resumes by session id (`--resume`), falling back to `--continue` for the working directory.")
            }

            Section {
                LabeledContent("Status") {
                    let status = AgentEnablement.availabilityStatus(for: .grok)
                    HStack(spacing: 4) {
                        Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(status.isAvailable ? .green : .secondary)
                        Text(status.statusText)
                    }
                }

                LabeledContent("Default Root") {
                    Text("~/.grok/sessions")
                        .monospaced()
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Storage Root", text: $grokSessionsPath, prompt: Text("Custom root (leave empty for default)"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateGrokSessionsPath()
                                commitGrokSessionsPathIfValid()
                            }
                            .onChange(of: grokSessionsPath) { _, _ in
                                scheduleGrokSessionsPathValidation()
                            }
                        Button("Choose...", action: pickGrokSessionsFolder)
                            .help("Select a Grok sessions directory")
                    }
                } label: {
                    Text("Storage Root")
                }

                if !grokSessionsPathValid {
                    Text("Choose an existing directory.")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Sessions Storage")
            } footer: {
                Text("Grok writes one directory per session under its sessions root, holding chat_history.jsonl beside summary.json. Override only when you point GROK_HOME at a non-default location.")
            }
        }
        .onAppear {
            scheduleGrokProbe()
        }
    }

    func pickGrokBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Grok CLI Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the grok executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            grokSettings.setBinaryPath(url.path)
            scheduleGrokProbe()
        }
    }

    func validateGrokSessionsPath() {
        guard !grokSessionsPath.isEmpty else {
            grokSessionsPathValid = true
            return
        }
        let expanded = (grokSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        grokSessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    func commitGrokSessionsPathIfValid() {
        guard grokSessionsPathValid else { return }
        UserDefaults.standard.set(grokSessionsPath, forKey: PreferencesKey.Paths.grokSessionsRootOverride)
    }

    func scheduleGrokSessionsPathValidation() {
        grokSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validateGrokSessionsPath()
            commitGrokSessionsPathIfValid()
        }
        grokSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickGrokSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Grok Sessions Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the Grok sessions folder", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !grokSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (grokSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/sessions")
        }

        if panel.runModal() == .OK, let url = panel.url {
            grokSessionsPath = url.path
            validateGrokSessionsPath()
            commitGrokSessionsPathIfValid()
        }
    }
}
