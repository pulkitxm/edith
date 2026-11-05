import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct ClipboardRows: View {
    @State private var preferences = ClipboardPreferences()
    let presentation: ClipboardPresentation?
    let openPalette: () -> Void

    @State private var recent: ClipboardRecentModel
    let history: ClipboardHistoryModel
    @State private var showHistory = false
    @State private var refreshObserver: NSObjectProtocol?
    @State private var refreshTask: Task<Void, Never>?

    init(
        client: ClipboardClient, history: ClipboardHistoryModel,
        presentation: ClipboardPresentation? = nil, openPalette: @escaping () -> Void = {}
    ) {
        self.presentation = presentation
        self.openPalette = openPalette
        _preferences = State(
            initialValue: presentation?.preferences
                ?? ClipboardPreferences.read(SharedDefaults.store))
        self.history = history
        _recent = State(
            initialValue: ClipboardRecentModel(load: {
                try await client.snapshot(.init(limit: 5, recentlyCreated: true)).entries
            }))
    }

    private var available: Bool { presentation?.available ?? true }

    private var maxItemMB: Binding<Int> {
        Binding(
            get: {
                min(
                    ClipboardArchive.maximumBlobBytes / 1_000_000,
                    max(1, preferences.maxItemBytes / 1_000_000))
            },
            set: {
                binding(\.maxItemBytes).wrappedValue =
                    $0 * 1_000_000
            })
    }

    private var boundedMaxItems: Binding<Int> {
        Binding(
            get: { preferences.maxItems },
            set: {
                preferences.maxItems = min(999, max(1, $0))
                savePreferences()
            })
    }

    var body: some View {
        Group {
            if !available {
                Section {
                    DeskSettingsNotice(
                        title: "Clipboard is off",
                        message: "Nothing you copy is being recorded. Turn it on to keep a history and change these settings."
                    )
                }
            } else if let error = presentation?.error {
                Section {
                    DeskSettingsError(
                        title: "A change was not saved", message: error,
                        retry: { Task { await presentation?.refresh() } })
                }
            }
            Group {
                Section {
                    LabeledContent {
                        Button("Open History", action: openPalette)
                            .buttonStyle(.edith(.primary))
                    } label: {
                        Text("Paste something again")
                        Text("Search everything you copied recently and pick an item to paste it.")
                    }
                    DeskShortcutRow(
                        keyPrefix: "clipboardHotKey", defaultLabel: "\u{2303}\u{21E7}C",
                        purpose: "Opens your clipboard history from any app.")
                }
                recentSection
                captureSection
                pastingSection
                historySection
                popupSection
            }
            .disabled(!available)
            .opacity(available ? 1 : 0.5)
        }
        .pageRefresh(
            interval: { .seconds(2) },
            cancel: {
                refreshTask?.cancel(); refreshTask = nil
                recent.contentLoad.cancel()
                if let refreshObserver { IPC.stopObserving(refreshObserver) }
                refreshObserver = nil
            }
        ) {
            if presentation == nil, refreshObserver == nil {
                refreshObserver = IPC.observe(IPC.Name.clipboardChanged) { reload() }
            }
            if let presentation {
                await presentation.refresh()
                preferences = presentation.preferences
                if showHistory { history.reload() }
            }
            await recent.refresh()
        }
        .onChange(of: presentation?.preferences) { _, next in
            if let next { preferences = next }
        }
        .edithSheet(isPresented: $showHistory) {
            ClipboardHistoryView(model: history)
        }
    }

    @ViewBuilder private var recentSection: some View {
        Section("Recently copied") {
            if let error = recent.error, recent.entries.isEmpty {
                DeskSettingsError(
                    title: "Recent items did not load", message: error, retry: reload)
            } else if recent.loading, recent.entries.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonGroup {
                        HStack(spacing: UIScale.pt(12)) {
                            SkeletonBlock(width: 20, height: 20, corner: 5)
                            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                                SkeletonBlock(width: 220, height: 10, corner: 4)
                                SkeletonBlock(width: 120, height: 8, corner: 4)
                            }
                        }
                    }
                }
                .accessibilityLabel("Loading clipboard history")
            } else if recent.entries.isEmpty {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Nothing copied yet")
                    Text("Copy some text, a link or an image in any app and it shows up here.")
                }
            } else {
                ForEach(recent.entries) { entry in
                    ClipboardRecentRow(entry: entry)
                }
                LabeledContent {
                    Button("Browse All") { showHistory = true }
                        .buttonStyle(.edith(.secondary))
                } label: {
                    Text("Full history")
                    Text("Search, pin and delete everything Edith has kept.")
                }
            }
        }
    }

    @ViewBuilder private var captureSection: some View {
        Section {
            Toggle(isOn: binding(\.capturePaused)) {
                Text("Pause recording")
                Text("New copies are ignored until you turn this off. Your history stays available.")
            }
            Toggle(isOn: binding(\.saveText)) {
                Text("Keep text and links")
            }
            Toggle(isOn: binding(\.saveImages)) {
                Text("Keep images")
            }
            Toggle(isOn: binding(\.saveFiles)) {
                Text("Keep files")
            }
            LabeledContent {
                TextField(
                    "Ignored apps", text: binding(\.ignoredApps),
                    prompt: Text("com.example.app, com.other.app")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .frame(width: UIScale.pt(220))
            } label: {
                Text("Ignored apps")
                Text("Copies made in these apps are never recorded. Password managers are listed already.")
            }
        } header: {
            Text("Recording")
        }
    }

    @ViewBuilder private var pastingSection: some View {
        Section("Pasting") {
            Toggle(
                isOn: Binding(
                    get: { preferences.autoPaste },
                    set: { newValue in
                        binding(\.autoPaste).wrappedValue = newValue
                        if newValue, !preferences.accessibilityGranted {
                            requestPermission()
                        }
                    })
            ) {
                Text("Paste for me")
                Text("Picking an item pastes it into the app you were using, instead of only copying it.")
            }
            if preferences.autoPaste, !preferences.accessibilityGranted {
                LabeledContent {
                    Button("Allow Access", action: requestPermission)
                        .buttonStyle(.edith(.secondary))
                } label: {
                    Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundColor(.orange)
                        + Text(" Accessibility is needed")
                    Text("Until you allow it, picking an item only copies it.")
                }
            }
            Toggle(isOn: binding(\.pastePlainText)) {
                Text("Paste as plain text")
                Text("Removes fonts, colors and links so text matches where you paste it.")
            }
        }
    }

    @ViewBuilder private var historySection: some View {
        Section("History") {
            LabeledContent {
                HStack(spacing: UIScale.pt(8)) {
                    EdithNumberField(value: boundedMaxItems, width: UIScale.pt(64))
                    Stepper("Items to keep", value: boundedMaxItems, in: 1...999)
                        .labelsHidden()
                }
            } label: {
                Text("Items to keep")
                Text("The oldest unpinned item is removed when the list is full.")
            }
            LabeledContent {
                HStack(spacing: UIScale.pt(8)) {
                    Text("\(maxItemMB.wrappedValue) MB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper(
                        "Largest item", value: maxItemMB,
                        in: 1...(ClipboardArchive.maximumBlobBytes / 1_000_000)
                    )
                    .labelsHidden()
                }
            } label: {
                Text("Largest item")
                Text("Bigger copies are skipped and not saved.")
            }
            Picker(selection: binding(\.maxAgeDays)) {
                Text("Never").tag(0)
                Text("After 7 days").tag(7)
                Text("After 30 days").tag(30)
                Text("After 90 days").tag(90)
            } label: {
                Text("Delete old items")
                Text("Pinned items are always kept.")
            }
            LabeledContent {
                HStack(spacing: UIScale.pt(8)) {
                    Text(String(format: "%.1f s", preferences.checkInterval))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper(
                        "Check for copies every", value: binding(\.checkInterval), in: 0.2...5,
                        step: 0.1
                    )
                    .labelsHidden()
                }
            } label: {
                Text("Check for copies every")
                Text("Longer saves battery. Shorter catches quick copies in a row.")
            }
        }
    }

    @ViewBuilder private var popupSection: some View {
        Section("History popup") {
            Picker(selection: binding(\.popupAt)) {
                ForEach(PopupPosition.allCases) { position in
                    Text(position.title).tag(position.rawValue)
                }
            } label: {
                Text("Opens at")
                Text("Where the popup appears when you press the shortcut.")
            }
            Picker(selection: binding(\.pinTo)) {
                Text("Top").tag("top")
                Text("Bottom").tag("bottom")
            } label: {
                Text("Pinned items")
                Text("Where pinned items sit in the list.")
            }
            Toggle(isOn: binding(\.showFooter)) {
                Text("Show keyboard hints")
                Text("A line of shortcuts along the bottom of the popup.")
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<ClipboardPreferences, Value>) -> Binding<
        Value
    > {
        Binding(
            get: { preferences[keyPath: key] },
            set: {
                preferences[keyPath: key] = $0; savePreferences()
            })
    }

    private func savePreferences() {
        if let presentation {
            presentation.preferences = preferences; presentation.save()
        } else {
            try? preferences.save(SharedDefaults.store)
        }
    }

    private func requestPermission() {
        if let presentation {
            presentation.action("clipboard.ui.permission")
        } else {
            ClipboardPermission.request()
        }
    }

    private func reload() {
        refreshTask?.cancel()
        refreshTask = Task { await recent.refresh() }
    }
}

private struct ClipboardRecentRow: View {
    let entry: ClipboardEntry

    var body: some View {
        LabeledContent {
            Text(entry.createdAt.formatted(.relative(presentation: .named)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } label: {
            Label {
                Text(entry.displayPreview).lineLimit(1).truncationMode(.tail)
                Text(entry.sourceApp ?? "Unknown app")
            } icon: {
                Image(systemName: ClipboardCategory(entry).symbol)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
@Observable
final class ClipboardRecentModel {
    private(set) var entries: [ClipboardEntry] = []
    let contentLoad = ContentLoad()
    var error: String? { contentLoad.errorMessage }
    var loading: Bool { contentLoad.isRunning }
    private let load: @Sendable () async throws -> [ClipboardEntry]

    init(load: @escaping @Sendable () async throws -> [ClipboardEntry]) { self.load = load }

    func refresh() async {
        await contentLoad.perform(operation: load) { entries = $0 }
    }
}
