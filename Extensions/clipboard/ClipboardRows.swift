import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct ClipboardRows: View {
    @AppStorage(AppStorageKeys.Clipboard.enabled, store: SharedDefaults.store) private var enabled =
        false
    @AppStorage(AppStorageKeys.Clipboard.maxItems, store: SharedDefaults.store) private
        var maxItems = ClipboardIndex.defaultMaxItems
    @AppStorage(AppStorageKeys.Clipboard.maxItemBytes, store: SharedDefaults.store) private
        var maxItemBytes =
        ClipboardIndex.defaultMaxItemBytes
    @AppStorage(AppStorageKeys.Clipboard.maxAgeDays, store: SharedDefaults.store) private
        var maxAgeDays = 0
    @AppStorage(AppStorageKeys.Clipboard.ignoredApps, store: SharedDefaults.store) private
        var ignoredApps = ""
    @AppStorage(AppStorageKeys.Clipboard.autoPaste, store: SharedDefaults.store) private
        var autoPaste = true
    @AppStorage(AppStorageKeys.Clipboard.capturePaused, store: SharedDefaults.store) private
        var capturePaused = false
    @AppStorage(AppStorageKeys.Clipboard.pastePlainText, store: SharedDefaults.store) private
        var pastePlainText =
        false
    @AppStorage(AppStorageKeys.Clipboard.checkInterval, store: SharedDefaults.store) private
        var checkInterval =
        ClipboardIndex.defaultCheckInterval
    @AppStorage(AppStorageKeys.Permissions.accessibilityGranted, store: SharedDefaults.store)
    private var accessibilityGranted = false
    @AppStorage(AppStorageKeys.Clipboard.popupAt, store: SharedDefaults.store) private var popupAt =
        "cursor"
    @AppStorage(AppStorageKeys.Clipboard.pinTo, store: SharedDefaults.store) private var pinTo =
        "top"
    @AppStorage(AppStorageKeys.Clipboard.showFooter, store: SharedDefaults.store) private
        var showFooter = true
    @AppStorage(AppStorageKeys.Clipboard.saveFiles, store: SharedDefaults.store) private
        var saveFiles = true
    @AppStorage(AppStorageKeys.Clipboard.saveImages, store: SharedDefaults.store) private
        var saveImages = true
    @AppStorage(AppStorageKeys.Clipboard.saveText, store: SharedDefaults.store) private
        var saveText = true

    @State private var tab = "general"
    @State private var recent: ClipboardRecentModel
    let history: ClipboardHistoryModel
    @State private var showHistory = false
    @State private var refreshObserver: NSObjectProtocol?
    @State private var refreshTask: Task<Void, Never>?

    init(client: ClipboardClient, history: ClipboardHistoryModel) {
        self.history = history
        _recent = State(
            initialValue: ClipboardRecentModel(load: {
                try await client.snapshot(.init(limit: 5, recentlyCreated: true)).entries
            }))
    }

    private var maxItemMB: Binding<Int> {
        Binding(
            get: {
                min(ClipboardArchive.maximumBlobBytes / 1_000_000, max(1, maxItemBytes / 1_000_000))
            },
            set: {
                $maxItemBytes.notifyingSettingsChange().wrappedValue =
                    $0 * 1_000_000
            })
    }

    private var boundedMaxItems: Binding<Int> {
        Binding(
            get: { maxItems },
            set: {
                maxItems = min(999, max(1, $0))
                IPC.post(IPC.Name.settingsChanged)
            })
    }

    var body: some View {
        Group {
            Section {
                EdithSegmentedPicker(
                    "", selection: $tab, options: ["general", "storage", "appearance", "ignore"],
                    label: { $0.capitalized }
                )
                .labelsHidden()
            }

            Group {
                switch tab {
                case "storage": storageSections
                case "appearance": appearanceSections
                case "ignore": ignoreSections
                default: generalSections
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section {
                if let error = recent.error {
                    Text(error).settingsCaption().foregroundStyle(.orange)
                    Button("Retry") { reload() }
                } else if recent.loading, recent.entries.isEmpty {
                    HStack {
                        SkeletonGroup {
                            SkeletonBlock(width: 168, height: 9, corner: 4)
                            Spacer()
                            SkeletonBlock(width: 72, height: 9, corner: 4)
                        }
                    }
                    .settingsCaption()
                    .accessibilityLabel("Loading clipboard history")
                } else if recent.entries.isEmpty {
                    Label(
                        "No clipboard history yet. Copy something to get started.",
                        systemImage: "doc.on.clipboard"
                    )
                    .settingsCaption()
                }
                ForEach(recent.entries) { entry in
                    recentRow(entry)
                }
                Button("Open history ▸") { showHistory = true }
            } header: {
                Text("Recent")
            }
        }
        .pageTask(cancel: {
            refreshTask?.cancel(); refreshTask = nil
            recent.contentLoad.cancel()
            if let refreshObserver { IPC.stopObserving(refreshObserver) }
            refreshObserver = nil
        }) {
            if refreshObserver == nil {
                refreshObserver = IPC.observe(IPC.Name.clipboardChanged) { reload() }
            }
            await recent.refresh()
        }
        .edithSheet(isPresented: $showHistory) {
            ClipboardHistoryView(model: history)
        }
    }

    @ViewBuilder private var generalSections: some View {
        Section {
            LabeledContent {
                HotKeyRecorderControl(keyPrefix: "clipboardHotKey", defaultLabel: "⌃⇧C")
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Open")
                    InfoDot(
                        "Global shortcut to open and close the history popup. Default: ⌃⇧C.")
                }
            }
        }
        Section {
            Toggle(
                isOn: $capturePaused.notifyingSettingsChange()
            ) {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Pause capture")
                    InfoDot(
                        "New copies are ignored until you resume. Your history stays available in the popup."
                    )
                }
            }
        } header: {
            Text("Capture")
        }
        Section {
            Toggle(
                isOn: Binding(
                    get: { autoPaste },
                    set: { newValue in
                        $autoPaste.notifyingSettingsChange().wrappedValue =
                            newValue
                        if newValue, !accessibilityGranted {
                            ClipboardPermission.request()
                        }
                    })
            ) {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Paste automatically")
                    InfoDot(
                        "Picking a clip pastes it straight into the app you were using instead of just copying it. Needs Accessibility."
                    )
                }
            }
            if autoPaste, !accessibilityGranted {
                Text(
                    "Accessibility isn't granted yet - selecting an item only copies until you grant it."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.orange)
            }
            Toggle(
                "Paste without formatting",
                isOn: $pastePlainText.notifyingSettingsChange()
            )
            Text("Strips fonts, colors and links so pasted text matches the destination.")
                .settingsCaption()
        } header: {
            Text("Behavior")
        }
    }

    @ViewBuilder private var storageSections: some View {
        Section {
            Toggle(
                "Files", isOn: $saveFiles.notifyingSettingsChange()
            )
            Toggle(
                "Images", isOn: $saveImages.notifyingSettingsChange()
            )
            Toggle(
                "Text", isOn: $saveText.notifyingSettingsChange()
            )
            Text("Change what types of copied content should be stored.")
                .settingsCaption()
        } header: {
            Text("Save")
        }
        Section {
            LabeledContent {
                HStack(spacing: UIScale.pt(4)) {
                    EdithNumberField(
                        value: boundedMaxItems,
                        width: UIScale.pt(64))
                    Stepper(
                        "", value: boundedMaxItems,
                        in: 1...999
                    )
                    .labelsHidden()
                }
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Size")
                    InfoDot("Number of history items to keep. Default: 200.")
                }
            }
            Stepper(
                value: maxItemMB,
                in: 1...(ClipboardArchive.maximumBlobBytes / 1_000_000)
            ) {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Maximum item size: \(maxItemMB.wrappedValue) MB")
                    InfoDot(
                        "Copies larger than this aren't saved - a small indicator shows when one was skipped."
                    )
                }
            }
            Picker(
                selection: $maxAgeDays.notifyingSettingsChange()
            ) {
                Text("Never").tag(0)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Auto-delete after")
                    InfoDot("Removes entries older than N days, pinned items excepted.")
                }
            }
            Stepper(
                value: $checkInterval.notifyingSettingsChange(),
                in: 0.2...5, step: 0.1
            ) {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Check interval: \(String(format: "%.1f", checkInterval))s")
                    InfoDot(
                        "How often Edith peeks at the clipboard. Larger saves battery; smaller catches rapid copies."
                    )
                }
            }
        }
    }

    @ViewBuilder private var appearanceSections: some View {
        Section {
            Picker(selection: $popupAt.notifyingSettingsChange()) {
                ForEach(PopupPosition.allCases) { position in
                    Text(position.title).tag(position.rawValue)
                }
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Popup at")
                    InfoDot(
                        "Where the popup appears: at the mouse cursor, under the menu icon, centered on the front window or screen, or wherever you last dragged it."
                    )
                }
            }
            Picker(selection: $pinTo.notifyingSettingsChange()) {
                Text("Top").tag("top")
                Text("Bottom").tag("bottom")
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Pin to")
                    InfoDot("Whether pinned items stick to the top or the bottom of the list.")
                }
            }
            Toggle(isOn: $showFooter.notifyingSettingsChange()) {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Show keyboard hints")
                    InfoDot("Shows the keyboard hints at the bottom of the popup.")
                }
            }
        }
    }

    @ViewBuilder private var ignoreSections: some View {
        Section {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                LabeledContent("Ignored apps") {
                    EdithTextField(
                        placeholder: "com.app.bundleid, com.other.app",
                        text: $ignoredApps.notifyingSettingsChange())
                }
                Text(
                    "Copies made in these apps are never recorded (password managers are pre-listed)."
                )
                .settingsCaption()
            }
        }
    }

    private func reload() {
        refreshTask?.cancel()
        refreshTask = Task { await recent.refresh() }
    }

    private func recentRow(_ entry: ClipboardEntry) -> some View {
        HStack {
            Text(entry.displayPreview).lineLimit(1)
            Spacer()
            Text(entry.sourceApp ?? "Unknown")
            Text("·")
            Text(entry.createdAt.formatted(.relative(presentation: .named)))
        }
        .settingsCaption()
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
