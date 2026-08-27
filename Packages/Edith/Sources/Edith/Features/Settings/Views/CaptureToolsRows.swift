import AppKit
import EdithKit
import SwiftUI

struct CaptureToolsRows: View {
    @AppStorage(AppStorageKeys.Capture.enabled, store: SharedDefaults.store) private
        var captureToolsEnabled = false
    @AppStorage(AppStorageKeys.Capture.copyMode, store: SharedDefaults.store) private
        var copyMode: CaptureCopyMode = .smart
    @AppStorage(AppStorageKeys.Capture.detectCodes, store: SharedDefaults.store) private
        var detectCodes = true
    @AppStorage(AppStorageKeys.Capture.historySize, store: SharedDefaults.store) private
        var historySize = 10
    @AppStorage(AppStorageKeys.Capture.saveScreenshots, store: SharedDefaults.store) private
        var saveScreenshots = false
    @State private var history: [CaptureRecognition] = []

    var body: some View {
        Group {
            Section("Capture") {
                HStack {
                    Button("Read screen") {
                        _ = CaptureToolOperationExecution.request(.read)
                    }
                    .buttonStyle(.edith(.primary))
                    Button("Screenshot") {
                        _ = CaptureToolOperationExecution.request(.screenshot)
                    }
                    .buttonStyle(.edith(.secondary))
                }
                LabeledContent("Read shortcut") {
                    HotKeyRecorderControl(
                        keyPrefix: "captureReadHotKey", defaultLabel: "⌃⌥⌘R")
                }
                LabeledContent("Screenshot shortcut") {
                    HotKeyRecorderControl(
                        keyPrefix: "captureScreenshotHotKey", defaultLabel: "⌃⌥⌘S")
                }
            }

            Section("Recognition") {
                Picker(
                    "Copy after reading",
                    selection: $copyMode.configured(AppStorageKeys.Capture.copyMode)
                ) {
                    ForEach(CaptureCopyMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle(
                    "Read QR and matrix codes",
                    isOn: $detectCodes.configured(AppStorageKeys.Capture.detectCodes))
                Toggle(
                    "Keep read screenshots in Pictures",
                    isOn: $saveScreenshots.configured(AppStorageKeys.Capture.saveScreenshots))
                Stepper(
                    "Recent reads: \(historySize)",
                    value: $historySize.configured(AppStorageKeys.Capture.historySize), in: 1...25)
                Text(
                    "Recognition runs offline with macOS Vision. Screen images are temporary unless you save them or enable screenshot retention."
                )
                .settingsCaption()
            }

            Section("Related tools") {
                Text(
                    "Use Color Picker for exact pixel colors. The Notch Shelf owns the camera preview for mirror checks."
                )
                .settingsCaption()
            }

            if !history.isEmpty {
                Section {
                    ForEach(history.prefix(historySize)) { capture in
                        Button {
                            copy(capture.output(for: copyMode))
                        } label: {
                            HStack {
                                Image(
                                    systemName: capture.codes.isEmpty
                                        ? "text.alignleft" : "qrcode.viewfinder"
                                )
                                .foregroundStyle(.secondary)
                                Text(capture.output(for: .smart))
                                    .lineLimit(2)
                                Spacer()
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.edith(.row))
                    }
                } header: {
                    HStack {
                        Text("Recent reads")
                        Spacer()
                        Button("Clear") {
                            CaptureHistoryStore.clear()
                            history = []
                            IPC.post(IPC.Name.settingsChanged)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .disabled(!captureToolsEnabled)
        .opacity(captureToolsEnabled ? 1 : 0.5)
        .onAppear { history = CaptureHistoryStore.load() }
        .onReceive(
            DistributedNotificationCenter.default().publisher(for: IPC.Name.settingsChanged)
        ) { _ in history = CaptureHistoryStore.load() }
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        IPC.post(IPC.Name.clipboardChanged)
    }
}
