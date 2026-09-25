import AppKit
import EdithKit
import EdithStudio
import SwiftUI

struct StudioRunnerView: View {
    let model: StudioModel
    let job: StudioJob
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            StudioBackBar(
                title: job.tool.title, subtitle: job.tool.summary, symbol: job.tool.symbolName,
                back: model.goHome
            ) {
                if case .finished = job.phase {
                    Button("Run again") { job.reset() }
                        .buttonStyle(.edith(.secondary))
                }
            }
            Divider()
            HStack(spacing: 0) {
                Group {
                    if job.phase == .finished, let result = job.result {
                        StudioResultView(model: model, job: job, result: result)
                    } else {
                        StudioInputsPanel(model: model, job: job)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StudioOptionsPanel(model: model, job: job)
                    .frame(width: UIScale.pt(330))
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .overlay {
            if job.isRunning {
                StudioProgressCard(job: job)
            }
        }
    }
}

struct StudioInputsPanel: View {
    let model: StudioModel
    let job: StudioJob
    @Environment(\.colorScheme) private var scheme

    private var ordered: Bool {
        if case .combine = job.tool.arity { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                StudioEngineBanner(model: model, tool: job.tool)
                if job.tool.needsFiles {
                    HStack {
                        Text(heading)
                            .font(.system(size: UIScale.pt(13), weight: .semibold))
                        Spacer()
                        Button {
                            choose()
                        } label: {
                            Label("Add files", systemImage: "plus")
                        }
                        .buttonStyle(.edith(.secondary))
                    }
                    if job.inputs.isEmpty {
                        StudioInputsDropZone(tool: job.tool, choose: choose)
                    } else {
                        if StudioPreview.supports(job.tool) {
                            StudioPreviewPanel(job: job, environment: model.environment)
                        }
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: UIScale.pt(150)), spacing: UIScale.pt(12))
                            ],
                            alignment: .leading, spacing: UIScale.pt(12)
                        ) {
                            ForEach(Array(job.inputs.enumerated()), id: \.element) { index, url in
                                StudioInputTile(
                                    job: job, url: url, index: index, ordered: ordered,
                                    facts: model.facts[url]
                                )
                                .task(id: url) { await model.loadFacts(for: url) }
                            }
                        }
                        if ordered {
                            Text("Files are used in this order. Use the arrows to change it.")
                                .font(.system(size: UIScale.pt(11)))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    StudioEmptyNote(
                        symbol: job.tool.symbolName,
                        text: "This tool does not need files. Fill in the settings and run it.")
                }
            }
            .padding(UIScale.pt(20))
        }
    }

    private var heading: String {
        let count = job.inputs.count
        let accepted = StudioInputText.accepted(job.tool)
        return count == 0 ? "Add \(accepted)" : "\(count) file\(count == 1 ? "" : "s")"
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = "Choose \(StudioInputText.accepted(job.tool)) for \(job.tool.title)."
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                model.add(panel.urls)
                job.add(panel.urls)
            }
        }
    }
}

enum StudioInputText {
    static func accepted(_ tool: StudioTool) -> String {
        let kinds = StudioKind.allCases.filter { tool.inputs.contains($0) }
        if kinds.count >= 6 { return "files" }
        let names = kinds.map { $0.pluralTitle.lowercased() }
        let extras = tool.extraExtensions.sorted().map { $0.uppercased() }
        return (names + extras).joined(separator: ", ")
    }
}

