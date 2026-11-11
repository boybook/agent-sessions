import SwiftUI
import AppKit

extension PreferencesView {
    var droidCLITab: some View {
        PreferencesForm {
            if !droidAgentEnabled {
                Section {
                    PreferenceCallout {
                        Text("This agent is disabled in General → Active CLI agents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Droid CLI Binary") {
                Picker("Binary Source", selection: Binding(
                    get: { droidSettings.binaryPath.isEmpty ? 0 : 1 },
                    set: { idx in
                        if idx == 0 {
                            droidSettings.setBinaryPath("")
                            scheduleDroidProbe()
                        } else {
                            pickDroidBinary()
                        }
                    }
                )) {
                    Text("Auto").tag(0)
                    Text("Custom").tag(1)
                }
                .pickerStyle(.segmented)
                .help("Use the auto-detected Droid CLI or supply a custom path")

                if droidSettings.binaryPath.isEmpty {
                    LabeledContent {
                        Text(droidVersionString ?? "unknown").monospaced()
                    } label: {
                        Text("Detected:")
                        if let path = droidResolvedPath {
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                    }

                    if droidProbeState == .failure && droidVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Droid CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install Droid (Factory CLI) and ensure `droid` is available on your PATH, or set a custom binary path here.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Check Version") { probeDroid() }
                            .help("Query the detected Droid CLI for its version")
                        Button(agentUpdateButtonTitle(for: .droid)) { runAgentUpdateFlow(for: .droid) }
                            .help("Check for a newer Droid CLI version and optionally update it")
                            .disabled(isAgentUpdateBusy(.droid))
                        Button("Copy Path") {
                            if let p = droidResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .help("Copy the detected Droid CLI path to clipboard")
                        .disabled(droidResolvedPath == nil)
                        Button("Reveal") {
                            if let p = droidResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .help("Reveal the detected Droid CLI binary in Finder")
                        .disabled(droidResolvedPath == nil)
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("/path/to/droid", text: Binding(get: { droidSettings.binaryPath }, set: { droidSettings.setBinaryPath($0) }),
                                  prompt: Text("/path/to/droid"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { scheduleDroidProbe() }
                            .onChange(of: droidSettings.binaryPath) { _, _ in scheduleDroidProbe() }
                            .help("Enter the full path to a custom Droid CLI binary")
                        Button("Choose…", action: pickDroidBinary)
                            .help("Select the Droid CLI binary from the filesystem")
                    }

                    if droidProbeState == .failure {
                        Text("Unable to execute the specified binary. Check the path and try again.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(!droidAgentEnabled)

            Section("Sessions Directory") {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Storage Root", text: $droidSessionsPath, prompt: Text("~/.factory/sessions"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateDroidSessionsPath()
                                commitDroidSessionsPathIfValid()
                            }
                            .onChange(of: droidSessionsPath) { _, _ in
                                droidSessionsPathDebounce?.cancel()
                                let work = DispatchWorkItem {
                                    validateDroidSessionsPath()
                                    commitDroidSessionsPathIfValid()
                                }
                                droidSessionsPathDebounce = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                            }
                            .help("Override where Agent Sessions scans for Droid interactive session JSONL files")
                        Button("Choose…", action: pickDroidSessionsFolder)
                            .help("Pick a folder to scan for Droid sessions")
                    }
                } label: {
                    Text("Storage Root")
                    if droidSessionsPathValid {
                        Text("Default: ~/.factory/sessions")
                    }
                }

                if !droidSessionsPathValid {
                    Text("Folder does not exist or is not a directory.")
                        .foregroundStyle(.red)
                }
            }
            .disabled(!droidAgentEnabled)

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Search Root", text: $droidProjectsPath, prompt: Text("~/.factory/projects"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateDroidProjectsPath()
                                commitDroidProjectsPathIfValid()
                            }
                            .onChange(of: droidProjectsPath) { _, _ in
                                droidProjectsPathDebounce?.cancel()
                                let work = DispatchWorkItem {
                                    validateDroidProjectsPath()
                                    commitDroidProjectsPathIfValid()
                                }
                                droidProjectsPathDebounce = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                            }
                            .help("Optional: scan for exported droid exec --output-format stream-json logs stored as JSONL")
                        Button("Choose…", action: pickDroidProjectsFolder)
                            .help("Pick a projects folder to scan for stream-json logs")
                    }
                } label: {
                    Text("Search Root")
                    if droidProjectsPathValid {
                        Text("Default: ~/.factory/projects (best-effort)")
                    }
                }

                if !droidProjectsPathValid {
                    Text("Folder does not exist or is not a directory.")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Projects Directory")
            } footer: {
                Text("Agent Sessions will only import files that match Droid’s stream-json schema to avoid false positives.")
            }
            .disabled(!droidAgentEnabled)
        }
        .onAppear {
            scheduleDroidProbe()
        }
    }
}

extension PreferencesView {
    var openClawCLITab: some View {
        PreferencesForm {
            if !openClawAgentEnabled {
                Section {
                    PreferenceCallout {
                        Text("This agent is disabled in General → Active CLI agents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle("Show deleted OpenClaw sessions", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions) }
                ))
                .help("OpenClaw auto-deletes sessions after 30 days. Shown by default with a 'deleted' badge. Disable to hide them.")
            }
            .disabled(!openClawAgentEnabled)

            Section("OpenClaw CLI Binary") {
                Picker("Binary Source", selection: Binding(
                    get: { openClawBinaryPath.isEmpty ? 0 : 1 },
                    set: { idx in
                        if idx == 0 {
                            openClawBinaryPath = ""
                            validateOpenClawBinaryPath()
                            scheduleOpenClawProbe()
                        } else {
                            pickOpenClawBinary()
                        }
                    }
                )) {
                    Text("Auto").tag(0)
                    Text("Custom").tag(1)
                }
                .pickerStyle(.segmented)
                .help("Use the auto-detected OpenClaw binary or supply a custom path")

                if openClawBinaryPath.isEmpty {
                    LabeledContent {
                        Text(openClawVersionString ?? "unknown").monospaced()
                    } label: {
                        Text("Detected:")
                        if let path = openClawResolvedPath {
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                    }

                    if openClawProbeState == .failure && openClawVersionString == nil {
                        PreferenceCallout {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("OpenClaw CLI not found")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Install OpenClaw (or clawdbot) and ensure `openclaw`/`clawdbot` is available on PATH, or set a custom binary path.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Check Version") { probeOpenClaw() }
                            .help("Query the detected OpenClaw CLI for its version")
                        Button(agentUpdateButtonTitle(for: .openclaw)) { runAgentUpdateFlow(for: .openclaw) }
                            .help("Check for a newer OpenClaw CLI version and optionally update it")
                            .disabled(isAgentUpdateBusy(.openclaw))
                        Button("Copy Path") {
                            if let p = openClawResolvedPath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p, forType: .string)
                            }
                        }
                        .help("Copy the detected OpenClaw binary path to clipboard")
                        .disabled(openClawResolvedPath == nil)
                        Button("Reveal") {
                            if let p = openClawResolvedPath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                        }
                        .help("Reveal the detected OpenClaw binary in Finder")
                        .disabled(openClawResolvedPath == nil)
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("/path/to/openclaw", text: $openClawBinaryPath, prompt: Text("/path/to/openclaw"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateOpenClawBinaryPath()
                                commitOpenClawBinaryPathIfValid()
                            }
                            .onChange(of: openClawBinaryPath) { _, _ in
                                validateOpenClawBinaryPath()
                                commitOpenClawBinaryPathIfValid()
                            }
                            .help("Enter the full path to a custom OpenClaw (or clawdbot) binary")
                        Button("Choose…", action: pickOpenClawBinary)
                            .help("Select the OpenClaw binary from the filesystem")
                        Button("Clear") {
                            openClawBinaryPath = ""
                            validateOpenClawBinaryPath()
                            scheduleOpenClawProbe()
                        }
                        .help("Remove the custom binary override")
                    }

                    if !openClawBinaryValid {
                        Text("Must be an executable file.")
                            .foregroundStyle(.red)
                    } else if openClawProbeState == .failure {
                        Text("Unable to execute the specified binary. Check the path and try again.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(!openClawAgentEnabled)

            Section("Sessions Directory") {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Storage Root", text: $openClawSessionsPath, prompt: Text("~/.openclaw"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateOpenClawSessionsPath()
                                commitOpenClawSessionsPathIfValid()
                            }
                            .onChange(of: openClawSessionsPath) { _, _ in
                                openClawSessionsPathDebounce?.cancel()
                                let work = DispatchWorkItem {
                                    validateOpenClawSessionsPath()
                                    commitOpenClawSessionsPathIfValid()
                                }
                                openClawSessionsPathDebounce = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                            }
                            .help("Override where Agent Sessions scans for OpenClaw and clawdbot transcripts")
                        Button("Choose…", action: pickOpenClawSessionsFolder)
                            .help("Pick a folder to scan for OpenClaw sessions")
                    }
                } label: {
                    Text("Storage Root")
                    if openClawSessionsPathValid {
                        Text("Default: $OPENCLAW_STATE_DIR, ~/.openclaw, or ~/.clawdbot")
                    }
                }

                if !openClawSessionsPathValid {
                    Text("Folder does not exist or is not a directory.")
                        .foregroundStyle(.red)
                }
            }
            .disabled(!openClawAgentEnabled)
        }
        .onAppear {
            scheduleOpenClawProbe()
        }
    }
}

extension PreferencesView {
    func pickDroidBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Droid CLI Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the droid executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            droidSettings.setBinaryPath(url.path)
            scheduleDroidProbe()
        }
    }

    func pickDroidSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Droid Sessions Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose a folder where Droid session logs are stored", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if !droidSessionsPath.isEmpty {
            let expanded = (droidSessionsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".factory/sessions")
        }

        if panel.runModal() == .OK, let url = panel.url {
            droidSessionsPath = url.path
            validateDroidSessionsPath()
            commitDroidSessionsPathIfValid()
        }
    }

    func pickDroidProjectsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Droid Projects Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose a folder to scan for stream-json logs", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if !droidProjectsPath.isEmpty {
            let expanded = (droidProjectsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".factory/projects")
        }

        if panel.runModal() == .OK, let url = panel.url {
            droidProjectsPath = url.path
            validateDroidProjectsPath()
            commitDroidProjectsPathIfValid()
        }
    }

    func pickOpenClawBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select OpenClaw CLI Binary", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the openclaw or clawdbot executable file", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            openClawBinaryPath = url.path
            validateOpenClawBinaryPath()
            commitOpenClawBinaryPathIfValid()
        }
    }

