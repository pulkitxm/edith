import AppKit
import EdithKit
import SwiftUI

struct ExtensionsPane: View {
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var musicEnabled = true
    @AppStorage("tabCalendarEnabled", store: SharedDefaults.store) private var calendarEnabled =
        true
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = true
    @AppStorage("notchShelfEnabled", store: SharedDefaults.store) private var notchShelfEnabled =
        false
    @AppStorage("clipboardEnabled", store: SharedDefaults.store) private var clipboardEnabled =
        false
    @AppStorage("focusDimEnabled", store: SharedDefaults.store) private var focusDimEnabled = false
    @AppStorage("colorPickerEnabled", store: SharedDefaults.store) private var colorPickerEnabled =
        false
    @State private var expanded: Set<String> = []

    var body: some View {
        Form {
            header(
                "music", title: "Music", icon: "music.note",
                subtitle: "Plays your local music folder, with media keys.",
                enabled: $musicEnabled)
            if expanded.contains("music") { MusicRows() }

            header(
                "calendar", title: "Calendar", icon: "calendar",
                subtitle: "Shows your schedule in the panel and the app.",
                enabled: $calendarEnabled, expandable: false)

            header(
                "system", title: "System", icon: "switch.2",
                subtitle: "Prevent-sleep toggle and the keyboard-cleaning lock.",
                enabled: $systemEnabled)
            if expanded.contains("system") { SystemRows() }

            header(
                "notchShelf", title: "Notch Shelf", icon: "tray.and.arrow.down",
                subtitle: "Park files under the notch mid-drag.",
                enabled: $notchShelfEnabled)
            if expanded.contains("notchShelf") { NotchShelfRows() }

            header(
                "clipboard", title: "Clipboard", icon: "doc.on.clipboard",
                subtitle: "Clipboard history with instant paste.",
                enabled: $clipboardEnabled)
            if expanded.contains("clipboard") { ClipboardRows() }

            header(
                "focusDim", title: "Focus Dim", icon: "circle.lefthalf.filled",
                subtitle: "Dims everything behind your active app.",
                enabled: $focusDimEnabled)
            if expanded.contains("focusDim") { FocusDimRows() }

            header(
                "presenter", title: "Presenter", icon: "theatermasks.fill",
                subtitle: "Blurs sensitive numbers while sharing your screen.",
                enabled: nil)
            if expanded.contains("presenter") { PresenterRows() }

            header(
                "colorPicker", title: "Color Picker", icon: "eyedropper",
                subtitle: "System loupe on a hotkey, sampled color to your clipboard.",
                enabled: $colorPickerEnabled)
            if expanded.contains("colorPicker") { ColorPickerRows() }

            PanelTabsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Extensions")
        .animation(.easeOut(duration: 0.15), value: expanded)
        .onAppear {
            if let id = SharedDefaults.store.string(forKey: "extensionsExpand") {
                expanded.insert(id)
                SharedDefaults.store.removeObject(forKey: "extensionsExpand")
            }
        }
    }

    private func header(
        _ id: String, title: String, icon: String, subtitle: String,
        enabled: Binding<Bool>?, expandable: Bool = true
    ) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let enabled {
                    Toggle("", isOn: enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .pointerCursor()
                }
                if expandable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded.contains(id) ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard expandable else { return }
                if expanded.contains(id) {
                    expanded.remove(id)
                } else {
                    expanded.insert(id)
                }
            }
            .pointerCursor()
        }
    }
}

private struct MusicRows: View {
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var enabled = true

