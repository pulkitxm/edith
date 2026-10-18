import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HostUpdatesPane: View {
    let updater: HostUpdater
    @State private var showingSchedule = false

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private var automaticDownloads: Binding<Bool> {
        Binding(
            get: { updater.automaticallyDownloadsUpdates },
            set: { value in
                SharedDefaults.store.set(value, forKey: AppStorageKeys.Update.automaticDownloads)
                updater.automaticallyDownloadsUpdates = value
            })
    }

    var body: some View {
        Group {
            if updater.updaterAvailable {
                Form {
                    Section {
                        LabeledContent("Current version") {
                            Text(currentVersion)
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Last checked") {
                            if let date = updater.lastUpdateCheckDate {
                                Text(date, format: .dateTime.year().month().day().hour().minute())
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Never")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Check for Updates") {
                            updater.checkForUpdates()
                        }
                        .disabled(!updater.canCheckForUpdates)
                    } header: {
                        Text("Version")
                    }

                    Section {
                        Toggle("Automatic updates", isOn: automaticDownloads)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .highPriorityGesture(
                                TapGesture().modifiers(.command).onEnded {
                                    showingSchedule = true
                                }
                            )
                            .edithSheet(isPresented: $showingSchedule) {
                                HostUpdateSchedulePanel(updater: updater)
                            }
                            .accessibilityHint(
                                "Command-click to configure the check schedule and see history")
                    } header: {
                        Text("Updates")
                    }
                }
                .edithForm()
            } else {
                Text("Updates are unavailable in this build")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Updates")
    }
}
