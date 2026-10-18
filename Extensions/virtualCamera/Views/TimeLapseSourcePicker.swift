import AppKit
import EdithExtensionUI
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

    mutating func toggle(_ id: UInt32, maximumCount: Int = 16) {
        if selected.contains(id) {
            selected.remove(id)
        } else if maximumCount == 1 {
            selected = [id]
            if mode == "windows" { systemAudio = true }
        } else if selected.count < maximumCount {
            selected.insert(id)
            if mode == "windows" { systemAudio = true }
        }
    }

    mutating func reconcile(displays: Set<UInt32>, windows: Set<UInt32>) {
        self.displays.formIntersection(displays)
        self.windows.formIntersection(windows)
    }

}

struct ScreenCaptureSourcePicker: View {
    let sources: any ScreenCaptureSourceProviding
    let compact: Bool
    let maximumCount: Int
    let maximumHeight: Double?
    let title: String
    let detail: String
    private let thumbnail: @MainActor (String, UInt32) async -> CGImage?
    private let loadsSources: Bool
    private let onSelection: (TimeLapseSourceSelection) -> Void
    @State private var selection: TimeLapseSourceSelection
    @State private var search = ""
    @State private var refresh = 0
    @Environment(\.dismiss) private var dismiss

    init(
        sources: any ScreenCaptureSourceProviding, compact: Bool = false,
        selection: TimeLapseSourceSelection, maximumCount: Int = 16,
        title: String = "Choose what to record",
        detail: String = "Select up to 16 sources. Each window is captured independently.",
        thumbnail: (@MainActor (String, UInt32) async -> CGImage?)? = nil,
        maximumHeight: Double? = nil,
        onSelection: @escaping (TimeLapseSourceSelection) -> Void
    ) {
        self.sources = sources
        self.compact = compact
        self.maximumCount = maximumCount
        self.maximumHeight = maximumHeight
        self.title = title
        self.detail = detail
        self.onSelection = onSelection
        loadsSources = thumbnail == nil
        self.thumbnail =
            thumbnail ?? { mode, id in
                await sources.sourceThumbnail(mode: mode, id: id)
            }
        _selection = State(initialValue: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(title).font(.edithText(.title3)).fontWeight(.semibold)
                    Text(detail)
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    refresh += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.edith(.borderless)).disabled(sources.sourceLoad.isRunning)
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
                    state: loadsSources && sources.sourceLoad.errorMessage == nil
                        ? sources.sourceLoad.state : .content,
                    message: sources.sourceLoad.errorMessage ?? "Choose displays or windows.",
                    layout: .cards, refreshing: sources.sourceLoad.isRefreshing,
                    retry: { refresh += 1 }
                ) {
                    if choices.isEmpty && sources.sourceLoad.errorMessage == nil {
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
                                        && maximumCount > 1
                                        && selection.selected.count >= maximumCount,
                                    revision: sources.sourceRevision,
                                    thumbnail: { await thumbnail(selection.mode, choice.id) },
                                    action: {
                                        selection.toggle(choice.id, maximumCount: maximumCount)
                                    })
                            }
                        }.padding(UIScale.pt(2))
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).id(selection.mode)
            if let error = sources.sourceLoad.errorMessage {
                PageNotice(
                    error, tone: .error,
                    actions: {
                        Button("Retry") { refresh += 1 }
                    })
            }
            if sources.sourceLoad.errorMessage == nil || sources.sourceLoad.hasContent {
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
                }.font(.edithText(.callout))
                if selection.mode == "windows" {
                    Text("Audio follows the selected apps, including their other windows.")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
            PageSectionHeader(selectionSummary) {
                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(.edith(.secondary))
                        .keyboardShortcut(.cancelAction)
                    Button("Use selection") {
                        onSelection(selection)
                        dismiss()
                    }.buttonStyle(.edith(.primary)).keyboardShortcut(.defaultAction)
                        .disabled(
                            sources.sourceLoad.isRunning || sources.captureSelectionBlocked
                                || selection.selected.isEmpty
                                || selection.selected.count > maximumCount
                        )
                }
            }
        }
        .padding(UIScale.pt(24))
        .frame(
            width: PresentationMetrics.width(compact ? 500 : 700),
            height: min(PresentationMetrics.height(600), maximumHeight ?? .infinity)
        )
        .pageSurface()
        .pageTask(id: refresh, active: loadsSources) { await sources.refreshCaptureSources() }
        .onChange(of: sources.sourceRevision) { _, _ in
            selection.reconcile(
                displays: Set(sources.displays.map(\.id)),
                windows: Set(sources.windows.map(\.id)))
        }
        .tracksWindowVisibility()
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
            return sources.displays.enumerated().map { index, display in
                .init(
                    id: display.id, title: "Display \(index + 1)",
                    subtitle: "\(display.width) × \(display.height)", symbol: "display")
            }
        }
        return sources.windows.filter {
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
