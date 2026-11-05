internal import EdithExtensionSupport_attention_native
internal import EdithExtensionUI
import SwiftUI

private struct AttentionSettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    init(_ title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: UIScale.pt(16)) {
            Text(title).font(.edithText(.body))
            Spacer(minLength: 0)
            control().labelsHidden().fixedSize()
        }
        .frame(minHeight: UIScale.pt(PageMetrics.controlHeight))
    }
}

private struct AttentionToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        AttentionSettingRow(title) {
            Toggle(title, isOn: $isOn).toggleStyle(.edithSwitch)
        }
    }
}

struct AttentionSettingsView: View {
    @Bindable var model: AttentionPageModel
    @State private var ruleSearch = ""
    @State private var ignoredDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageCard {
                HStack(alignment: .center, spacing: UIScale.pt(16)) {
                    SettingsTitle(
                        "Enable Attention",
                        subtitle:
                            "Master switch for all collection. Turning it off stops application, browser, agent and music tracking without deleting history."
                    )
                    Spacer(minLength: 0)
                    Toggle(
                        "Enable Attention",
                        isOn: Binding(
                            get: { model.settings.isEnabled },
                            set: { model.setAttentionEnabled($0) })
                    )
                    .toggleStyle(.edithSwitch)
                    .labelsHidden()
                }
            }

            PageCard {
                SettingsTitle(
                    "Sources", subtitle: "Everything stays on this Mac unless iCloud backup is on.")
                AttentionToggleRow(
                    "Track foreground applications", isOn: $model.settings.trackingEnabled)
                AttentionToggleRow(
                    "Run the local browser server", isOn: $model.settings.browserTrackingEnabled)
                AttentionToggleRow(
                    "Record agent activity on every machine",
                    isOn: $model.settings.agentTrackingEnabled)
                AttentionToggleRow(
                    "Record music from Edith, Spotify and Apple Music",
                    isOn: $model.settings.mediaTrackingEnabled)
                AttentionSettingRow("Detail level") {
                    Picker("Detail level", selection: $model.settings.privacyLevel) {
                        Text("Applications only").tag(AttentionPrivacyLevel.applications)
                        Text("Domains").tag(AttentionPrivacyLevel.domains)
                        Text("Detailed").tag(AttentionPrivacyLevel.detailed)
                    }
                }
                AttentionToggleRow(
                    "Store window and page titles", isOn: $model.settings.windowTitlesEnabled)
                AttentionSettingRow("Idle after") {
                    Picker("Idle after", selection: $model.settings.idleThreshold) {
                        Text("1 minute").tag(TimeInterval(60))
                        Text("3 minutes").tag(TimeInterval(180))
                        Text("5 minutes").tag(TimeInterval(300))
                        Text("10 minutes").tag(TimeInterval(600))
                        Text("15 minutes").tag(TimeInterval(900))
                    }
                }
                Text(
                    "Changes to the idle threshold apply to future activity."
                )
                .font(.edithText(.caption))
                .foregroundStyle(.secondary)
                AttentionSettingRow("Deep work after") {
                    Picker("Deep work after", selection: $model.settings.focusBlockMinimum) {
                        Text("15 minutes").tag(TimeInterval(900))
                        Text("25 minutes").tag(TimeInterval(1_500))
                        Text("45 minutes").tag(TimeInterval(2_700))
                        Text("60 minutes").tag(TimeInterval(3_600))
                    }
                }
                if model.settings.windowTitlesEnabled {
                    Button("Grant Accessibility access for window titles") {
                        model.requestAccessibility()
                    }
                    .buttonStyle(.edith(.secondary))
                }
            }
            .disabled(!model.settings.isEnabled)

