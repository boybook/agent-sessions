import SwiftUI
import AppKit

extension PreferencesView {
    var cursorTab: some View {
        PreferencesForm {
            if !cursorAgentEnabled {
                Section {
                    PreferenceCallout {
                        Text("This agent is disabled in General → Active CLI agents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Cursor CLI Binary") {
                Picker("Binary Source", selection: Binding(
                    get: { cursorSettings.binaryPath.isEmpty ? 0 : 1 },
                    set: { idx in
                        if idx == 0 {
                            cursorSettings.setBinaryPath("")
                            scheduleCursorProbe()
                        } else {
                            pickCursorBinary()
                        }
                    }
                )) {
                    Text("Auto").tag(0)
                    Text("Custom").tag(1)
                }
                .pickerStyle(.segmented)
                .help("Use the auto-detected Cursor CLI or supply a custom path")

                if cursorSettings.binaryPath.isEmpty {
                    LabeledContent {
                        Text(cursorVersionString ?? "unknown").monospaced()
                    } label: {
                        Text("Detected:")
                        if let path = cursorResolvedPath {
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                    }

                    if cursorProbeState == .failure && cursorVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cursor CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install Cursor Agent from cursor.com/download and ensure `cursor` is on PATH.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Check Version") { probeCursor() }
                            .help("Query the detected Cursor CLI for its version")
                        Button("Copy Path") {
                            if let p = cursorResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .help("Copy the detected Cursor CLI path to clipboard")
                        .disabled(cursorResolvedPath == nil)
                        Button("Reveal") {
                            if let p = cursorResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .help("Reveal the detected Cursor CLI binary in Finder")
                        .disabled(cursorResolvedPath == nil)
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("/path/to/agent", text: Binding(get: { cursorSettings.binaryPath }, set: { cursorSettings.setBinaryPath($0) }),
                                  prompt: Text("/path/to/agent"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { scheduleCursorProbe() }
                            .onChange(of: cursorSettings.binaryPath) { _, _ in scheduleCursorProbe() }
                            .help("Enter the full path to a custom Cursor CLI binary")
                        Button("Choose…", action: pickCursorBinary)
                            .help("Select the Cursor CLI binary from the filesystem")
                    }
                    if !cursorSettings.binaryPath.isEmpty, cursorProbeState == .failure {
                        Text("Invalid Cursor binary path.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(!cursorAgentEnabled)

            Section("Sessions Storage") {
                LabeledContent("Status") {
                    let status = AgentEnablement.availabilityStatus(for: .cursor)
                    HStack(spacing: 4) {
                        Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(status.isAvailable ? .green : .secondary)
                        Text(status.statusText)
                    }
                }

                LabeledContent("Storage Root") {
                    Text("~/.cursor")
                        .monospaced()
                }

                LabeledContent("Transcripts") {
                    Text("~/.cursor/projects/*/agent-transcripts/")
                        .monospaced()
                }

                LabeledContent("Chat Metadata") {
                    Text("~/.cursor/chats/*/*/store.db")
                        .monospaced()
                }
            }
            .disabled(!cursorAgentEnabled)

            Section {
                @AppStorage(PreferencesKey.Paths.cursorSessionsRootOverride) var cursorRootOverride: String = ""

                TextField("Storage Root", text: $cursorRootOverride, prompt: Text("Custom root (leave empty for default)"))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Custom Root Override")
            } footer: {
                Text("Override the default ~/.cursor path. Most users should leave this empty.")
            }
            .disabled(!cursorAgentEnabled)
        }
        .onAppear {
            scheduleCursorProbe()
        }
    }

    func pickCursorBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Cursor CLI Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the agent executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            cursorSettings.setBinaryPath(url.path)
            scheduleCursorProbe()
        }
    }
}
