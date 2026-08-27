import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct RadialLauncherRows: View {
    @AppStorage(RadialLauncherPreferenceKeys.enabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(RadialLauncherPreferenceKeys.atPointer, store: SharedDefaults.store) private
        var atPointer = true
    @State private var profile = RadialLauncherProfile.starter
    @State private var loaded = false

    var body: some View {
        Section("Profile") {
            TextField("Profile name", text: $profile.name)
            Toggle("Center on pointer", isOn: $atPointer)
            HStack {
                HotKeyRecorderControl(
                    keyPrefix: "radialLauncherHotKey", defaultLabel: "⌥⌘Space")
                Button("Try launcher") { IPC.post(IPC.Name.requestRadialLauncher) }
            }
            Text(
                "Press the shortcut, point at a slice, then release. A quick press leaves the wheel open for clicking or number keys."
            )
            .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section("Wheel actions") {
            ForEach($profile.items) { $item in
                RadialLauncherItemRow(item: $item) {
                    profile.items.removeAll { $0.id == item.id }
                }
            }
            Button {
                profile.items.append(
                    RadialLauncherItem(kind: .application, name: "New action"))
            } label: {
                Label("Add action", systemImage: "plus")
            }
            .disabled(profile.items.count >= 8 || !enabled)
            Text(
                "The wheel supports one to eight applications, files, links, key combinations, media controls, and Edith actions."
            )
            .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onAppear(perform: load)
        .onChange(of: profile) { save() }
        .onChange(of: atPointer) { IPC.post(IPC.Name.settingsChanged) }
    }

    private func load() {
        profile = RadialLauncherProfileStore.decode(
            SharedDefaults.store.string(forKey: RadialLauncherPreferenceKeys.profile))
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        SharedDefaults.store.set(
            RadialLauncherProfileStore.encode(profile),
            forKey: RadialLauncherPreferenceKeys.profile)
        IPC.post(IPC.Name.settingsChanged)
    }
}

private struct RadialLauncherItemRow: View {
    @Binding var item: RadialLauncherItem
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack {
                Image(systemName: item.effectiveSymbol)
                    .frame(width: UIScale.pt(20))
                TextField("Name", text: $item.name)
                Picker("Type", selection: $item.kind) {
                    ForEach(RadialLauncherItemKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: UIScale.pt(150))
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            targetEditor
        }
        .padding(.vertical, UIScale.pt(4))
        .onChange(of: item.kind) { resetTarget() }
    }

    @ViewBuilder
    private var targetEditor: some View {
        switch item.kind {
        case .application, .file:
            HStack {
                TextField("Path", text: $item.payload)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…", action: choosePath)
            }
        case .link:
            TextField("https://example.com", text: $item.payload)
                .textFieldStyle(.roundedBorder)
        case .keyCombination:
            RadialLauncherShortcutRecorder(item: $item)
        case .media:
            Picker("Control", selection: $item.payload) {
                ForEach(RadialLauncherMediaAction.allCases) { action in
                    Text(action.title).tag(action.rawValue)
                }
            }
        case .edith:
            Picker("Action", selection: $item.payload) {
                ForEach(RadialLauncherEdithAction.allCases) { action in
                    Text(action.title).tag(action.rawValue)
                }
            }
        }
    }

    private func resetTarget() {
        item.symbol = ""
        switch item.kind {
        case .application, .file, .link, .keyCombination:
            item.payload = ""
        case .media:
            item.payload = RadialLauncherMediaAction.playPause.rawValue
        case .edith:
            item.payload = RadialLauncherEdithAction.openPanel.rawValue
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = item.kind == .file
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if item.kind == .application {
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        item.payload = url.path
        if item.name == "New action" || item.name.isEmpty {
            item.name = url.deletingPathExtension().lastPathComponent
        }
    }
}

private struct RadialLauncherShortcutRecorder: View {
    @Binding var item: RadialLauncherItem
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press key combination…" : item.payload.ifEmpty("Record shortcut"))
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .kerning(recording ? 0 : 2)
        }
        .onDisappear { stop() }
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
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {
            stop()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else { return }
        var modifiers = 0
        var label = ""
        if flags.contains(.control) {
            modifiers |= controlKey
            label += "⌃"
        }
        if flags.contains(.option) {
            modifiers |= optionKey
            label += "⌥"
        }
        if flags.contains(.shift) {
            modifiers |= shiftKey
            label += "⇧"
        }
        if flags.contains(.command) {
            modifiers |= cmdKey
            label += "⌘"
        }
        item.keyCode = Int(event.keyCode)
        item.modifiers = modifiers
        item.payload = label + (event.charactersIgnoringModifiers?.uppercased() ?? "?")
        stop()
    }
}

private extension String {
    func ifEmpty(_ replacement: String) -> String {
        isEmpty ? replacement : self
    }
}