            PageCard {
                SettingsTitle(
                    "Jev categorization",
                    subtitle:
                        "When a Jev key is configured, Edith asks Jev which category fits apps and sites you have not categorized, and individual titles on mixed sites such as YouTube and X. Your own rules always win."
                )
                AttentionToggleRow(
                    "Categorize automatically every half hour",
                    isOn: $model.settings.jevCategorizationEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("About you").font(.edithText(.subheadline).weight(.semibold))
                    TextEditor(text: $model.settings.profileNote)
                        .font(.edithText(.callout))
                        .frame(minHeight: UIScale.pt(70), maxHeight: UIScale.pt(120))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    Text(
                        "Jev reads this with every question, together with examples from your own rules. Say what you do and what counts as useful for you, for example: I build developer tools, so following AI news on X and watching engineering talks helps my work, but X is still personal time."
                    )
                    .font(.edithText(.subheadline)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button {
                        model.categorizeNow()
                    } label: {
                        Text(model.categorizing ? "Asking Jev" : "Categorize now")
                    }
                    .buttonStyle(.edith(.secondary))
                    .disabled(model.categorizing || !model.settings.jevCategorizationEnabled)
                    Spacer()
                    Text(
                        "\(model.classifications.entities.values.filter(\.isDecisive).count) apps and sites, \(model.classifications.titles.values.filter(\.isDecisive).count) titles categorized by Jev"
                    )
                    .font(.edithText(.subheadline)).foregroundStyle(.secondary)
                }
            }

            BrowserInstallCard(model: model, showToken: true)

            PageCard {
                SettingsTitle(
                    "Ignored apps",
                    subtitle:
                        "Time in these apps is dropped from every summary. Use bundle identifiers, for example com.apple.finder."
                )
                ForEach(model.settings.ignoredBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID).font(.system(size: UIScale.pt(12), design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            model.settings.ignoredBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.edith(.iconOnly))
                    }
                }
                HStack {
                    TextField("Bundle identifier", text: $ignoredDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let value = ignoredDraft.trimmingCharacters(in: .whitespaces)
                        guard !value.isEmpty, !model.settings.ignoredBundleIDs.contains(value)
                        else { return }
                        model.settings.ignoredBundleIDs.append(value)
                        ignoredDraft = ""
                    }
                    .buttonStyle(.edith(.secondary))
                }
            }

            PageCard {
                SettingsTitle(
                    "iCloud backup",
                    subtitle: "Snapshots stay in your own iCloud Drive under Edith/Attention.")
                AttentionToggleRow(
                    "Back up attention data every 15 minutes",
                    isOn: $model.settings.iCloudBackupEnabled)
                HStack {
                    Button("Back up now") { model.backupNow() }
                        .buttonStyle(.edith(.secondary))
                        .disabled(model.transferringBackup)
                    Button("Restore before tracking") { model.restoreBackup() }
                        .buttonStyle(.edith(.secondary))
                        .disabled(
                            model.transferringBackup || !model.cloudBackup.backupAvailable
                                || model.hasStoredEvents)
                    Spacer()
                    if let date = model.cloudBackup.lastBackupAt {
                        Text("Last backup \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.edithText(.subheadline)).foregroundStyle(.secondary)
                    }
                }
            }

            AttentionCategoriesEditor(model: model)

            AttentionRulesEditor(model: model, search: $ruleSearch)

            HStack {
                Text("Changes apply to all history and to the collectors after saving.")
                    .font(.edithText(.subheadline)).foregroundStyle(.secondary)
                Spacer()
                Button("Save settings") { model.saveSettings() }
                    .buttonStyle(.edith(.primary))
            }
        }
    }
}

private struct AttentionCategoriesEditor: View {
    @Bindable var model: AttentionPageModel

