import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct ClipboardPane: View {
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
        0.5
    @AppStorage("clipboardBackup", store: SharedDefaults.store) private var icloudBackup = false
    @AppStorage("lastClipboardBackupAt", store: SharedDefaults.store) private var lastBackupAt =
        0.0
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
        Form {
            Section {
                Toggle("Enable clipboard history", isOn: $enabled)
                    .pointerCursor()
                InfoDot(
                    "Turns the feature and its background monitoring on. Off means zero cost - nothing watches your clipboard."
                )
            }

            Section {
                Picker("", selection: $tab) {
                    Text("General").tag("general")
                    Text("Storage").tag("storage")
                    Text("Appearance").tag("appearance")
                    Text("Ignore").tag("ignore")
                }
                .pickerStyle(.segmented)
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
                if recentEntries.isEmpty {
                    Text("No clipboard history yet.")
                        .font(.caption).foregroundStyle(.secondary)
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
        .formStyle(.grouped)
        .navigationTitle("Clipboard")
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
            HStack {
                LabeledContent("Open") { ClipboardShortcutRecorder() }
                InfoDot(
                    "Global shortcut to open and close the history popup. Default: ⌃⇧C.")
            }
        }
        Section {
            HStack {
                Toggle(
                    "Paste automatically",
                    isOn: Binding(
                        get: { autoPaste },
                        set: { newValue in
                            autoPaste = newValue
                            if newValue, !accessibilityGranted {
                                IPC.post(IPC.Name.grantAccessibility)
                            }
                        })
                )
                .pointerCursor()
                InfoDot(
                    "Selecting an item pastes it into the front app instead of just copying. Needs Accessibility."
                )
            }
            if autoPaste, !accessibilityGranted {
                Text(
                    "Accessibility isn't granted yet - selecting an item only copies until you grant it."
                )
                .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Paste without formatting", isOn: $pastePlainText)
                .pointerCursor()
            Text("Strips fonts, colors and links so pasted text matches the destination.")
                .font(.caption).foregroundStyle(.secondary)
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
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Save")
        }
        Section {
            HStack {
                LabeledContent("Size") {
                    HStack(spacing: 4) {
                        TextField("", value: $maxItems, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                        Stepper("", value: $maxItems, in: 1...999)
                            .labelsHidden()
                            .pointerCursor()
                    }
                }
                InfoDot("Number of history items to keep. Default: 200.")
            }
            HStack {
                Stepper(
                    "Maximum item size: \(maxItemMB.wrappedValue) MB", value: maxItemMB,
                    in: 1...200
                )
                .pointerCursor()
                InfoDot(
                    "Copies larger than this aren't saved - a small indicator shows when one was skipped."
                )
            }
            HStack {
                Picker("Auto-delete after", selection: $maxAgeDays) {
                    Text("Never").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pointerCursor()
                InfoDot("Removes entries older than N days, pinned items excepted.")
            }
            HStack {
                Stepper(
                    "Check interval: \(String(format: "%.1f", checkInterval))s",
                    value: $checkInterval, in: 0.2...5, step: 0.1
                )
                .pointerCursor()
                InfoDot(
                    "How often Edith peeks at the clipboard. Larger saves battery; smaller catches rapid copies."
                )
            }
        }
        Section {
            HStack {
                Toggle("Back up to iCloud", isOn: $icloudBackup)
                    .pointerCursor()
                    .disabled(!AppData.cloudAvailable)
                InfoDot(
                    "Keeps text history in iCloud Drive so reinstalls and other Macs can restore it. Backup, not live sync."
                )
            }
            Text(backupSubtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var appearanceSections: some View {
        Section {
            HStack {
                Picker("Popup at", selection: $popupAt) {
                    ForEach(ClipboardPopupPosition.allCases) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                }
                .pointerCursor()
                InfoDot(
                    "Where the popup appears: at the mouse cursor, under the menu icon, centered on the front window or screen, or wherever you last dragged it."
                )
            }
            HStack {
                Picker("Pin to", selection: $pinTo) {
                    Text("Top").tag("top")
                    Text("Bottom").tag("bottom")
                }
                .pointerCursor()
                InfoDot("Whether pinned items stick to the top or the bottom of the list.")
            }
            HStack {
                Toggle("Show footer", isOn: $showFooter)
                    .pointerCursor()
                InfoDot("Shows the Clear and Preferences rows at the bottom of the popup.")
            }
        }
    }

    @ViewBuilder private var ignoreSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Ignored apps") {
                    TextField("com.app.bundleid, com.other.app", text: $ignoredApps)
                        .textFieldStyle(.roundedBorder)
                }
                Text(
                    "Copies made in these apps are never recorded (password managers are pre-listed)."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var backupSubtitle: String {
        if !AppData.cloudAvailable { return "iCloud Drive is not available on this Mac" }
        if !icloudBackup { return "Items up to 1 MB each - larger copies stay on this Mac only" }
        if lastBackupAt > 0 {
            let at = Date(timeIntervalSince1970: lastBackupAt)
            return "Backed up \(at.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Waiting for first backup…"
    }

    private func reload() {
        recentEntries = Array(
            ClipboardRepository.loadEntries().sorted { $0.createdAt > $1.createdAt }.prefix(5))
    }

    private func recentRow(_ entry: ClipboardEntry) -> some View {
        HStack {
            Text(entry.preview ?? "").lineLimit(1)
            Spacer()
            Text(entry.sourceApp ?? "Unknown")
            Text("·")
            Text(entry.createdAt.formatted(.relative(presentation: .named)))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ClipboardShortcutRecorder: View {
    @State private var recording = false
    @State private var monitor: Any?
    @State private var label = SharedDefaults.store.string(forKey: "clipboardHotKeyLabel") ?? "⌃⇧C"

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press shortcut…" : label)
                .font(.system(size: 12, weight: .medium))
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
        }
        .pointerCursor()
        .onDisappear { if recording { stop() } }
        .help("Click, then press the new shortcut (Esc cancels)")
    }

    private func start() {
        recording = true
        NSApp.activate(ignoringOtherApps: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        label = SharedDefaults.store.string(forKey: "clipboardHotKeyLabel") ?? "⌃⇧C"
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {
            stop()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        else { return }
        var mods = 0
        var symbols = ""
        if flags.contains(.control) { mods |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { mods |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { mods |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { mods |= cmdKey; symbols += "⌘" }
        let key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        SharedDefaults.store.set(Int(event.keyCode), forKey: "clipboardHotKeyCode")
        SharedDefaults.store.set(mods, forKey: "clipboardHotKeyMods")
        SharedDefaults.store.set(symbols + key, forKey: "clipboardHotKeyLabel")
        stop()
    }
}
