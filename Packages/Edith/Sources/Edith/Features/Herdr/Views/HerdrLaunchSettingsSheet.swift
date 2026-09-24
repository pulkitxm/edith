import EdithKit
import SwiftUI

struct HerdrLaunchSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(HerdrLaunchSettings.kinds, id: \.self) { kind in
                        HerdrLaunchKindRow(kind: kind)
                        if kind != HerdrLaunchSettings.kinds.last { Divider() }
                    }
                }
            }
        }
        .frame(width: UIScale.pt(580), height: UIScale.pt(560))
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("Agent Launch Settings")
                    .font(.system(size: UIScale.pt(16), weight: .semibold))
                Text("The command, model, effort and fast mode used when you launch each agent.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.edith(.borderless))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(UIScale.pt(18))
    }
}

private struct HerdrLaunchKindRow: View {
    let kind: String
    @State private var command = ""
    @State private var options = AgentLaunchOptions.none
    @State private var catalog: AgentLaunchCatalog?
    @State private var refreshes = 0
    @State private var loading = false

    private var launchKind: AgentLaunchKind? { AgentLaunchKind(kind: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            commandLine
            if let catalog {
                if catalog.kind.selectsAtLaunch {
                    choices(catalog)
                    ForEach(catalog.explanations(for: options), id: \.self) { line in
                        Text(line)
                    }
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(.secondary)
                    .padding(.leading, UIScale.pt(106))
                } else {
                    listing(catalog)
                }
            }
        }
        .padding(.horizontal, UIScale.pt(18))
        .padding(.vertical, UIScale.pt(10))
        .onAppear(perform: reload)
        .task(id: refreshes) { await loadCatalog() }
    }

    private var commandLine: some View {
        HStack(spacing: UIScale.pt(10)) {
            HerdrKindMark(kind: kind, size: UIScale.pt(16))
            Text(kind)
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .frame(width: UIScale.pt(80), alignment: .leading)
            TextField(
                "Command",
                text: Binding(
                    get: { command },
                    set: { newValue in
                        command = newValue
                        HerdrLaunchSettings.setCommand(newValue, for: kind)
                    })
            )
            .textFieldStyle(.roundedBorder)
            Button("Reset") {
                HerdrLaunchSettings.resetToDefault(for: kind)
                command = HerdrLaunchSettings.command(for: kind)
            }
            .buttonStyle(.edith(.borderless))
            .font(.system(size: UIScale.pt(11)))
            .disabled(HerdrLaunchSettings.usesHerdrAgentStart(for: kind))
        }
    }

    private func choices(_ catalog: AgentLaunchCatalog) -> some View {
        let chosen = catalog.model(options.model)
        return HStack(spacing: UIScale.pt(8)) {
            Text("Model")
            Picker("Model", selection: binding(\.model)) {
                Text("CLI default").tag(String?.none)
                ForEach(catalog.pickerModels(including: options.model)) { model in
                    Text(model.name).tag(Optional(model.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: UIScale.pt(170), alignment: .leading)
            .help("The model \(kind) starts with")
            if !chosen.efforts.isEmpty {
                Text(catalog.kind.effortLabel)
                Picker(catalog.kind.effortLabel, selection: binding(\.effort)) {
                    Text("Default").tag(String?.none)
                    ForEach(chosen.efforts) { effort in
                        Text(effort.id).tag(Optional(effort.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: UIScale.pt(100), alignment: .leading)
                .help("How hard the model thinks before it answers")
            }
            if let fast = chosen.fastSummary {
                Toggle("Fast", isOn: binding(\.fast))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help(fast)
            }
            Spacer(minLength: 0)
            source(catalog)
        }
        .font(.system(size: UIScale.pt(11)))
        .padding(.leading, UIScale.pt(26))
    }

    private func listing(_ catalog: AgentLaunchCatalog) -> some View {
        HStack(spacing: UIScale.pt(10)) {
            Menu("\(catalog.models.count) models") {
                ForEach(catalog.models) { model in
                    Text(model.id)
                }
            }
            .fixedSize()
            .disabled(catalog.models.isEmpty)
            if let note = catalog.kind.note {
                Text(note)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            source(catalog)
        }
        .font(.system(size: UIScale.pt(11)))
        .padding(.leading, UIScale.pt(26))
    }

    private func source(_ catalog: AgentLaunchCatalog) -> some View {
        HStack(spacing: UIScale.pt(4)) {
            Text(catalog.source.label)
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(.secondary)
                .help(catalog.kind.note ?? "Where this model list came from")
            if let tool = catalog.kind.discoveryCommand {
                Button {
                    refreshes += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                }
                .buttonStyle(.edith(.borderless))
                .disabled(loading)
                .help("Ask \(tool) for its models again")
                .accessibilityLabel("Refresh \(kind) models")
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentLaunchOptions, Value>)
        -> Binding<Value>
    {
        Binding(
            get: { options[keyPath: keyPath] },
            set: { value in
                var next = options
                next[keyPath: keyPath] = value
                if let catalog { next = AgentLaunchArguments.sanitized(next, in: catalog) }
                options = next
                HerdrLaunchSettings.setOptions(next, for: kind)
            })
    }

    private func reload() {
        command = HerdrLaunchSettings.command(for: kind)
        options = HerdrLaunchSettings.options(for: kind)
        if catalog == nil { catalog = launchKind?.builtIn }
    }

    private func loadCatalog() async {
        guard let launchKind, launchKind.discoveryCommand != nil else { return }
        loading = true
        let loaded = await AgentLaunchCatalogs.shared.catalog(
            for: launchKind, refresh: refreshes > 0)
        guard !Task.isCancelled else { return }
        catalog = loaded
        loading = false
    }
}
