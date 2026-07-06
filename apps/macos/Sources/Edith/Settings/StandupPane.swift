import AppKit
import EdithKit
import SwiftUI

struct StandupPane: View {
    @AppStorage("standupEnabled", store: SharedDefaults.store) private var enabled = false
    @AppStorage("standupScheduleHour", store: SharedDefaults.store) private var scheduleHour = 9
    @AppStorage("standupScheduleMinute", store: SharedDefaults.store) private var scheduleMinute =
        30
    @AppStorage("standupRepoRoots", store: SharedDefaults.store) private var repoRootsRaw = ""
    @AppStorage("standupAuthorEmail", store: SharedDefaults.store) private var authorEmail = ""
    @AppStorage("standupNotionDatabaseID", store: SharedDefaults.store)
    private var notionDatabaseID = ""
    @AppStorage("standupNotionTagsProperty", store: SharedDefaults.store)
    private var notionTagsProperty = "Tags"
    @AppStorage("standupWorkTag", store: SharedDefaults.store) private var workTag = "work"
    @AppStorage("standupModel", store: SharedDefaults.store) private var model = "haiku"
    @AppStorage("standupDeliverNotification", store: SharedDefaults.store)
    private var deliverNotification = true
    @AppStorage("standupDeliverFile", store: SharedDefaults.store) private var deliverFile = true
    @AppStorage("standupGithubAllowlist", store: SharedDefaults.store)
    private var githubAllowlistRaw = ""

    @State private var notionToken = ""
    @State private var hasStoredToken = StandupKeychain.get() != nil
    @State private var ghStatus = "Checking…"
    @State private var historyQuery = ""
    @State private var history: [StandupHistory.Entry] = []
    @State private var expanded: Set<String> = []

    private var repoRoots: [String] { StandupSettings.splitLines(repoRootsRaw) }

    private var scheduleTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: scheduleHour, minute: scheduleMinute, second: 0, of: Date())
                    ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                scheduleHour = c.hour ?? 9
                scheduleMinute = c.minute ?? 30
            })
    }

    private var filteredHistory: [StandupHistory.Entry] {
        guard !historyQuery.isEmpty else { return history }
        return history.filter {
            $0.content.localizedCaseInsensitiveContains(historyQuery)
                || $0.id.localizedCaseInsensitiveContains(historyQuery)
        }
    }

    var body: some View {
        Form {
            enableSection
            scheduleSection
            reposSection
            authorSection
            githubSection
            notionSection
            deliverySection
            historySection
        }
        .formStyle(.grouped)
        .navigationTitle("Standup")
        .onAppear {
            if authorEmail.isEmpty { loadDefaultAuthorEmail() }
            checkGHStatus()
            history = StandupHistory.load()
        }
    }

    private var enableSection: some View {
        Section {
            Toggle("Enable standup", isOn: $enabled)
                .pointerCursor()
            Text("When off, nothing is scheduled and nothing loads.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scheduleSection: some View {
        Section {
            HStack {
                DatePicker(
                    "Schedule time", selection: scheduleTime, displayedComponents: .hourAndMinute
                )
                .pointerCursor()
                InfoDot(
                    "When the standup generates. If the Mac was asleep, it catches up on wake; if it was off, at next launch."
                )
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var reposSection: some View {
        Section {
            ForEach(repoRoots, id: \.self) { root in
                HStack {
                    Text(root).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        removeRepoRoot(root)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            Button("Add folder…", action: addRepoRoot)
                .pointerCursor()
        } header: {
            Text("Repo folders")
        } footer: {
            Text("Folders scanned two levels deep for git repositories.")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var authorSection: some View {
        Section {
            TextField("Git author email", text: $authorEmail)
                .textFieldStyle(.roundedBorder)
            Text("Commits matching this author count as yours. Defaults from git config.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var githubSection: some View {
        Section {
            LabeledContent("GitHub") { Text(ghStatus).foregroundStyle(.secondary) }
            Text("Uses your existing gh CLI login; nothing to configure if gh works in a terminal.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Restrict to org/repo (optional, comma-separated)", text: $githubAllowlistRaw)
                .textFieldStyle(.roundedBorder)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var notionSection: some View {
        Section {
            SecureField("Notion integration token", text: $notionToken)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveNotionToken)
            HStack {
                Text(hasStoredToken ? "Token saved" : "No token set")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save", action: saveNotionToken)
                    .pointerCursor()
                    .disabled(notionToken.isEmpty)
            }
            TextField("Agents board database ID", text: $notionDatabaseID)
                .textFieldStyle(.roundedBorder)
            Text(
                "An internal-integration token (stored in the Keychain) and the agents board to pull runs from."
            )
            .font(.caption).foregroundStyle(.secondary)
            TextField("Tag property", text: $notionTagsProperty)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Work tag", text: $workTag)
                    .textFieldStyle(.roundedBorder)
                InfoDot(
                    "Only Notion rows with this tag are included - keeps personal projects out of standup."
                )
            }
        } header: {
            Text("Notion token & board")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var deliverySection: some View {
        Section {
            HStack {
                Picker("Model", selection: $model) {
                    Text("Haiku").tag("haiku")
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                }
                InfoDot(
                    "The Claude model that writes the summary. Haiku is plenty and cheapest against plan limits."
                )
            }
            Toggle("Notification", isOn: $deliverNotification)
                .pointerCursor()
            Toggle("Markdown file", isOn: $deliverFile)
                .pointerCursor()
            Text(
                "Notification with a Copy button, and/or the markdown file. The pane keeps history either way."
            )
            .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Delivery")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var historySection: some View {
        Section {
            TextField("Search standups", text: $historyQuery)
                .textFieldStyle(.roundedBorder)
            if filteredHistory.isEmpty {
                Text("No standups yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(filteredHistory) { entry in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expanded.contains(entry.id) },
                        set: { open in
                            if open { expanded.insert(entry.id) } else { expanded.remove(entry.id) }
                        })
                ) {
                    Text(entry.content)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                }
            }
        } header: {
            Text("History")
        }
    }

    private func addRepoRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var roots = repoRoots
        guard !roots.contains(url.path) else { return }
        roots.append(url.path)
        repoRootsRaw = roots.joined(separator: "\n")
    }

    private func removeRepoRoot(_ path: String) {
        repoRootsRaw = repoRoots.filter { $0 != path }.joined(separator: "\n")
    }

    private func saveNotionToken() {
        guard !notionToken.isEmpty else { return }
        StandupKeychain.set(notionToken)
        notionToken = ""
        hasStoredToken = true
    }

    private func loadDefaultAuthorEmail() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["config", "user.email"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return }
        authorEmail = value
    }

    private func checkGHStatus() {
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lic", "gh auth status"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            guard (try? p.run()) != nil else {
                await MainActor.run { ghStatus = "gh CLI not found" }
                return
            }
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            await MainActor.run { ghStatus = ok ? "Logged in" : "Not logged in" }
        }
    }
}