    var body: some View {
        Section {
            LabeledContent("Music folder") {
                Button("Open in Finder") {
                    try? FileManager.default.createDirectory(
                        at: Repo.musicDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Repo.musicDir)
                }
                .pointerCursor()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct SystemRows: View {
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var enabled = true
    @AppStorage("preventSleep", store: SharedDefaults.store) private var preventSleep = false

    var body: some View {
        Section {
            HStack {
                Toggle("Prevent sleep", isOn: $preventSleep)
                    .pointerCursor()
                InfoDot(
                    "Keeps your Mac awake until you turn this off again, even with the lid closed on power."
                )
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct PanelTabsSection: View {
    @AppStorage("tabOrder", store: SharedDefaults.store) private var tabOrderRaw =
        "usage,music,system"
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var usageEnabled = true
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var musicEnabled = true
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = true
    @AppStorage("tabCalendarEnabled", store: SharedDefaults.store) private var calendarEnabled =
        true
    @State private var draggingTab: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var rowPitch: CGFloat = 38

    private static let tabs: [(id: String, title: String)] = [
        ("usage", "Agent Usage"),
        ("music", "Music"),
        ("system", "System"),
        ("calendar", "Calendar"),
    ]

    private var orderedIDs: [String] {
        var ids = tabOrderRaw.split(separator: ",").map(String.init)
            .filter { id in Self.tabs.contains { $0.id == id } }
        for tab in Self.tabs where !ids.contains(tab.id) {
            ids.append(tab.id)
        }
        return ids
    }

    var body: some View {
        Section {
            let order = orderedIDs
            VStack(spacing: 12) {
                ForEach(Array(order.enumerated()), id: \.element) { index, id in
                    tabRow(id)
                        .offset(y: rowOffset(index: index, id: id, order: order))
                        .zIndex(draggingTab == id ? 1 : 0)
                        .animation(
                            draggingTab == id ? nil : .easeOut(duration: 0.15),
                            value: projectedDelta)
                }
            }
            Text("Drag to reorder the tabs in the menu bar panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Menu bar panel")
        }
    }

    private func tabRow(_ id: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(
                    draggingTab == id ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                )
                .frame(width: 18, height: 26)
                .contentShape(Rectangle())
                .onHover { over in
                    over ? NSCursor.openHand.set() : NSCursor.arrow.set()
                }
                .gesture(
                    DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            if draggingTab == nil {
                                draggingTab = id
                                NSCursor.closedHand.set()
                            }
                            dragTranslation = value.translation.height
                        }
                        .onEnded { _ in commitDrag() }
                )
            Text(Self.tabs.first { $0.id == id }?.title ?? id)
                .opacity(binding(for: id).wrappedValue ? 1 : 0.5)
            Spacer()
            Toggle("", isOn: binding(for: id))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointerCursor()
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(draggingTab == id ? Color.primary.opacity(0.08) : .clear)
                .padding(.horizontal, -8)
                .padding(.vertical, -5)
        )
        .scaleEffect(draggingTab == id ? 1.02 : 1)
        .shadow(color: .black.opacity(draggingTab == id ? 0.3 : 0), radius: 6, y: 2)
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { rowPitch = geo.size.height + 12 }
            })
    }

    private var projectedDelta: Int {
        guard rowPitch > 0 else { return 0 }
        return Int((dragTranslation / rowPitch).rounded())
    }

    private func rowOffset(index: Int, id: String, order: [String]) -> CGFloat {
        guard let dragging = draggingTab,
            let from = order.firstIndex(of: dragging)
        else { return 0 }
        if id == dragging { return dragTranslation }
        let to = max(0, min(order.count - 1, from + projectedDelta))
        if from < to, index > from, index <= to { return -rowPitch }
        if to < from, index >= to, index < from { return rowPitch }
        return 0
    }

    private func commitDrag() {
        defer {
            withAnimation(.easeOut(duration: 0.18)) {
                draggingTab = nil
                dragTranslation = 0
            }
            NSCursor.arrow.set()
        }
        guard let dragging = draggingTab else { return }
        var order = orderedIDs
        guard let from = order.firstIndex(of: dragging) else { return }
        let to = max(0, min(order.count - 1, from + projectedDelta))
        guard to != from else { return }
        let item = order.remove(at: from)
        order.insert(item, at: to)
        tabOrderRaw = order.joined(separator: ",")
    }

    private func binding(for id: String) -> Binding<Bool> {
        switch id {
        case "usage": return $usageEnabled
        case "music": return $musicEnabled
        case "system": return $systemEnabled
        default: return $calendarEnabled
        }
    }
}
