import AppKit
import EdithKit
import EdithStudio
import Observation
import SwiftUI

enum StudioWorkflowStore {
    static var url: URL { DataRoot.studio.appendingPathComponent("workflows.json") }

    static func load() -> [StudioWorkflow] {
        guard let data = try? Data(contentsOf: url) else { return StudioWorkflow.presets }
        return (try? JSONDecoder().decode([StudioWorkflow].self, from: data))
            ?? StudioWorkflow.presets
    }

    static func save(_ workflows: [StudioWorkflow]) {
        try? FileManager.default.createDirectory(
            at: DataRoot.studio, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(workflows) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

@MainActor
@Observable
final class StudioWorkflowDraft: Identifiable {
    let id: UUID
    var name: String
    var steps: [StudioJob]
    var failure: String?

    init(workflow: StudioWorkflow) {
        id = workflow.id
        name = workflow.name
        steps = StudioWorkflowDraft.jobs(for: workflow)
    }

    static func jobs(for workflow: StudioWorkflow) -> [StudioJob] {
        var jobs: [StudioJob] = []
        for step in workflow.steps {
            guard let tool = step.tool else { continue }
            jobs.append(
                StudioJob(
                    tool: tool, inputs: [],
                    settings: step.settings.merged(over: tool.defaultSettings)))
        }
        return jobs
    }

    var workflow: StudioWorkflow {
        var steps: [StudioWorkflow.Step] = []
        for job in self.steps {
            steps.append(StudioWorkflow.Step(toolID: job.tool.id, settings: job.settings))
        }
        return StudioWorkflow(id: id, name: name, steps: steps)
    }

    var candidates: [StudioTool] {
        StudioCatalog.ranked(workflow.candidates(after: steps.count - 1))
    }

    func append(_ tool: StudioTool) {
        steps.append(StudioJob(tool: tool, inputs: []))
    }

    func remove(at index: Int) {
        guard steps.indices.contains(index) else { return }
        steps.remove(at: index)
    }

    func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard steps.indices.contains(index), steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
    }
}

struct StudioWorkflowSection: View {
    let model: StudioModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Text("WORKFLOWS")
                .font(DashSkin.mono(10, weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: UIScale.pt(240)), spacing: UIScale.pt(12))],
                alignment: .leading, spacing: UIScale.pt(12)
            ) {
                ForEach(model.workflows) { workflow in
                    StudioWorkflowCard(model: model, workflow: workflow)
                }
                Button {
                    model.editWorkflow(nil)
                } label: {
                    VStack(spacing: UIScale.pt(8)) {
                        Image(systemName: "plus")
                            .font(.system(size: UIScale.pt(20), weight: .light))
                        Text("New workflow")
                            .font(.system(size: UIScale.pt(13), weight: .semibold))
                        Text("Chain tools and reuse them on any files.")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: UIScale.pt(120))
                    .overlay(
                        RoundedRectangle(cornerRadius: UIScale.pt(12))
                            .strokeBorder(
                                DashSkin.lineStrong(scheme == .dark),
                                style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                    )
                    .edithButtonTarget(.borderless)
                }
                .buttonStyle(.edith(.borderless))
            }
        }
    }
}

struct StudioWorkflowCard: View {
    let model: StudioModel
    let workflow: StudioWorkflow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(4)) {
                ForEach(Array(workflow.tools.enumerated()), id: \.offset) { index, tool in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: UIScale.pt(9), weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    StudioToolIcon(tool: tool, size: 26)
                }
            }
            Text(workflow.name)
                .font(.system(size: UIScale.pt(13.5), weight: .semibold))
            Text(workflow.summary)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Button("Run") { model.runWorkflow(workflow, with: model.selectedURLs) }
                    .buttonStyle(.edith(.primary))
                Button("Edit") { model.editWorkflow(workflow) }
                    .buttonStyle(.edith(.secondary))
                Spacer()
                Button {
                    model.deleteWorkflow(workflow)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.edith(.iconOnly))
                .help("Delete workflow")
            }
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                DashSkin.line(scheme == .dark)))
    }
}

struct StudioWorkflowEditor: View {
    let model: StudioModel
    let draft: StudioWorkflowDraft
    @State private var expanded: Int?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            Text("Workflow").font(.system(size: UIScale.pt(17), weight: .semibold))
            TextField("Name", text: Binding(get: { draft.name }, set: { draft.name = $0 }))
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                            HStack(spacing: UIScale.pt(8)) {
                                Text("\(index + 1)")
                                    .font(DashSkin.mono(11, weight: .bold))
                                    .frame(width: UIScale.pt(20))
                                StudioToolIcon(tool: step.tool, size: 26)
                                Text(step.tool.title).font(
                                    .system(size: UIScale.pt(12.5), weight: .medium))
                                Spacer()
                                if !step.tool.options.isEmpty {
                                    Button(expanded == index ? "Done" : "Settings") {
                                        expanded = expanded == index ? nil : index
                                    }
                                    .buttonStyle(.edith(.toolbar))
                                }
                                Button {
                                    draft.move(index, by: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.edith(.iconOnly))
                                .disabled(index == 0)
                                Button {
                                    draft.remove(at: index)
                                    expanded = nil
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.edith(.iconOnly))
                            }
                            if expanded == index {
                                StudioOptionsForm(job: step)
                                    .padding(.leading, UIScale.pt(28))
                            }
                        }
                        .padding(UIScale.pt(10))
                        .background(
                            DashSkin.paper2(scheme == .dark),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
                    }
                    Menu {
                        ForEach(StudioToolGrouping.byGroup(draft.candidates), id: \.group) {
                            entry in
                            Section(entry.group.title) {
                                ForEach(entry.tools) { tool in
                                    Button(tool.title) {
                                        draft.append(tool)
                                        expanded =
                                            tool.options.contains(where: \.isRequired)
                                            ? draft.steps.count - 1 : nil
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(
                            draft.steps.isEmpty ? "Choose the first tool" : "Add a step",
                            systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.top, UIScale.pt(4))
                }
            }
            .frame(minHeight: UIScale.pt(220), maxHeight: UIScale.pt(420))
            if let failure = draft.failure {
                Text(failure).font(.system(size: UIScale.pt(11.5))).foregroundStyle(DashSkin.danger)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.editingWorkflow = nil }
                    .buttonStyle(.edith(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Save workflow") { model.saveWorkflow(draft) }
                    .buttonStyle(.edith(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(UIScale.pt(22))
        .frame(width: UIScale.pt(560))
    }
}
