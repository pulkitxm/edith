import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct ClipboardRows: View {
    @AppStorage("clipboardEnabled", store: SharedDefaults.store) private var enabled = false
    @AppStorage("clipboardMaxItems", store: SharedDefaults.store) private var maxItems = 200
    @AppStorage("clipboardMaxItemBytes", store: SharedDefaults.store) private var maxItemBytes =
        10_000_000
    @AppStorage("clipboardMaxAgeDays", store: SharedDefaults.store) private var maxAgeDays = 0
    @AppStorage("clipboardIgnoredApps", store: SharedDefaults.store) private var ignoredApps = ""
    @AppStorage("clipboardAutoPaste", store: SharedDefaults.store) private var autoPaste = false
    @AppStorage("clipboardPastePlainText", store: SharedDefaults.store) private var pastePlainText =
        false
    @AppStorage("clipboardCheckInterval", store: SharedDefaults.store) private var checkInterval =
        1.0
    @AppStorage("permAccessibilityGranted", store: SharedDefaults.store)
    private var accessibilityGranted = false
    @AppStorage("clipboardPopupAt", store: SharedDefaults.store) private var popupAt = "cursor"
    @AppStorage("clipboardPinTo", store: SharedDefaults.store) private var pinTo = "top"
    @AppStorage("clipboardShowFooter", store: SharedDefaults.store) private var showFooter = true
    @AppStorage("clipboardSaveFiles", store: SharedDefaults.store) private var saveFiles = true
    @AppStorage("clipboardSaveImages", store: SharedDefaults.store) private var saveImages = true
    @AppStorage("clipboardSaveText", store: SharedDefaults.store) private var saveText = true

    @State private var tab = "general"
    @State private var recentEntries: [ClipboardEntry] = []
    @State private var showHistory = false
    @State private var refreshObserver: NSObjectProtocol?

    private var maxItemMB: Binding<Int> {
        Binding(
            get: { max(1, maxItemBytes / 1_000_000) },
            set: { maxItemBytes = $0 * 1_000_000 })
    }

    var body: some View {
        Group {
            Section {
                Picker("", selection: $tab) {
                    Text("General").tag("general")
                    Text("Storage").tag("storage")
                    Text("Appearance").tag("appearance")
                    Text("Ignore").tag("ignore")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .pointerCursor()
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
                if recentEntries.isEmpty {
                    Text("No clipboard history yet.")
                        .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                } else {
                    ForEach(recentEntries) { entry in
                        recentRow(entry)
                    }
                }
                Button("Open history ▸") { showHistory = true }
                    .pointerCursor()
            } header: {
                Text("Recent")
            }
        }
        .onAppear {
            reload()
            refreshObserver = IPC.observe(IPC.Name.clipboardChanged) { reload() }
        }
        .onDisappear {
            if let refreshObserver { IPC.stopObserving(refreshObserver) }
            refreshObserver = nil
        }
        .sheet(isPresented: $showHistory) {
            ClipboardHistoryView()
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
                isOn: Binding(
                    get: { autoPaste },
                    set: { newValue in
                        autoPaste = newValue
                        if newValue, !accessibilityGranted {
                            IPC.post(IPC.Name.grantAccessibility)
                        }
                    })
            ) {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Paste automatically")
                    InfoDot(
                        "Selecting an item pastes it into the front app instead of just copying. Needs Accessibility."
                    )
                }
            }
            .pointerCursor()
            if autoPaste, !accessibilityGranted {
                Text(
                    "Accessibility isn't granted yet - selecting an item only copies until you grant it."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.orange)
            }
            Toggle("Paste without formatting", isOn: $pastePlainText)
                .pointerCursor()
            Text("Strips fonts, colors and links so pasted text matches the destination.")
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
        } header: {
            Text("Behavior")
        }
    }

    @ViewBuilder private var storageSections: some View {
        Section {
            Toggle("Files", isOn: $saveFiles).pointerCursor()
            Toggle("Images", isOn: $saveImages).pointerCursor()
            Toggle("Text", isOn: $saveText).pointerCursor()
            Text("Change what types of copied content should be stored.")
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
        } header: {
            Text("Save")
        }
        Section {
            LabeledContent {
                HStack(spacing: UIScale.pt(4)) {
                    EdithNumberField(value: $maxItems, width: UIScale.pt(64))
                    Stepper("", value: $maxItems, in: 1...999)
                        .labelsHidden()
                        .pointerCursor()
                }
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Size")
                    InfoDot("Number of history items to keep. Default: 200.")
                }
            }
            Stepper(
                value: maxItemMB,
                in: 1...200
            ) {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Maximum item size: \(maxItemMB.wrappedValue) MB")
                    InfoDot(
                        "Copies larger than this aren't saved - a small indicator shows when one was skipped."
                    )
                }
            }
            .pointerCursor()
            Picker(selection: $maxAgeDays) {
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
            .pointerCursor()
            Stepper(value: $checkInterval, in: 0.2...5, step: 0.1) {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Check interval: \(String(format: "%.1f", checkInterval))s")
                    InfoDot(
                        "How often Edith peeks at the clipboard. Larger saves battery; smaller catches rapid copies."
                    )
                }
            }
            .pointerCursor()
        }
    }

    @ViewBuilder private var appearanceSections: some View {
        Section {
            Picker(selection: $popupAt) {
                ForEach(ClipboardPopupPosition.allCases) { position in
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
            .pointerCursor()
            Picker(selection: $pinTo) {
                Text("Top").tag("top")
                Text("Bottom").tag("bottom")
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Pin to")
                    InfoDot("Whether pinned items stick to the top or the bottom of the list.")
                }
            }
            .pointerCursor()
            Toggle(isOn: $showFooter) {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Show footer")
                    InfoDot("Shows the Clear and Preferences rows at the bottom of the popup.")
                }
            }
            .pointerCursor()
        }
    }

    @ViewBuilder private var ignoreSections: some View {
        Section {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                LabeledContent("Ignored apps") {
                    EdithTextField(
                        placeholder: "com.app.bundleid, com.other.app", text: $ignoredApps)
                }
                Text(
                    "Copies made in these apps are never recorded (password managers are pre-listed)."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
            }
        }
    }

    private func reload() {
        recentEntries = Array(
            ClipboardRepository.loadEntries().sorted { $0.createdAt > $1.createdAt }.prefix(5))
    }

    private func recentRow(_ entry: ClipboardEntry) -> some View {
        HStack {
            Text(entry.displayPreview).lineLimit(1)
            Spacer()
            Text(entry.sourceApp ?? "Unknown")
            Text("·")
            Text(entry.createdAt.formatted(.relative(presentation: .named)))
        }
        .font(.system(size: UIScale.pt(10)))
        .foregroundStyle(.secondary)
    }
}
