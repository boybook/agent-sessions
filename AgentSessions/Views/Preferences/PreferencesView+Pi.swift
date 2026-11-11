import SwiftUI
import AppKit

extension PreferencesView {
    var piTab: some View {
        PreferencesForm {
            if !piAgentEnabled {
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
                    get: { piSettings.binaryPath.isEmpty ? 0 : 1 },
                    set: { idx in
                        if idx == 0 {
                            piSettings.setBinaryPath("")
                            schedulePiProbe()
                        } else {
                            pickPiBinary()
                        }
                    }
                )) {
                    Text("Auto").tag(0)
                    Text("Custom").tag(1)
                }
                .pickerStyle(.segmented)
                .help("Use the auto-detected Pi CLI or supply a custom path")

                if piSettings.binaryPath.isEmpty {
                    LabeledContent("Detected:") {
                        Text(piVersionString ?? "unknown").monospaced()
                    }
                    if let path = piResolvedPath {
                        LabeledContent("Resolved Path") {
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                    }

                    if piProbeState == .failure && piVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Pi CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install Pi from pi.dev and ensure `pi` is on PATH.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Check Version") { probePi() }
                            .help("Query the detected Pi CLI for its version")
                        Button("Copy Path") {
                            if let p = piResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .help("Copy the detected Pi CLI path to clipboard")
                        .disabled(piResolvedPath == nil)
                        Button("Reveal") {
                            if let p = piResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .help("Reveal the detected Pi CLI binary in Finder")
                        .disabled(piResolvedPath == nil)
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("/path/to/pi", text: Binding(get: { piSettings.binaryPath }, set: { piSettings.setBinaryPath($0) }),
                                  prompt: Text("/path/to/pi"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { schedulePiProbe() }
                            .onChange(of: piSettings.binaryPath) { _, _ in schedulePiProbe() }
                            .help("Enter the full path to a custom Pi CLI binary")
                        Button("Choose...", action: pickPiBinary)
                            .help("Select the Pi CLI binary from the filesystem")
                    }
                    if !piSettings.binaryPath.isEmpty, piProbeState == .failure {
                        Text("Invalid Pi binary path.")
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Pi CLI Binary")
            }

            Section {
                LabeledContent("Status") {
                    let status = AgentEnablement.availabilityStatus(for: .pi)
                    HStack(spacing: 4) {
                        Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(status.isAvailable ? .green : .secondary)
                        Text(status.statusText)
                    }
                }

                LabeledContent("Default Root") {
                    Text("~/.pi/agent/sessions")
                        .monospaced()
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Storage Root", text: $piSessionsPath, prompt: Text("Custom root (leave empty for default)"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validatePiSessionsPath()
                                commitPiSessionsPathIfValid()
                            }
                            .onChange(of: piSessionsPath) { _, _ in
                                schedulePiSessionsPathValidation()
                            }
                        Button("Choose...", action: pickPiSessionsFolder)
                            .help("Select a Pi sessions directory")
                    }
                } label: {
                    Text("Storage Root")
                }

                if !piSessionsPathValid {
                    Text("Choose an existing directory.")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Sessions Storage")
            } footer: {
                Text("Pi writes JSONL v3 session files under its sessions directory. Override only when you use a non-default Pi agent directory.")
            }
        }
        .onAppear {
            schedulePiProbe()
        }
    }

    func pickPiBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Pi CLI Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the pi executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            piSettings.setBinaryPath(url.path)
            schedulePiProbe()
        }
    }

    func validatePiSessionsPath() {
        guard !piSessionsPath.isEmpty else {
            piSessionsPathValid = true
            return
        }
        let expanded = (piSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        piSessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    func commitPiSessionsPathIfValid() {
        guard piSessionsPathValid else { return }
        UserDefaults.standard.set(piSessionsPath, forKey: PreferencesKey.Paths.piSessionsRootOverride)
    }

    func schedulePiSessionsPathValidation() {
        piSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validatePiSessionsPath()
            commitPiSessionsPathIfValid()
        }
        piSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickPiSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Pi Sessions Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the Pi sessions folder", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !piSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (piSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/sessions")
        }

        if panel.runModal() == .OK, let url = panel.url {
            piSessionsPath = url.path
            validatePiSessionsPath()
            commitPiSessionsPathIfValid()
        }
    }
}
