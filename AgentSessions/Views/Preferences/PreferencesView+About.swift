import SwiftUI
import AppKit

extension PreferencesView {

    var aboutTab: some View {
        PreferencesForm {
            Section {
                VStack(spacing: 8) {
                    if let appIcon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    Text("Agent Sessions")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                labeledRow("Version:") {
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text(version)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text("Unknown")
                            .foregroundStyle(.secondary)
                    }
                }

                labeledRow("Security & Privacy:") {
                    Button("Security & Privacy") {
                        UpdateCheckModel.shared.openURL("https://github.com/jazzyalex/agent-sessions/blob/main/docs/security.md")
                    }
                    .buttonStyle(.link)
                }

                labeledRow("License:") {
                    Button("MIT License") {
                        UpdateCheckModel.shared.openURL("https://github.com/jazzyalex/agent-sessions/blob/main/LICENSE")
                    }
                    .buttonStyle(.link)
                }

                labeledRow("Website:") {
                    Button("jazzyalex.github.io/agent-sessions") {
                        UpdateCheckModel.shared.openURL("https://jazzyalex.github.io/agent-sessions/")
                    }
                    .buttonStyle(.link)
                }

                labeledRow("GitHub:") {
                    Button("github.com/jazzyalex/agent-sessions") {
                        UpdateCheckModel.shared.openURL("https://github.com/jazzyalex/agent-sessions")
                    }
                    .buttonStyle(.link)
                }

                labeledRow("X (Twitter):") {
                    Button("@jazzyalex") {
                        UpdateCheckModel.shared.openURL("https://x.com/jazzyalex")
                    }
                    .buttonStyle(.link)
                }
            }

            Section("Updates") {
                if updaterController.hasGentleReminder {
                    PreferenceCallout(
                        iconName: "exclamationmark.circle.fill",
                        tint: .blue,
                        backgroundColor: Color.blue.opacity(0.12)
                    ) {
                        Text("An update is available")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                }

                Toggle("Auto-Update", isOn: Binding(
                    get: { updaterController.autoUpdateEnabled },
                    set: { updaterController.autoUpdateEnabled = $0 }
                ))
                .help("Automatically download and install app updates")
                .disabled(updaterController.updater == nil)

                HStack {
                    Spacer()
                    Button("Check for Updates...") {
                        updaterController.checkForUpdates(nil)
                    }
                    .help("Check for new versions and install updates")
                }
            }

            Section("Diagnostics") {
                // Stays a row above the Email link (the copy says "below").
                Text("Crash reports are collected locally. Use the email link below to open a pre-filled report email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                labeledRow("Email:") {
                    Button("jazzyalex@gmail.com") {
                        sendPendingCrashReports()
                    }
                    .buttonStyle(.link)
                    .help("Open a pre-filled email draft with the latest crash report in the message body.")
                }

                labeledRow("Pending reports:") {
                    Text("\(crashPendingCount)")
                        .font(.system(.body, design: .monospaced))
                }

                labeledRow("Last detected:") {
                    if let date = crashLastDetectedAt {
                        Text(AppDateFormatting.dateTimeMedium(date))
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                }

                labeledRow("Last email draft:") {
                    if let date = crashLastSendAt {
                        Text(AppDateFormatting.dateTimeMedium(date))
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }

                if let sendError = crashLastSendError, !sendError.isEmpty {
                    PreferenceCallout(
                        iconName: "exclamationmark.triangle.fill",
                        tint: .orange
                    ) {
                        Text(sendError)
                            .font(.caption)
                    }
                }

                HStack(spacing: 8) {
                    Spacer()

                    Button(isCrashSendRunning ? "Preparing..." : "Email Crash Report") {
                        sendPendingCrashReports()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCrashSendRunning || crashPendingCount == 0)
                    .help("Open the default email app with a pre-filled crash report draft.")

                    Button("Export Report") {
                        exportLatestCrashReport()
                    }
                    .disabled(crashPendingCount == 0)
                    .help("Export the most recent queued crash report as JSON.")

                    Button("Clear Pending") {
                        showCrashClearConfirm = true
                    }
                    .disabled(crashPendingCount == 0)
                    .help("Delete all queued crash reports from local storage.")
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { showingResetConfirm = true }
                        .help("Revert all settings to their original values")
                }
            }
        }
        .onAppear {
            refreshCrashDiagnosticsState()
        }
        .alert("Crash Reports", isPresented: $showCrashSendResult) {
            Button("Close", role: .cancel) {}
        } message: {
            Text(crashSendResultMessage)
        }
        .alert("Clear Pending Crash Reports?", isPresented: $showCrashClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                clearPendingCrashReports()
            }
        } message: {
            Text("This removes all queued crash reports from local storage.")
        }
        .alert("Export Failed", isPresented: $showCrashExportError) {
            Button("Close", role: .cancel) {}
        } message: {
            Text(crashExportErrorMessage)
        }
    }

}
