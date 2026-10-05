import AppKit
import EdithKit
import SwiftUI

struct TimeLapseSourceSelection {
    var mode: String
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
    private let loadsSources: Bool
    @State private var selection: TimeLapseSourceSelection
    @State private var search = ""
    @State private var refresh = 0
    @Environment(\.dismiss) private var dismiss

    init(
        recorder: TimeLapseRecorder, compact: Bool = false,
        thumbnail: (@MainActor (String, UInt32) async -> CGImage?)? = nil
    ) {
        self.recorder = recorder
        self.compact = compact
        loadsSources = thumbnail == nil
        self.thumbnail =
            thumbnail ?? { [weak recorder] mode, id in
                await recorder?.sourceThumbnail(mode: mode, id: id)
            }
        _selection = State(
            initialValue: TimeLapseSourceSelection(
                mode: recorder.sourceMode, displays: recorder.selectedDisplays,
                windows: recorder.selectedWindows, systemAudio: recorder.settings.systemAudio))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text("Choose what to record").font(.edithText(.title3)).fontWeight(.semibold)
                    Text("Select up to 16 sources. Each window is captured independently.")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    refresh += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.edith(.borderless)).disabled(recorder.sourceLoad.isRunning)
                    .help("Refresh sources").accessibilityLabel("Refresh sources")
            }
            EdithSegmentedPicker(
                "Source type", selection: $selection.mode,
                options: ["windows", "displays"],
                label: { $0 == "windows" ? "Windows" : "Displays" })
            if selection.mode == "windows" {
                TextField("Search apps or windows", text: $search).textFieldStyle(.roundedBorder)
            }
            ScrollView {
                PageLoading(
                    state: loadsSources ? recorder.sourceLoad.state : .content,
                    message: recorder.sourceLoad.errorMessage ?? "Choose displays or windows.",
                    layout: .cards, refreshing: recorder.sourceLoad.isRefreshing,
                    retry: { refresh += 1 }
                ) {
                    if choices.isEmpty {
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
                                    choice: choice,
                                    selected: selection.selected.contains(choice.id),
                                    disabled: !selection.selected.contains(choice.id)
                                        && selection.selected.count >= 16,
                                    revision: recorder.sourceRevision,
                                    thumbnail: { await thumbnail(selection.mode, choice.id) },
                                    action: { selection.toggle(choice.id) })
                            }
                        }.padding(UIScale.pt(2))
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).id(selection.mode)
            if recorder.sourceLoad.hasContent, let error = recorder.sourceLoad.errorMessage {
                PageNotice(
                    error, tone: .error,
                    actions: {
                        Button("Retry") { refresh += 1 }
                    })
            }
            Divider()
            HStack {
                Label("System audio", systemImage: "speaker.wave.2")
                Spacer()
                Toggle("System audio", isOn: $selection.systemAudio).labelsHidden()
                    .toggleStyle(.switch)
            }.font(.edithText(.callout))
            PageSectionHeader(selectionSummary) {
                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(.edith(.secondary))
                        .keyboardShortcut(.cancelAction)
                    Button("Use selection") {
                        selection.apply(to: recorder)
                        dismiss()
                    }.buttonStyle(.edith(.primary)).keyboardShortcut(.defaultAction)
                        .disabled(
                            recorder.sourceLoad.isRunning || recorder.busy || recorder.recording
                                || selection.selected.isEmpty
                                || selection.selected.count > 16
                        )
                }
            }
        }
        .padding(UIScale.pt(24))
        .frame(
            width: PresentationMetrics.width(compact ? 500 : 700),
            height: PresentationMetrics.height(600)
        )
        .pageSurface()
        .pageTask(id: refresh, active: loadsSources) { await recorder.loadSources() }
        .onChange(of: recorder.sourceRevision) { _, _ in
            selection.reconcile(
                displays: Set(recorder.displays.map(\.id)),
                windows: Set(recorder.windows.map(\.id)))
        }
    }

    private var columns: [GridItem] {
        PageMetrics.cardColumns(false, minimum: 180, maximum: 320, spacing: 16)
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
    @State private var loading = ContentLoad()

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .fill(.quaternary.opacity(0.5)).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(image, scale: 1, label: Text(choice.title))
                                .resizable().scaledToFit().padding(UIScale.pt(5))
                        } else if loading.state == .loading {
                            SkeletonBlock(height: 100, corner: 10)
                        } else {
                            VStack(spacing: UIScale.pt(6)) {
                                Image(systemName: choice.symbol).font(.edithText(.title2))
                                Text("Preview unavailable").font(.edithText(.caption2))
                            }.foregroundStyle(.secondary)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.edithText(.title3)).foregroundStyle(
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
                Text(choice.title).font(.edithText(.callout)).fontWeight(.medium).lineLimit(1)
                Label(choice.subtitle, systemImage: choice.symbol)
                    .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless)).disabled(disabled)
        .help("\(choice.title)\n\(choice.subtitle)")
        .accessibilityLabel("\(choice.title), \(choice.subtitle)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .pageTask(id: revision, cancel: { loading.cancel() }) {
            let request = loading.begin()
            let result = await thumbnail()
            guard loading.isCurrent(request) else { return }
            image = result
            loading.complete(request)
        }
    }
}
