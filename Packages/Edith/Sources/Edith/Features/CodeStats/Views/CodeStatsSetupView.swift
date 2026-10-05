import EdithKit
import SwiftUI

struct CodeStatsSetupView: View {
    let model: CodeStatsModel
    let choose: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @State private var newIdentity = ""

    static let largeMirrorWarningBytes: Int64 = 20_000_000_000

    private var dark: Bool { scheme == .dark }

    var body: some View {
        PageCard(
            title: "Set up Code Stats", note: "Mirror your GitHub and count your commits"
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                folderStep
                step(
                    "git", done: model.status?.gitAvailable == true,
                    detail: model.status?.gitAvailable == true
                        ? "Installed" : "git is needed to mirror and read repositories."
                ) {
                    if model.status?.gitAvailable == false {
                        CodeStatsCommandHint(command: "ed tools install git", dark: dark)
                    }
                }
                githubStep
                identityStep
                scheduleStep
                HStack {
                    Spacer()
                    Button {
                        Task { await model.start() }
                    } label: {
                        Label("Start first sync", systemImage: "play.fill")
                    }
                    .buttonStyle(.edith(.primary))
                    .controlSize(.large)
                    .disabled(!model.canStart)
                }
            }
        }
        .task {
            guard automaticActionsEnabled else { return }
            await model.loadProfileIfNeeded()
        }
    }

    private var folderStep: some View {
        let storage = model.status?.storage ?? .notConfigured
        return step(
            "Mirror folder", done: storage.isReady,
            detail: model.status?.settings.folder
                ?? "Every repository you can reach is kept here as a bare clone."
        ) {
            HStack(spacing: UIScale.pt(10)) {
                Button("Choose folder...", action: choose)
                if case .ready(let free?) = storage {
                    Text(
                        ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
                    )
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    if free < Self.largeMirrorWarningBytes {
                        Label(
                            "Low space for a large mirror", systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(DashSkin.warn)
                    }
                } else if storage != .notConfigured {
                    Text(storage.summary).foregroundStyle(DashSkin.warn)
                }
            }
            .font(.system(size: UIScale.pt(12)))
            Text(
                "The mirror can take several gigabytes. An external drive works; results stay visible while it is unplugged."
            )
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(DashSkin.inkFaint(dark))
        }
    }

    private var githubStep: some View {
        let lookup = model.profileLookup
        return step(
            "GitHub", done: lookup?.profile != nil,
            detail: lookup?.issue.map { CodeStatsBanner.github($0).message }
                ?? (lookup == nil ? "Checking the GitHub CLI..." : "Signed in")
        ) {
            if let profile = lookup?.profile {
                CodeStatsProfileBadge(profile: profile, dark: dark)
            } else if let issue = lookup?.issue {
                HStack(spacing: UIScale.pt(10)) {
                    if let command = CodeStatsBanner.github(issue).command {
                        CodeStatsCommandHint(command: command, dark: dark)
                    }
                    Button(model.profileLoading ? "Checking..." : "Check again") {
                        Task { await model.loadProfile() }
                    }
                    .disabled(model.profileLoading)
                }
            }
        }
    }

    private var identityStep: some View {
        step(
            "Your identities", done: !model.identity.isEmpty,
            detail:
                "Commits whose email matches, or whose name or email contains a fragment, count as yours."
        ) {
            if let seeded = model.seededIdentity {
                HStack {
                    Text("From your profile: " + seeded.labels.joined(separator: ", "))
                        .lineLimit(2)
                    Button("Use these") { model.useSeededIdentity() }
                }
                .font(.system(size: UIScale.pt(12)))
            }
            CodeStatsIdentityChips(
                labels: model.identity.labels, dark: dark, remove: model.removeIdentity)
            HStack {
                TextField("Email or name fragment", text: $newIdentity)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: UIScale.pt(280))
                    .onSubmit(addIdentity)
                Button("Add", action: addIdentity)
                    .disabled(newIdentity.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(model.authorsLoading ? "Finding authors..." : "Find authors in the folder") {
                    Task { await model.discoverAuthors() }
                }
                .disabled(model.authorsLoading || model.status?.storage.isReady != true)
            }
            ForEach(model.authors.prefix(8)) { author in
                HStack {
                    Text("\(author.name) <\(author.email)>").lineLimit(1)
                    Text(CodeStatsNumberFormat.grouped(author.commits) + " commits")
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    Spacer()
                    if author.countedAsYou {
                        Label("Counted as you", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(DashSkin.ok)
                    } else {
                        Button("Add") { model.addIdentity(author.email) }
                    }
                }
                .font(.system(size: UIScale.pt(12)))
            }
        }
    }

    private var scheduleStep: some View {
        step(
            "Schedule", done: true,
            detail:
                "A refresh missed while the Mac slept or the drive was unplugged runs once as soon as it can."
        ) {
            EdithSegmentedPicker(
                "Refresh",
                selection: Binding(
                    get: { CodeStatsScheduleKind(model.schedule) },
                    set: { kind in Task { await model.setSchedule(kind) } }),
                options: [CodeStatsScheduleKind.manual, .daily, .weekly],
                label: {
                    switch $0 {
                    case .manual: "Manually"
                    case .daily: "Daily"
                    case .weekly: "Weekly"
                    }
                }
            )
            .labelsHidden()
            .fixedSize()
        }
    }

    private func addIdentity() {
        model.addIdentity(newIdentity)
        newIdentity = ""
    }

    private func step<Content: View>(
        _ title: String, done: Bool, detail: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(12)) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: UIScale.pt(17)))
                .foregroundStyle(done ? DashSkin.ok : DashSkin.inkFaint(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Text(title)
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(detail)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CodeStatsIdentityChips: View {
    let labels: [String]
    let dark: Bool
    let remove: (String) -> Void

    var body: some View {
        if !labels.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: UIScale.pt(180)), alignment: .leading)],
                alignment: .leading, spacing: UIScale.pt(6)
            ) {
                ForEach(labels, id: \.self) { label in
                    HStack(spacing: UIScale.pt(4)) {
                        Text(label).lineLimit(1).truncationMode(.middle)
                        Button {
                            remove(
                                label.hasPrefix("*") ? String(label.dropFirst().dropLast()) : label)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.edith(.borderless))
                        .accessibilityLabel("Remove \(label)")
                    }
                    .font(.system(size: UIScale.pt(11.5)))
                    .padding(.horizontal, UIScale.pt(8))
                    .padding(.vertical, UIScale.pt(3))
                    .widgetBar(
                        cornerRadius: 8, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
                }
            }
        }
    }
}
