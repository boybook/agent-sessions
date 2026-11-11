import SwiftUI
import AppKit

extension PreferencesView {
    var devinTab: some View {
        PreferencesForm {
            if !devinAgentEnabled {
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
                    get: { devinSettings.binaryPath.isEmpty ? 0 : 1 },
                    set: { idx in
                        if idx == 0 {
                            devinSettings.setBinaryPath("")
                            scheduleDevinProbe()
                        } else {
                            pickDevinBinary()
                        }
                    }
                )) {
                    Text("Auto").tag(0)
                    Text("Custom").tag(1)
                }
                .pickerStyle(.segmented)
                .help("Use the auto-detected Devin CLI or supply a custom path")

                if devinSettings.binaryPath.isEmpty {
                    LabeledContent("Detected:") {
                        Text(devinVersionString ?? "unknown").monospaced()
                    }
                    if let path = devinResolvedPath {
                        LabeledContent("Resolved Path") {
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                    }

                    if devinProbeState == .failure && devinVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Devin CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install it from devin.ai and ensure `devin` is on PATH.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Check Version") { probeDevin() }
                            .help("Query the detected Devin CLI for its version")
                        Button("Copy Path") {
                            if let p = devinResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .help("Copy the detected Devin CLI path to clipboard")
                        .disabled(devinResolvedPath == nil)
                        Button("Reveal") {
                            if let p = devinResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .help("Reveal the detected Devin CLI binary in Finder")
                        .disabled(devinResolvedPath == nil)
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("/path/to/devin", text: Binding(get: { devinSettings.binaryPath }, set: { devinSettings.setBinaryPath($0) }),
                                  prompt: Text("/path/to/devin"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { scheduleDevinProbe() }
                            .onChange(of: devinSettings.binaryPath) { _, _ in scheduleDevinProbe() }
                            .help("Enter the full path to a custom Devin CLI binary")
                        Button("Choose...", action: pickDevinBinary)
                            .help("Select the Devin CLI binary from the filesystem")
                    }
                    if !devinSettings.binaryPath.isEmpty, devinProbeState == .failure {
                        Text("Invalid Devin binary path.")
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Devin CLI Binary")
            } footer: {
                Text("Used for both the copied resume command and Resume in Terminal. Devin resumes by session id (`--resume`), falling back to `--continue` for the most recent conversation.")
            }

            Section {
                LabeledContent("Status") {
                    let status = AgentEnablement.availabilityStatus(for: .devin)
                    HStack(spacing: 4) {
                        Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(status.isAvailable ? .green : .secondary)
                        Text(status.statusText)
                    }
                }

                LabeledContent("Default Root") {
                    Text("~/.local/share/devin/cli")
                        .monospaced()
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Storage Root", text: $devinSessionsPath, prompt: Text("Custom root (leave empty for default)"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateDevinSessionsPath()
                                commitDevinSessionsPathIfValid()
                            }
                            .onChange(of: devinSessionsPath) { _, _ in
                                scheduleDevinSessionsPathValidation()
                            }
                        Button("Choose...", action: pickDevinSessionsFolder)
                            .help("Select a Devin sessions directory")
                    }
                } label: {
                    Text("Storage Root")
                }

                if !devinSessionsPathValid {
                    Text("Choose an existing directory.")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Sessions Storage")
            } footer: {
                Text("Devin keeps every session in one SQLite database (sessions.db) under its CLI data directory. Override only when that data lives outside the default location; point it at the devin data directory or the cli directory that contains sessions.db.")
            }
        }
        .onAppear {
            scheduleDevinProbe()
        }
    }

    func pickDevinBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Devin CLI Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the devin executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            devinSettings.setBinaryPath(url.path)
            scheduleDevinProbe()
        }
    }

    func validateDevinSessionsPath() {
        guard !devinSessionsPath.isEmpty else {
            devinSessionsPathValid = true
            return
        }
        let expanded = (devinSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        devinSessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    func commitDevinSessionsPathIfValid() {
        guard devinSessionsPathValid else { return }
        UserDefaults.standard.set(devinSessionsPath, forKey: "DevinSessionsRootOverride")
    }

    func scheduleDevinSessionsPathValidation() {
        devinSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validateDevinSessionsPath()
            commitDevinSessionsPathIfValid()
        }
        devinSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickDevinSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Devin Sessions Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the Devin sessions folder", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !devinSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (devinSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/devin/cli")
        }

        if panel.runModal() == .OK, let url = panel.url {
            devinSessionsPath = url.path
            validateDevinSessionsPath()
            commitDevinSessionsPathIfValid()
        }
    }
}
