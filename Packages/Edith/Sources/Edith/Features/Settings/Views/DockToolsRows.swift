import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct DockToolsRows: View {
    @AppStorage(AppStorageKeys.DockTools.enabled, store: SharedDefaults.store) private var enabled =
        false
    @AppStorage(AppStorageKeys.DockTools.previewMode, store: SharedDefaults.store) private
        var previewMode = DockPreviewMode.hover.rawValue
    @AppStorage(AppStorageKeys.DockTools.hoverDelay, store: SharedDefaults.store) private
        var hoverDelay = DockToolsPreferences.defaultHoverDelay
    @AppStorage(AppStorageKeys.DockTools.clickAction, store: SharedDefaults.store) private
        var clickAction = DockClickAction.standard.rawValue
    @AppStorage(AppStorageKeys.DockTools.greenButtonMaximizes, store: SharedDefaults.store) private
        var greenButtonMaximizes = false
    @AppStorage(AppStorageKeys.DockTools.quitOnLastWindow, store: SharedDefaults.store) private
        var quitOnLastWindow = false
    @AppStorage(AppStorageKeys.DockTools.excludedApps, store: SharedDefaults.store) private
        var excludedApps = ""
    @State private var pickerError: String?

    var body: some View {
        Section("Preview") {
            Picker(
                "Open previews",
                selection: $previewMode.configured(AppStorageKeys.DockTools.previewMode)
            ) {
                ForEach(DockPreviewMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text(
                previewMode == DockPreviewMode.hover.rawValue
                    ? "Rest the pointer on a running app to see its windows."
                    : "Hold Option while clicking a running app to open its window preview."
            )
            .settingsCaption()
            if previewMode == DockPreviewMode.hover.rawValue {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    LabeledContent("Hover delay") {
                        Text(String(format: "%.2fs", hoverDelay))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $hoverDelay.configured(AppStorageKeys.DockTools.hoverDelay),
                        in: DockToolsPreferences.hoverDelayRange)
                }
            }
            Text(
                "Screen Recording adds live thumbnails. Window titles remain available without it."
            )
            .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section("Dock behavior") {
            Picker(
                "Active app click",
                selection: $clickAction.configured(AppStorageKeys.DockTools.clickAction)
            ) {
                ForEach(DockClickAction.allCases, id: \.self) { action in
                    Text(action.title).tag(action.rawValue)
                }
            }
            Text("Only overrides a click when that app is already frontmost.")
                .settingsCaption()
            Toggle(
                "Green button maximizes without full screen",
                isOn: $greenButtonMaximizes.configured(
                    AppStorageKeys.DockTools.greenButtonMaximizes))
            Toggle(
                "Quit when the last window closes",
                isOn: $quitOnLastWindow.configured(AppStorageKeys.DockTools.quitOnLastWindow))
            Text("Minimized windows and windows on another Space keep the app running.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section("Excluded apps") {
            if identifiers.isEmpty {
                Text("No excluded apps")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(identifiers, id: \.self) { identifier in
                    HStack(spacing: UIScale.pt(10)) {
                        appIcon(identifier)
                            .frame(width: UIScale.pt(24), height: UIScale.pt(24))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(appName(identifier))
                            Text(identifier)
                                .settingsCaption()
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            remove(identifier)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(appName(identifier)) from exclusions")
                    }
                }
            }
            Button("Add app...") { chooseApplication() }
            if let pickerError {
                Text(pickerError)
                    .foregroundStyle(.red)
                    .settingsCaption()
            }
            Text("Excluded apps keep standard Dock, green button, and close behavior.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var identifiers: [String] {
        DockToolsPreferences.identifiers(excludedApps).sorted()
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Exclude an app"
        panel.prompt = "Exclude"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            let additions = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            guard additions.count == panel.urls.count else {
                pickerError = "One selected app has no bundle identifier."
                return
            }
            pickerError = nil
            let updated = DockToolsPreferences.identifiers(excludedApps).union(additions)
            excludedApps = DockToolsPreferences.encodedIdentifiers(updated)
            IPC.post(IPC.Name.settingsChanged)
        }
    }

    private func remove(_ identifier: String) {
        let updated = DockToolsPreferences.identifiers(excludedApps).subtracting([identifier])
        excludedApps = DockToolsPreferences.encodedIdentifiers(updated)
        IPC.post(IPC.Name.settingsChanged)
    }

    private func appName(_ identifier: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
            .flatMap {
                Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?
            .deletingPathExtension().lastPathComponent
            ?? identifier
    }

    private func appIcon(_ identifier: String) -> some View {
        let image =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        return Image(nsImage: image).resizable()
    }
}
