import AppKit
import EdithKit
import SwiftUI

struct TimeLapseSourceSelection {
    var mode: String {
        didSet {
            if mode == "windows", !windows.isEmpty { systemAudio = true }
        }
    }
    var displays: Set<UInt32>
    var windows: Set<UInt32>
    var systemAudio: Bool

    var selected: Set<UInt32> {
        get { mode == "displays" ? displays : windows }
        set {
            if mode == "displays" { displays = newValue } else { windows = newValue }
        }
    }

    mutating func toggle(_ id: UInt32) {
        if selected.contains(id) {
            selected.remove(id)
        } else if selected.count < 16 {
            selected.insert(id)
            if mode == "windows" { systemAudio = true }
        }
    }

    mutating func reconcile(displays: Set<UInt32>, windows: Set<UInt32>) {
        self.displays.formIntersection(displays)
        self.windows.formIntersection(windows)
    }

    @available(macOS 15.0, *)
    @MainActor func apply(to recorder: TimeLapseRecorder) {
        recorder.sourceMode = mode
        recorder.selectedDisplays = displays
        recorder.selectedWindows = windows
        recorder.settings.systemAudio = systemAudio
    }
}

@available(macOS 15.0, *)
struct TimeLapseSourcePicker: View {
    let recorder: TimeLapseRecorder
    let compact: Bool
    private let thumbnail: @MainActor (String, UInt32) async -> CGImage?
    @State private var selection: TimeLapseSourceSelection
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    init(
        recorder: TimeLapseRecorder, compact: Bool = false,
        thumbnail: (@MainActor (String, UInt32) async -> CGImage?)? = nil
    ) {
        self.recorder = recorder
        self.compact = compact
        self.thumbnail =
            thumbnail ?? { [weak recorder] mode, id in
                await recorder?.sourceThumbnail(mode: mode, id: id)
            }
        _selection = State(
            initialValue: TimeLapseSourceSelection(
                mode: recorder.sourceMode, displays: recorder.selectedDisplays,
                windows: recorder.selectedWindows,
                systemAudio: recorder.sourceMode == "windows" || recorder.settings.systemAudio))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text("Choose what to record").font(.title3.weight(.semibold))
                    Text("Select up to 16 sources. Each window is captured independently.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await recorder.loadSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless).disabled(recorder.busy)
                    .help("Refresh sources").accessibilityLabel("Refresh sources")
            }
            HStack(spacing: 0) {
                sourceTab("Windows", mode: "windows", symbol: "macwindow")
                sourceTab("Displays", mode: "displays", symbol: "display")
            }
            if selection.mode == "windows" {
                TextField("Search apps or windows", text: $search).textFieldStyle(.roundedBorder)
            }
            ScrollView {
                if recorder.busy {
                    ProgressView("Loading sources…").frame(maxWidth: .infinity)
                        .padding(UIScale.pt(40))
                } else if choices.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "No sources available" : "No matching windows",
                        systemImage: selection.mode == "displays" ? "display" : "macwindow",
                        description: Text(
                            search.isEmpty
                                ? "Open a window or connect a display, then refresh."
                                : "Try another app or window name."))
                } else {
                    LazyVGrid(columns: columns, spacing: UIScale.pt(16)) {
                        ForEach(choices) { choice in
                            TimeLapseSourceCard(
                                choice: choice, selected: selection.selected.contains(choice.id),
                                disabled: !selection.selected.contains(choice.id)
                                    && selection.selected.count >= 16,
                                revision: recorder.sourceRevision,
                                thumbnail: { await thumbnail(selection.mode, choice.id) },
                                action: { selection.toggle(choice.id) })
                        }
                    }.padding(UIScale.pt(2))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).id(selection.mode)
            if let error = recorder.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Divider()
            HStack {
                Label(
                    selection.mode == "windows" ? "Selected app audio" : "System audio",
                    systemImage: "speaker.wave.2")
                Spacer()
                Toggle(
                    selection.mode == "windows" ? "Selected app audio" : "System audio",
                    isOn: $selection.systemAudio
                ).labelsHidden()
                    .toggleStyle(.switch)
            }.font(.callout)
            if selection.mode == "windows" {
                Text("Audio follows the selected apps, including their other windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(selectionSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use selection") {
                    selection.apply(to: recorder)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(
                        recorder.busy || selection.selected.isEmpty || selection.selected.count > 16
                    )
            }
        }
        .padding(UIScale.pt(24))
        .frame(width: UIScale.pt(compact ? 500 : 700), height: UIScale.pt(600))
        .background(.background)
        .onChange(of: recorder.sourceRevision) { _, _ in
            selection.reconcile(
                displays: Set(recorder.displays.map(\.id)),
                windows: Set(recorder.windows.map(\.id)))
        }
    }

    private var columns: [GridItem] {
        let spacing = UIScale.pt(16)
        return selection.mode == "displays"
            ? Array(repeating: GridItem(.flexible(), spacing: spacing), count: 2)
            : [GridItem(.adaptive(minimum: UIScale.pt(180)), spacing: spacing)]
    }

    private func sourceTab(_ title: String, mode: String, symbol: String) -> some View {
        Button {
            selection.mode = mode
        } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selection.mode == mode ? .semibold : .regular))
                .foregroundStyle(selection.mode == mode ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity).padding(.vertical, UIScale.pt(10))
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selection.mode == mode ? Color.accentColor : .clear)
                        .frame(height: UIScale.pt(2))
                }
        }.buttonStyle(.plain)
            .accessibilityValue(selection.mode == mode ? "Selected" : "Not selected")
    }

    private var selectionSummary: String {
        let count = selection.selected.count
        let noun = selection.mode == "displays" ? "display" : "window"
        return count == 0
            ? "Choose a source to continue"
            : "\(count) \(noun)\(count == 1 ? "" : "s") selected"
    }

    private var choices: [TimeLapseSourceCard.Choice] {
        if selection.mode == "displays" {
            return recorder.displays.enumerated().map { index, display in
                .init(
                    id: display.id, title: "Display \(index + 1)",
                    subtitle: "\(display.width) × \(display.height)", symbol: "display")
            }
        }
        return recorder.windows.filter {
            search.isEmpty
                || "\($0.application) \($0.title)".localizedCaseInsensitiveContains(search)
        }.map {
            .init(id: $0.id, title: $0.title, subtitle: $0.application, symbol: "macwindow")
        }
    }
}

