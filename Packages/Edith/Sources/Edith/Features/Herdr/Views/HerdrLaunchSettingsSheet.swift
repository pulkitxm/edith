import AppKit
import EdithKit
import SwiftUI

struct HerdrLaunchSettingsSheet: View {
    var accounts = ClaudeAccountsModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ClaudeAccountSettings(accounts: accounts).padding(UIScale.pt(18))
                    Divider()
                    ClaudeSharedLaunchSettings().padding(UIScale.pt(18))
                    Divider()
                    ForEach(HerdrLaunchSettings.kinds, id: \.self) { kind in
                        HerdrLaunchKindRow(kind: kind)
                        if kind != HerdrLaunchSettings.kinds.last { Divider() }
                    }
                }
            }
        }
        .frame(width: PresentationMetrics.width(580), height: PresentationMetrics.height(560))
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
    @State private var catalogLoad = ContentLoad()
    private var loading: Bool { catalogLoad.isRunning }

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
        .pageTask(id: refreshes, cancel: { catalogLoad.cancel() }) { await loadCatalog() }
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
        let refresh = refreshes > 0
        await catalogLoad.perform(operation: {
            await AgentLaunchCatalogs.shared.catalog(for: launchKind, refresh: refresh)
        }) { catalog = $0 }
    }
}

struct ClaudeSharedLaunchSettings: View {
    var defaults: UserDefaults = SharedDefaults.store
    @State private var arguments = ""
    @State private var environment = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text("Claude launch options").font(.edithText(.headline))
            Text(
                "Shared by all Claude accounts on this Mac and used for local and remote sessions."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Additional arguments, one per line").font(.edithText(.caption))
            ShellInputEditor(text: $arguments, label: "Shared Claude launch arguments")
                .frame(height: UIScale.pt(48))
                .accessibilityLabel("Shared Claude launch arguments")
            Text("Environment variables, NAME=value per line").font(.edithText(.caption))
            ShellInputEditor(text: $environment, label: "Shared Claude launch environment")
                .frame(height: UIScale.pt(48))
                .accessibilityLabel("Shared Claude launch environment")
            Text(
                "Added to the configured command, including aliases such as cc. Put flag values on their own lines."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Save launch options") {
                do {
                    try HerdrLaunchSettings.setSharedClaudeLaunch(
                        arguments: arguments, environment: environment, in: defaults)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
            if let error { Text(error).font(.edithText(.caption)).foregroundStyle(.red) }
        }
        .onAppear {
            arguments = HerdrLaunchSettings.sharedArguments(in: defaults)
            environment = HerdrLaunchSettings.sharedEnvironment(in: defaults)
        }
    }
}

struct ShellInputEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let editor = scrollView.documentView as! NSTextView
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.textContainerInset = NSSize(width: 5, height: 4)
        editor.delegate = context.coordinator
        configure(editor)
        return scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.text = $text
        configure(view.documentView as! NSTextView)
    }

    private func configure(_ editor: NSTextView) {
        editor.isEditable = isEnabled
        editor.font = .monospacedSystemFont(ofSize: UIScale.pt(11), weight: .regular)
        editor.textColor = .labelColor
        editor.setAccessibilityLabel(label)
        if editor.string != text { editor.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}