struct StudioInputsDropZone: View {
    let tool: StudioTool
    let choose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: UIScale.pt(10)) {
            Image(systemName: tool.symbolName)
                .font(.system(size: UIScale.pt(30), weight: .light))
                .foregroundStyle(StudioPalette.tint(for: tool))
            Text("Drop \(StudioInputText.accepted(tool)) here")
                .font(.system(size: UIScale.pt(14), weight: .semibold))
            if tool.arity.minimum > 1 {
                Text("Add at least \(tool.arity.minimum) files.")
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(.secondary)
            }
            Button("Choose files", action: choose)
                .buttonStyle(.edith(.primary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(46))
        .background(
            DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(14))
                .strokeBorder(
                    DashSkin.lineStrong(scheme == .dark),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
    }
}

struct StudioInputTile: View {
    let job: StudioJob
    let url: URL
    let index: Int
    let ordered: Bool
    let facts: StudioFileFacts?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            ZStack(alignment: .topTrailing) {
                StudioThumbnail(url: url, side: 160)
                    .frame(height: UIScale.pt(110))
                Button {
                    job.remove(url)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: UIScale.pt(15)))
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(DashSkin.paper2(scheme == .dark)).padding(2))
                }
                .buttonStyle(.edith(.iconOnly))
                .padding(UIScale.pt(5))
                .disabled(job.isRunning)
                .help("Remove from this run")
                if ordered {
                    Text("\(index + 1)")
                        .font(DashSkin.mono(10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: UIScale.pt(20), height: UIScale.pt(20))
                        .background(DashSkin.accent(scheme == .dark), in: Circle())
                        .padding(UIScale.pt(6))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Text(url.lastPathComponent)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: UIScale.pt(4)) {
                Text(StudioFileActions.describe(facts, kind: url.studioKind))
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if ordered {
                    Button {
                        job.move(url, by: -1)
                    } label: {
                        Image(systemName: "arrow.left")
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .disabled(index == 0 || job.isRunning)
                    .help("Move earlier")
                    Button {
                        job.move(url, by: 1)
                    } label: {
                        Image(systemName: "arrow.right")
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .disabled(index == job.inputs.count - 1 || job.isRunning)
                    .help("Move later")
                }
            }
        }
        .padding(UIScale.pt(8))
        .background(
            DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                DashSkin.line(scheme == .dark)))
    }
}

struct StudioOptionsPanel: View {
    let model: StudioModel
    let job: StudioJob
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    if job.tool.options.isEmpty {
                        Text("No settings needed.")
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(.secondary)
                    } else {
                        StudioOptionsForm(job: job)
                    }
                }
                .padding(UIScale.pt(18))
            }
            Divider()
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                if case let .failed(message) = job.phase {
                    Label(message, systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let validation = job.validationMessage,
                    !job.inputs.isEmpty || !job.tool.needsFiles
                {
                    Text(validation)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: UIScale.pt(6)) {
                    Text("Save to")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.secondary)
                    StudioDestinationPicker()
                        .labelsHidden()
                        .controlSize(.small)
                }
                Button {
                    model.run(job)
                } label: {
                    Text(job.tool.actionTitle)
                        .font(.system(size: UIScale.pt(13.5), weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, UIScale.pt(3))
                }
                .buttonStyle(.edith(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canRun)
                .help("\(job.tool.actionTitle) (⌘↩)")
            }
            .padding(UIScale.pt(16))
        }
        .background(DashSkin.paper2(scheme == .dark).opacity(0.55))
    }

    private var canRun: Bool {
        !job.isRunning && job.validationMessage == nil
            && model.environment.missing(for: job.tool).isEmpty
    }
}

struct StudioProgressCard: View {
    let job: StudioJob
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
            VStack(spacing: UIScale.pt(12)) {
                StudioToolIcon(tool: job.tool, size: 44)
                Text(job.status ?? "\(job.tool.actionTitle)…")
                    .font(.system(size: UIScale.pt(13.5), weight: .semibold))
                    .lineLimit(1)
                ProgressView(value: job.progress)
                    .frame(width: UIScale.pt(260))
                Text("\(Int((job.progress * 100).rounded()))%")
                    .font(DashSkin.mono(11))
                    .foregroundStyle(.secondary)
                Button("Cancel") { job.cancel() }
                    .buttonStyle(.edith(.secondary))
                    .keyboardShortcut(".", modifiers: .command)
            }
            .padding(UIScale.pt(26))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: UIScale.pt(16)))
            .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
        }
    }
}