private struct TimeLapseSourceCard: View {
    struct Choice: Identifiable {
        let id: UInt32
        let title: String
        let subtitle: String
        let symbol: String
    }

    let choice: Choice
    let selected: Bool
    let disabled: Bool
    let revision: Int
    let thumbnail: @MainActor () async -> CGImage?
    let action: () -> Void
    @State private var image: CGImage?
    @State private var loading = true

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .fill(.quaternary.opacity(0.5)).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(image, scale: 1, label: Text(choice.title))
                                .resizable().scaledToFit().padding(UIScale.pt(5))
                        } else if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            VStack(spacing: UIScale.pt(6)) {
                                Image(systemName: choice.symbol).font(.title2)
                                Text("Preview unavailable").font(.caption2)
                            }.foregroundStyle(.secondary)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(
                                selected ? Color.accentColor : .secondary
                            )
                            .background(.regularMaterial, in: Circle()).padding(UIScale.pt(8))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(10))
                            .strokeBorder(
                                selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                lineWidth: UIScale.pt(selected ? 2 : 1))
                    }
                Text(choice.title).font(.callout.weight(.medium)).lineLimit(1)
                Label(choice.subtitle, systemImage: choice.symbol)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .help("\(choice.title)\n\(choice.subtitle)")
        .accessibilityLabel("\(choice.title), \(choice.subtitle)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .task(id: revision) {
            loading = true
            image = await thumbnail()
            guard !Task.isCancelled else { return }
            loading = false
        }
    }
}