    func pickOpenClawSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select OpenClaw Sessions Directory", comment: "Title in a file selection panel.")
        panel.message = String(localized: "Choose the OpenClaw state folder (contains agents/*/sessions)", comment: "Instructions in a file selection panel.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if !openClawSessionsPath.isEmpty {
            let expanded = (openClawSessionsPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw")
        }

        if panel.runModal() == .OK, let url = panel.url {
            openClawSessionsPath = url.path
            validateOpenClawSessionsPath()
            commitOpenClawSessionsPathIfValid()
        }
    }

    func validateDroidSessionsPath() {
        guard !droidSessionsPath.isEmpty else {
            droidSessionsPathValid = true
            return
        }
        let expanded = (droidSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        droidSessionsPathValid = exists && isDir.boolValue
    }

    func validateDroidProjectsPath() {
        guard !droidProjectsPath.isEmpty else {
            droidProjectsPathValid = true
            return
        }
        let expanded = (droidProjectsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        droidProjectsPathValid = exists && isDir.boolValue
    }

    func validateOpenClawBinaryPath() {
        guard !openClawBinaryPath.isEmpty else {
            openClawBinaryValid = true
            return
        }
        let expanded = (openClawBinaryPath as NSString).expandingTildeInPath
        openClawBinaryValid = FileManager.default.isExecutableFile(atPath: expanded)
    }

    func validateOpenClawSessionsPath() {
        guard !openClawSessionsPath.isEmpty else {
            openClawSessionsPathValid = true
            return
        }
        let expanded = (openClawSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        openClawSessionsPathValid = exists && isDir.boolValue
    }

    func commitDroidSessionsPathIfValid() {
        guard droidSessionsPathValid else { return }
        // @AppStorage persists automatically; indexers update on refresh.
    }

    func commitDroidProjectsPathIfValid() {
        guard droidProjectsPathValid else { return }
        // @AppStorage persists automatically; indexers update on refresh.
    }

    func commitOpenClawBinaryPathIfValid() {
        guard openClawBinaryValid else { return }
        scheduleOpenClawProbe()
    }

    func commitOpenClawSessionsPathIfValid() {
        guard openClawSessionsPathValid else { return }
        // @AppStorage persists automatically; OpenClawSessionIndexer listens to UserDefaults changes.
    }
}