struct StudioResultView: View {
    let model: StudioModel
    let job: StudioJob
    let result: StudioRunResult
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let outputs = StudioLibraryQuery.outputURLs(result)
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                HStack(alignment: .center, spacing: UIScale.pt(12)) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: UIScale.pt(30)))
                        .foregroundStyle(DashSkin.ok)
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(StudioResultText.headline(job.tool, result))
                            .font(.system(size: UIScale.pt(17), weight: .semibold))
                        Text(StudioResultText.detail(result))
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        StudioFileActions.reveal(outputs)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.edith(.primary))
                }
                ForEach(result.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(.secondary)
                }
                ForEach(result.failures, id: \.self) { failure in
                    Label(
                        "\(failure.file): \(failure.message)",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.warn)
                }
                VStack(spacing: 0) {
                    ForEach(Array(result.outputs.prefix(200).enumerated()), id: \.element.id) {
                        index, output in
                        if index > 0 { Divider().opacity(0.5) }
                        StudioOutputRow(model: model, output: output)
                    }
                }
                .background(
                    DashSkin.paper2(scheme == .dark),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                        DashSkin.line(scheme == .dark)))
                if result.outputs.count > 200 {
                    Text("And \(result.outputs.count - 200) more in the folder.")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: UIScale.pt(8)) {
                    Button("Add results to Files") { model.add(outputs) }
                        .buttonStyle(.edith(.secondary))
                    Button("Back to Studio") { model.goHome() }
                        .buttonStyle(.edith(.secondary))
                }
                let next = StudioResultText.continuations(for: outputs, after: job.tool)
                if !next.isEmpty {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        Text("CONTINUE WITH")
                            .font(DashSkin.mono(10, weight: .semibold))
                            .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: UIScale.pt(190)), spacing: UIScale.pt(8))
                            ],
                            alignment: .leading, spacing: UIScale.pt(8)
                        ) {
                            ForEach(next) { tool in
                                StudioToolRow(tool: tool, environment: model.environment) {
                                    model.continueWith(tool, outputs: outputs)
                                }
                            }
                        }
                    }
                }
            }
            .padding(UIScale.pt(22))
        }
    }
}

struct StudioOutputRow: View {
    let model: StudioModel
    let output: StudioOutputFile

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            StudioThumbnail(url: output.url, side: 64, corner: 6)
                .frame(width: UIScale.pt(44), height: UIScale.pt(44))
            VStack(alignment: .leading, spacing: 1) {
                Text(output.url.lastPathComponent)
                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    StudioInspector.size(output.bytes) + " · "
                        + output.url.deletingLastPathComponent().path
                )
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            }
            Spacer(minLength: UIScale.pt(8))
            if let edit = StudioCatalog.quickTool(.edit, for: output.kind) {
                Button("Edit") { model.continueWith(edit, outputs: [output.url]) }
                    .buttonStyle(.edith(.toolbar))
            }
            Button("Open") { StudioFileActions.open(output.url) }
                .buttonStyle(.edith(.toolbar))
            Button {
                StudioFileActions.reveal([output.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.edith(.iconOnly))
            .help("Show in Finder")
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(8))
    }
}

enum StudioResultText {
    static func headline(_ tool: StudioTool, _ result: StudioRunResult) -> String {
        let count = result.outputs.count
        if let savings = result.savings, savings > 0.005, tool.group == .optimize {
            return "Saved \(Int((savings * 100).rounded()))%"
        }
        return count == 1 ? "Your file is ready" : "\(count) files are ready"
    }

    static func detail(_ result: StudioRunResult) -> String {
        let before = StudioInspector.size(result.inputBytes)
        let after = StudioInspector.size(result.outputBytes)
        if result.inputBytes > 0 { return "\(before) → \(after)" }
        return after
    }

    static func continuations(for outputs: [URL], after tool: StudioTool) -> [StudioTool] {
        guard !outputs.isEmpty else { return [] }
        let candidates = StudioCatalog.tools(accepting: outputs).filter { $0.id != tool.id }
        return Array(StudioCatalog.ranked(candidates).prefix(8))
    }
}
