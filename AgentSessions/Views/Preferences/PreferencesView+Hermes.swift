import SwiftUI
import AppKit

extension PreferencesView {
    var hermesCLITab: some View {
        PreferencesForm {
            if !hermesAgentEnabled {
                Section {
                    PreferenceCallout {
                        Text("This agent is disabled in General → Active CLI agents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("Binary Source", selection: Binding(
                    get: { hermesSettings.binaryPath.isEmpty ? 0 : 1 },
                    set: { idx in
                        if idx == 0 {
                            hermesSettings.setBinaryPath("")
                            scheduleHermesProbe()
                        } else {
                            pickHermesBinary()
                        }
                    }
                )) {
                    Text("Auto").tag(0)
                    Text("Custom").tag(1)
                }
                .pickerStyle(.segmented)

                if hermesSettings.binaryPath.isEmpty {
                    LabeledContent("Detected:") {
                        Text(hermesVersionString ?? "unknown").monospaced()
                    }
                    if let path = hermesResolvedPath {
                        LabeledContent("Resolved Path") {
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if hermesProbeState == .failure && hermesVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Hermes CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install Hermes Agent and ensure `hermes` is on PATH.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Check Version") { probeHermes() }
                        Button("Copy Path") {
                            if let path = hermesResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(path, forType: .string)
                            }
                        }
                        .disabled(hermesResolvedPath == nil)
                        Button("Reveal") {
                            if let path = hermesResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                        .disabled(hermesResolvedPath == nil)
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("/path/to/hermes", text: Binding(get: { hermesSettings.binaryPath }, set: { hermesSettings.setBinaryPath($0) }),
                                  prompt: Text("/path/to/hermes"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { scheduleHermesProbe() }
                            .onChange(of: hermesSettings.binaryPath) { _, _ in scheduleHermesProbe() }
                        Button("Choose…", action: pickHermesBinary)
                    }
                    if !hermesSettings.binaryPath.isEmpty, hermesProbeState == .failure {
                        Text("Invalid Hermes binary path.")
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Hermes CLI Binary")
            }
            .disabled(!hermesAgentEnabled)

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Storage Root", text: $hermesSessionsPath, prompt: Text("~/.hermes/sessions"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateHermesSessionsPath()
                                commitHermesSessionsPathIfValid()
                            }
                            .onChange(of: hermesSessionsPath) { _, _ in
                                hermesSessionsPathDebounce?.cancel()
                                let work = DispatchWorkItem {
                                    validateHermesSessionsPath()
                                    commitHermesSessionsPathIfValid()
                                }
                                hermesSessionsPathDebounce = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                            }
                        Button("Choose…", action: pickHermesSessionsFolder)
                    }
                } label: {
                    Text("Storage Root")
                }

                if !hermesSessionsPathValid {
                    Text("Folder does not exist or is not a directory.")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Sessions Folder")
            } footer: {
                if hermesSessionsPathValid {
                    Text("Default: ~/.hermes/sessions")
                }
            }
            .disabled(!hermesAgentEnabled)
        }
        .onAppear {
            scheduleHermesProbe()
        }
    }

    func probeHermes() {
        if hermesProbeState == .probing { return }
        hermesProbeState = .probing
        hermesVersionString = nil
        hermesResolvedPath = nil
        let override = hermesSettings.binaryPath.isEmpty ? nil : hermesSettings.binaryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let env = HermesCLIEnvironment()
            let result = env.probe(customPath: override)
            DispatchQueue.main.async {
                switch result {
                case .success(let res):
                    self.hermesVersionString = res.versionString
                    self.hermesResolvedPath = res.binaryURL.path
                    self.hermesProbeState = .success
                    self.hermesCLIAvailable = true
                case .failure:
                    self.hermesVersionString = nil
                    self.hermesResolvedPath = nil
                    self.hermesProbeState = .failure
                    self.hermesCLIAvailable = false
                }
            }
        }
    }

    func scheduleHermesProbe() {
        hermesProbeDebounce?.cancel()
        let work = DispatchWorkItem { probeHermes() }
        hermesProbeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func pickHermesBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Hermes CLI Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the hermes executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            hermesSettings.setBinaryPath(url.path)
            scheduleHermesProbe()
        }
    }

    func pickHermesSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Hermes Sessions Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose a folder where Hermes canonical session JSON files are stored", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !hermesSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (hermesSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/sessions")
        }
        if panel.runModal() == .OK, let url = panel.url {
            hermesSessionsPath = url.path
            validateHermesSessionsPath()
            commitHermesSessionsPathIfValid()
        }
    }

    func validateHermesSessionsPath() {
        guard !hermesSessionsPath.isEmpty else {
            hermesSessionsPathValid = true
            return
        }
        let expanded = (hermesSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        hermesSessionsPathValid = exists && isDir.boolValue
    }

    func commitHermesSessionsPathIfValid() {
        guard hermesSessionsPathValid else { return }
        let expanded = (hermesSessionsPath as NSString).expandingTildeInPath
        UserDefaults.standard.set(expanded, forKey: PreferencesKey.Paths.hermesSessionsRootOverride)
    }
}
