import SwiftUI
import AppKit

extension PreferencesView {
    /// Browse-only DeepSeek Harness pane: no binary override, no resume action,
    /// no network work. Sessions-root override only, following the Fx/Cline
    /// storage-section shape. The enabled toggle lives in General.
    var deepseekHarnessTab: some View {
        PreferencesForm {
            if !deepSeekHarnessAgentEnabled {
                Section {
                    PreferenceCallout {
                        Text("This agent is disabled in General -> Active CLI agents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("Status") {
                    let status = AgentEnablement.availabilityStatus(for: .deepseekHarness)
                    HStack(spacing: 4) {
                        Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(status.isAvailable ? .green : .secondary)
                        Text(status.statusText)
                    }
                }

                LabeledContent("Default Root") {
                    Text("$DSH_HOME/sessions, or ~/.dsh/sessions")
                        .monospaced()
                }

                LabeledContent("Resolved Path") {
                    Text(resolvedDeepSeekHarnessSessionsPath)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Storage Root", text: $deepSeekHarnessSessionsPath, prompt: Text("Custom root (leave empty for default)"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateDeepSeekHarnessSessionsPath()
                                commitDeepSeekHarnessSessionsPathIfValid()
                            }
                            .onChange(of: deepSeekHarnessSessionsPath) { _, _ in
                                scheduleDeepSeekHarnessSessionsPathValidation()
                            }
                        Button("Choose...", action: pickDeepSeekHarnessSessionsFolder)
                            .help("Select a DeepSeek sessions directory")
                    }
                } label: {
                    Text("Storage Root")
                }

                if !deepSeekHarnessSessionsPathValid {
                    Text("Choose an existing directory.")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Sessions Storage")
            } footer: {
                Text("Precedence: the override above wins when set and points directly at the sessions root; otherwise the app uses $DSH_HOME/sessions when $DSH_HOME is set, otherwise ~/.dsh/sessions.")
            }

            Section("Limitations") {
                Text("v1 browses and searches local v0–v3 plain (.jsonl) and Zstandard (.jsonl.zstd) generations. Not offered: resume in Terminal, live sessions, DSH archive-state mirroring, attachment-byte lookup, or usage telemetry.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            deepSeekHarnessSessionsPath = UserDefaults.standard.string(forKey: DeepSeekHarnessSettings.Keys.rootOverride) ?? ""
            validateDeepSeekHarnessSessionsPath()
        }
    }

    /// The sessions root the indexer resolves from the current override, using
    /// the same `DeepSeekHarnessDiscovery` truth the refresh path reads. Path
    /// computation only — no filesystem inspection.
    var resolvedDeepSeekHarnessSessionsPath: String {
        let override = DeepSeekHarnessSettings.normalizedOverride(deepSeekHarnessSessionsPath)
        return DeepSeekHarnessDiscovery(customRoot: override.isEmpty ? nil : override)
            .sessionsRoot().path
    }

    func validateDeepSeekHarnessSessionsPath() {
        let trimmed = DeepSeekHarnessSettings.normalizedOverride(deepSeekHarnessSessionsPath)
        guard !trimmed.isEmpty else {
            deepSeekHarnessSessionsPathValid = true
            return
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        deepSeekHarnessSessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    /// Persists through the single `DeepSeekHarnessSettings.Keys.rootOverride`
    /// key the indexer already reads on its next refresh; no explicit reload
    /// call, matching the Fx/Cline root-only commit path.
    func commitDeepSeekHarnessSessionsPathIfValid() {
        guard deepSeekHarnessSessionsPathValid else { return }
        let trimmed = DeepSeekHarnessSettings.normalizedOverride(deepSeekHarnessSessionsPath)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: DeepSeekHarnessSettings.Keys.rootOverride)
        } else {
            UserDefaults.standard.set(trimmed, forKey: DeepSeekHarnessSettings.Keys.rootOverride)
        }
    }

    func scheduleDeepSeekHarnessSessionsPathValidation() {
        deepSeekHarnessSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validateDeepSeekHarnessSessionsPath()
            commitDeepSeekHarnessSessionsPathIfValid()
        }
        deepSeekHarnessSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickDeepSeekHarnessSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select DeepSeek Sessions Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the DeepSeek sessions folder", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !deepSeekHarnessSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (deepSeekHarnessSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/sessions")
        }

        if panel.runModal() == .OK, let url = panel.url {
            deepSeekHarnessSessionsPath = url.path
            validateDeepSeekHarnessSessionsPath()
            commitDeepSeekHarnessSessionsPathIfValid()
        }
    }
}
