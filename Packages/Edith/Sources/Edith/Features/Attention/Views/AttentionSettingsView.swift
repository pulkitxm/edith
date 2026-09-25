import EdithKit
import SwiftUI

struct AttentionSettingsView: View {
    @Bindable var model: AttentionPageModel
    @State private var ruleSearch = ""
    @State private var ignoredDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AttentionCard {
                Toggle(
                    isOn: Binding(
                        get: { model.settings.isEnabled },
                        set: { model.setAttentionEnabled($0) })
                ) {
                    SettingsTitle(
                        "Enable Attention",
                        subtitle:
                            "Master switch for all collection. Turning it off stops application, browser, agent and music tracking without deleting history."
                    )
                }
                .toggleStyle(.switch)
            }

            AttentionCard {
                SettingsTitle(
                    "Sources", subtitle: "Everything stays on this Mac unless iCloud backup is on.")
                Toggle("Track foreground applications", isOn: $model.settings.trackingEnabled)
                Toggle("Run the local browser server", isOn: $model.settings.browserTrackingEnabled)
                Toggle(
                    "Record agent activity on every machine",
                    isOn: $model.settings.agentTrackingEnabled)
                Toggle(
                    "Record music from Edith, Spotify and Apple Music",
                    isOn: $model.settings.mediaTrackingEnabled)
                Picker("Detail level", selection: $model.settings.privacyLevel) {
                    Text("Applications only").tag(AttentionPrivacyLevel.applications)
                    Text("Domains").tag(AttentionPrivacyLevel.domains)
                    Text("Detailed").tag(AttentionPrivacyLevel.detailed)
                }
                Toggle("Store window and page titles", isOn: $model.settings.windowTitlesEnabled)
                HStack {
                    Picker("Idle after", selection: $model.settings.idleThreshold) {
                        Text("1 minute").tag(TimeInterval(60))
                        Text("3 minutes").tag(TimeInterval(180))
                        Text("5 minutes").tag(TimeInterval(300))
                        Text("10 minutes").tag(TimeInterval(600))
                        Text("15 minutes").tag(TimeInterval(900))
                    }
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

            AttentionCard {
                SettingsTitle(
                    "Jev categorization",
                    subtitle:
                        "When a Jev key is configured, Edith asks Jev which category fits apps and sites you have not categorized, and individual titles on mixed sites such as YouTube and X. Your own rules always win."
                )
                Toggle(
                    "Categorize automatically every half hour",
                    isOn: $model.settings.jevCategorizationEnabled)
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
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            BrowserInstallCard(model: model, showToken: true)

            AttentionCard {
                SettingsTitle(
                    "Ignored apps",
                    subtitle:
                        "Time in these apps is dropped from every summary. Use bundle identifiers, for example com.apple.finder."
                )
                ForEach(model.settings.ignoredBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID).font(.system(size: 12, design: .monospaced))
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

            AttentionCard {
                SettingsTitle(
                    "iCloud backup",
                    subtitle: "Snapshots stay in your own iCloud Drive under Edith/Attention.")
                Toggle(
                    "Back up attention data every 15 minutes",
                    isOn: $model.settings.iCloudBackupEnabled)
                HStack {
                    Button("Back up now") { model.backupNow() }
                        .buttonStyle(.edith(.secondary))
                        .disabled(model.transferringBackup)
                    Button("Restore before tracking") { model.restoreBackup() }
                        .buttonStyle(.edith(.secondary))
                        .disabled(
                            model.transferringBackup || !model.cloudBackup.available
                                || model.hasStoredEvents)
                    Spacer()
                    if let date = model.cloudBackup.lastBackupAt {
                        Text("Last backup \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }

            AttentionCategoriesEditor(model: model)

            AttentionRulesEditor(model: model, search: $ruleSearch)

            HStack {
                Text("Changes apply to all history and to the collectors after saving.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
        AttentionCard {
            HStack {
                SettingsTitle(
                    "Categories",
                    subtitle:
                        "The kind decides whether time counts as productive, communication, distracting or neutral."
                )
                Spacer()
                Button("Add category") { model.addCategory() }
                    .buttonStyle(.edith(.secondary))
            }
            ForEach($model.settings.categories) { $category in
                let builtIn = AttentionCatalog.categories.contains { $0.id == category.id }
                HStack(spacing: 10) {
                    ColorPicker(
                        "Color",
                        selection: Binding(
                            get: { AttentionPalette.hex(category.color) ?? .gray },
                            set: { category.color = AttentionPalette.hexString($0) }),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    TextField("Name", text: $category.name)
                    Picker("Kind", selection: $category.kind) {
                        ForEach(AttentionCategoryKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
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
                + rule.contexts).contains { $0.lowercased().contains(query) }
        }
        AttentionCard {
            HStack {
                SettingsTitle(
                    "Rules",
                    subtitle:
                        "Your rules run before the \(AttentionCatalog.rules.count) built-in ones. A rule with only apps or domains names an identity; add URL prefixes, title keywords or Edith context such as page=herdr or machine=tuf to categorize just part of it."
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
                .frame(width: 180)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.edith(.iconOnly))
            }
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
                    field("Edith context", \.contexts, "page=herdr, machine=tuf, agent=Codex")
                        .gridCellColumns(2)
                }
            }
            .font(.system(size: 11))
        }
        .padding(.vertical, 4)
    }

    private func field(
        _ label: String, _ keyPath: WritableKeyPath<AttentionIdentityRule, [String]>,
        _ placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
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
