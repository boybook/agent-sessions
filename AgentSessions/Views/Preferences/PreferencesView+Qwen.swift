import SwiftUI
import AppKit

extension PreferencesView {
    var qwenTab: some View {
        PreferencesForm {
            if !qwenAgentEnabled {
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
                    get: { qwenSettings.binaryPath.isEmpty ? 0 : 1 },
                    set: { value in
                        if value == 0 {
                            qwenSettings.setBinaryPath("")
                            scheduleQwenProbe()
                        } else {
                            pickQwenBinary()
                        }
                    }
                )) {
                    Text("Auto").tag(0)
                    Text("Custom").tag(1)
                }
                .pickerStyle(.segmented)

                if qwenSettings.binaryPath.isEmpty {
                    LabeledContent("Detected:") {
                        Text(qwenVersionString ?? "unknown").monospaced()
                    }
                    if let path = qwenResolvedPath {
                        LabeledContent("Resolved Path") {
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if qwenProbeState == .failure && qwenVersionString == nil {
                        PreferenceCallout {
                            Text("Qwen Code was not found. Ensure `qwen` is on PATH.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Check Version") { probeQwen() }
                        Button("Copy Path") {
                            if let path = qwenResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(path, forType: .string)
                            }
                        }
                        .disabled(qwenResolvedPath == nil)
                        Button("Reveal") {
                            if let path = qwenResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                        .disabled(qwenResolvedPath == nil)
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("/path/to/qwen", text: Binding(
                            get: { qwenSettings.binaryPath },
                            set: { qwenSettings.setBinaryPath($0) }
                        ), prompt: Text("/path/to/qwen"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { scheduleQwenProbe() }
                        .onChange(of: qwenSettings.binaryPath) { _, _ in scheduleQwenProbe() }
                        Button("Choose...", action: pickQwenBinary)
                    }
                    if qwenProbeState == .failure {
                        Text("Invalid Qwen Code binary path.").foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Qwen Code Binary")
            } footer: {
                Text("Active chats use the installed CLI's advertised `--resume <id>` command, with `--continue` only when the session working directory is known. Archived chats remain browsable and searchable, but Qwen cannot resume them in place.")
            }

            Section {
                LabeledContent("Status") {
                    let status = AgentEnablement.availabilityStatus(for: .qwen)
                    HStack(spacing: 4) {
                        Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(status.isAvailable ? .green : .secondary)
                        Text(status.statusText)
                    }
                }
                LabeledContent("Default Root") {
                    Text("~/.qwen/projects").monospaced()
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Storage Root", text: $qwenSessionsPath, prompt: Text("Custom root (leave empty for default)"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateQwenSessionsPath()
                                commitQwenSessionsPathIfValid()
                            }
                            .onChange(of: qwenSessionsPath) { _, _ in scheduleQwenSessionsPathValidation() }
                        Button("Choose...", action: pickQwenSessionsFolder)
                    }
                } label: {
                    Text("Storage Root")
                }
                if !qwenSessionsPathValid {
                    Text("Choose an existing directory.").foregroundStyle(.red)
                }
            } header: {
                Text("Sessions Storage")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Qwen Code stores one session-ID-named JSONL transcript per session below each project's chats directory. Override this only for a relocated QWEN_HOME or copied projects root. A copied root not named projects remains browse-only because the CLI cannot resolve it for resume.")
                    Text("QWEN_RUNTIME_DIR is process-local and is not auto-detected. If you use it, choose that runtime directory's projects folder here.")
                }
            }
        }
        .onAppear { scheduleQwenProbe() }
    }

    func pickQwenBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Qwen Code Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the qwen executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            qwenSettings.setBinaryPath(url.path)
            scheduleQwenProbe()
        }
    }

    func validateQwenSessionsPath() {
        guard !qwenSessionsPath.isEmpty else {
            qwenSessionsPathValid = true
            return
        }
        let expanded = (qwenSessionsPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        qwenSessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func commitQwenSessionsPathIfValid() {
        guard qwenSessionsPathValid else { return }
        UserDefaults.standard.set(qwenSessionsPath, forKey: QwenPreferencesKey.sessionsRootOverride)
    }

    func scheduleQwenSessionsPathValidation() {
        qwenSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validateQwenSessionsPath()
            commitQwenSessionsPathIfValid()
        }
        qwenSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickQwenSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Qwen Code Projects Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the Qwen Code projects folder", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = qwenSessionsPath.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".qwen/projects")
            : URL(fileURLWithPath: (qwenSessionsPath as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            qwenSessionsPath = url.path
            validateQwenSessionsPath()
            commitQwenSessionsPathIfValid()
        }
    }
}