    var body: some View {
        PageCard {
            HStack {
                SettingsTitle(
                    "Categories",
                    subtitle:
                        "Each category has a default productivity and says whether it is work or personal. Rules can override both for a single app, site, title or Edith context."
                )
                Spacer()
                Button("Add category") { model.addCategory() }
                    .buttonStyle(.edith(.secondary))
            }
            ForEach($model.settings.categories) { $category in
                let builtIn = AttentionCatalog.categories.contains { $0.id == category.id }
                HStack(spacing: 10) {
                    TextField("Name", text: $category.name)
                    Picker("Productivity", selection: $category.productivity) {
                        ForEach(AttentionProductivity.ranked, id: \.self) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .labelsHidden()
                    .frame(width: UIScale.pt(150))
                    Picker("Sphere", selection: $category.sphere) {
                        ForEach(AttentionSphere.allCases, id: \.self) { sphere in
                            Text(sphere.title).tag(sphere)
                        }
                    }
                    .labelsHidden()
                    .frame(width: UIScale.pt(160))
                    Button(role: .destructive) {
                        model.removeCategory(category.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .disabled(builtIn)
                    .help(builtIn ? "Built-in categories can be renamed but not removed" : "Remove")
                }
            }
        }
    }
}

private struct AttentionRulesEditor: View {
    @Bindable var model: AttentionPageModel
    @Binding var search: String

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let indices = model.settings.rules.indices.filter { index in
            guard !query.isEmpty else { return true }
            let rule = model.settings.rules[index]
            return
                ([rule.name] + rule.bundleIDs + rule.domains + rule.urls + rule.keywords
                + rule.contexts + rule.browserProfiles).contains { $0.lowercased().contains(query) }
        }
        PageCard {
            HStack {
                SettingsTitle(
                    "Rules",
                    subtitle:
                        "Your rules run before the \(AttentionCatalog.rules.count) built-in ones. A rule with only apps or domains names an identity; add URL prefixes, title keywords, channel or repository context, or browser profile labels to categorize part of it. Enable separate reporting to give those matches their own time totals."
                )
                Spacer()
                Button("Add rule") { model.addRule() }
                    .buttonStyle(.edith(.secondary))
            }
            TextField("Search rules", text: $search)
                .textFieldStyle(.roundedBorder)
            ForEach(indices, id: \.self) { index in
                Divider()
                AttentionRuleEditor(
                    rule: $model.settings.rules[index], categories: model.settings.categories
                ) {
                    model.removeRule(model.settings.rules[index].id)
                }
            }
        }
    }
}

private struct AttentionRuleEditor: View {
    @Binding var rule: AttentionIdentityRule
    let categories: [AttentionCategory]
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $rule.name)
                Picker("Category", selection: $rule.categoryID) {
                    ForEach(categories) { category in Text(category.name).tag(category.id) }
                }
                .labelsHidden()
                .frame(width: UIScale.pt(180))
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.edith(.iconOnly))
            }
            HStack(spacing: UIScale.pt(8)) {
                Picker("Productivity", selection: $rule.productivity) {
                    Text("Category default").tag(AttentionProductivity?.none)
                    ForEach(AttentionProductivity.ranked, id: \.self) { level in
                        Text(level.title).tag(AttentionProductivity?.some(level))
                    }
                }
                .frame(maxWidth: .infinity)
                Picker("Part of", selection: $rule.sphere) {
                    Text("Category default").tag(AttentionSphere?.none)
                    ForEach(AttentionSphere.allCases, id: \.self) { sphere in
                        Text(sphere.title).tag(AttentionSphere?.some(sphere))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .font(.edithText(.subheadline))
            AttentionToggleRow(
                "Report matches separately using this rule’s name", isOn: $rule.reportSeparately)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    field("Apps", \.bundleIDs, "com.apple.dt.Xcode, com.jetbrains.*")
                    field("Domains", \.domains, "github.com, youtube.com")
                }
                GridRow {
                    field("URL prefixes", \.urls, "github.com/owner/repo")
                    field("Title keywords", \.keywords, "swift, tutorial")
                }
                GridRow {
                    field("Context", \.contexts, "page=herdr, channel=Example, repo=owner/repo")
                    field("Browser profiles", \.browserProfiles, "Work, Personal")
                }
            }
            .font(.edithText(.subheadline))
        }
        .padding(.vertical, 4)
    }

    private func field(
        _ label: String, _ keyPath: WritableKeyPath<AttentionIdentityRule, [String]>,
        _ placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.edithText(.caption).weight(.semibold)).foregroundStyle(
                .secondary)
            TextField(
                placeholder,
                text: Binding(
                    get: { rule[keyPath: keyPath].joined(separator: ", ") },
                    set: { value in
                        rule[keyPath: keyPath] = value.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        }.filter { !$0.isEmpty }
                    })
            )
            .textFieldStyle(.roundedBorder)
        }
    }
}
