import AVFoundation
import AVKit
import AppKit
import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
private final class ScreenRecordingEditorModel {
    let take: ScreenRecordingTake
    let player: AVPlayer
    var document: ScreenRecordingEditDocument
    var presets: [ScreenRecordingExportPreset]
    var exportProgress = 0.0
    var exporting = false
    var errorMessage: String?
    var finishedURL: URL?
    var overlayText = ""
    private var exporter: ScreenRecordingExporter?

    init(take: ScreenRecordingTake) {
        self.take = take
        player = AVPlayer(url: ScreenRecordingLibrary.masterURL(for: take.id))
        let editURL = ScreenRecordingLibrary.editURL(for: take.id)
        if let data = try? Data(contentsOf: editURL),
            let saved = try? JSONDecoder().decode(ScreenRecordingEditDocument.self, from: data)
        {
            document = saved.normalized(duration: take.duration)
        } else {
            document = ScreenRecordingEditDocument(trimEnd: take.duration)
        }
        presets = ScreenRecordingPresetStore.load()
        if !presets.contains(document.preset) { presets.insert(document.preset, at: 0) }
        generateZoomsIfNeeded()
    }

    func persist() {
        document = document.normalized(duration: take.duration)
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: ScreenRecordingLibrary.editURL(for: take.id), options: .atomic)
    }

    func addCut() {
        let time = min(max(player.currentTime().seconds, document.trimStart), document.trimEnd)
        let start = max(document.trimStart, time - 0.5)
        let end = min(document.trimEnd, time + 0.5)
        guard end - start >= 0.05 else { return }
        document.cuts.append(ScreenRecordingRange(start: start, end: end))
        persist()
    }

    func addText() {
        let value = overlayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let time = min(max(player.currentTime().seconds, document.trimStart), document.trimEnd)
        document.texts.append(ScreenRecordingTextOverlay(
            text: value, start: time, end: min(document.trimEnd, time + 3)))
        overlayText = ""
        persist()
    }

    func applyCrop(_ crop: ScreenRecordingCrop) {
        document.crop = crop.rect
        persist()
    }

    func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save export preset"
        alert.informativeText = "Name this combination of format, size, frame rate, and quality."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var preset = document.preset
        preset.id = UUID()
        preset.name = name
        presets.append(preset)
        document.preset = preset
        ScreenRecordingPresetStore.save(presets)
        persist()
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Edith Recording.\(document.preset.format.rawValue)"
        panel.allowedContentTypes = document.preset.format == .gif ? [.gif] : [.mpeg4Movie]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true
        exportProgress = 0
        errorMessage = nil
        finishedURL = nil
        persist()
        let exporter = ScreenRecordingExporter()
        self.exporter = exporter
        let take = self.take
        let document = self.document
        exporter.onProgress = { [weak self] progress in
            Task { @MainActor in self?.exportProgress = progress }
        }
        Task { [weak self] in
            do {
                try await exporter.export(take: take, document: document, to: destination)
                guard let self else { return }
                exporting = false
                finishedURL = destination
                self.exporter = nil
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError {
                self?.exporting = false
                self?.exporter = nil
            } catch {
                self?.exporting = false
                self?.errorMessage = error.localizedDescription
                self?.exporter = nil
                NSSound.beep()
            }
        }
    }

    func cancelExport() {
        exporter?.cancel()
    }

    func copyFinished() {
        guard let finishedURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([finishedURL as NSURL])
        IPC.post(IPC.Name.clipboardChanged)
    }

    private func generateZoomsIfNeeded() {
        guard document.automaticZooms, document.zooms.isEmpty,
            let data = try? Data(contentsOf: ScreenRecordingLibrary.pointerURL(for: take.id)),
            let track = try? JSONDecoder().decode(ScreenRecordingPointerTrack.self, from: data)
        else { return }
        document.zooms = ScreenRecordingTimeline.automaticZooms(
            clicks: track.clicks, duration: take.duration)
    }
}

@MainActor
final class ScreenRecordingEditorController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model: ScreenRecordingEditorModel
    private let closed: () -> Void

    init(take: ScreenRecordingTake, closed: @escaping () -> Void) {
        model = ScreenRecordingEditorModel(take: take)
        self.closed = closed
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init()
        panel.title = "Recording Editor"
        panel.minSize = NSSize(width: 860, height: 620)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ScreenRecordingEditorView(model: model))
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        model.persist()
        model.player.pause()
        panel.close()
        panel.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        model.persist()
        model.player.pause()
        panel.contentView = nil
        closed()
    }
}

private enum ScreenRecordingCrop: String, CaseIterable {
    case original
    case widescreen
    case square
    case portrait

    var label: String {
        switch self {
        case .original: "Original"
        case .widescreen: "16:9"
        case .square: "1:1"
        case .portrait: "9:16"
        }
    }

    var rect: CGRect? {
        switch self {
        case .original: nil
        case .widescreen: CGRect(x: 0, y: 0.21875, width: 1, height: 0.5625)
        case .square: CGRect(x: 0.125, y: 0, width: 0.75, height: 1)
        case .portrait: CGRect(x: 0.3418, y: 0, width: 0.3164, height: 1)
        }
    }
}

private struct ScreenRecordingEditorView: View {
    @Bindable var model: ScreenRecordingEditorModel
    @State private var crop: ScreenRecordingCrop = .original
    @State private var background = Color(red: 0.067, green: 0.094, blue: 0.153)

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VideoPlayer(player: model.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                timeline
            }
            .frame(minWidth: 560)
            ScrollView { inspector.padding(16) }
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var timeline: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Trim")
                Slider(
                    value: $model.document.trimStart,
                    in: 0...max(0.1, model.document.trimEnd - 0.05),
                    onEditingChanged: { if !$0 { model.persist() } })
                Text(model.document.trimStart, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit().frame(width: 36)
                Slider(
                    value: $model.document.trimEnd,
                    in: min(model.take.duration, model.document.trimStart + 0.05)...max(
                        model.take.duration, model.document.trimStart + 0.05),
                    onEditingChanged: { if !$0 { model.persist() } })
                Text(model.document.trimEnd, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit().frame(width: 36)
                Button("Cut at playhead", action: model.addCut)
            }
            if !model.document.cuts.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(model.document.cuts.enumerated()), id: \.offset) { index, cut in
                            Button {
                                model.document.cuts.remove(at: index)
                                model.persist()
                            } label: {
                                Label(
                                    "\(cut.start, specifier: "%.1f") to \(cut.end, specifier: "%.1f")",
                                    systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Pointer") {
                VStack(alignment: .leading) {
                    Toggle("Highlight pointer", isOn: $model.document.showsPointer)
                    Toggle("Show click markers", isOn: $model.document.showsClickMarkers)
                    LabeledContent("Smoothing") {
                        Slider(value: $model.document.pointerSmoothing, in: 0...1)
                    }
                    LabeledContent("Size") {
                        Slider(value: $model.document.pointerScale, in: 0.5...3)
                    }
                    Toggle("Automatic click zooms", isOn: $model.document.automaticZooms)
                }
                .padding(6)
            }
            GroupBox("Text") {
                VStack {
                    TextField("Overlay text", text: $model.overlayText)
                    Button("Add at playhead", action: model.addText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    ForEach(model.document.texts) { text in
                        HStack {
                            Text(text.text).lineLimit(1)
                            Spacer()
                            Button {
                                model.document.texts.removeAll { $0.id == text.id }
                                model.persist()
                            } label: { Image(systemName: "trash") }
                        }
                    }
                }
                .padding(6)
            }
            GroupBox("Frame") {
                VStack {
                    Picker("Crop", selection: $crop) {
                        ForEach(ScreenRecordingCrop.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .onChange(of: crop) { _, value in model.applyCrop(value) }
                    ColorPicker("Background", selection: $background, supportsOpacity: false)
                        .onChange(of: background) { _, value in
                            model.document.backgroundHex = Self.hex(value)
                            model.persist()
                        }
                    LabeledContent("Padding") {
                        Slider(value: $model.document.padding, in: 0...160)
                    }
                }
                .padding(6)
            }
            GroupBox("Audio") {
                VStack {
                    LabeledContent("System") {
                        Slider(value: $model.document.systemAudioVolume, in: 0...2)
                    }
                    LabeledContent("Microphone") {
                        Slider(value: $model.document.microphoneVolume, in: 0...2)
                    }
                }
                .padding(6)
            }
            GroupBox("Export preset") {
                VStack {
                    Picker("Preset", selection: $model.document.preset) {
                        ForEach(model.presets) { Text($0.name).tag($0) }
                    }
                    Picker("Format", selection: $model.document.preset.format) {
                        Text("MP4").tag(ScreenRecordingFormat.mp4)
                        Text("GIF").tag(ScreenRecordingFormat.gif)
                    }
                    Stepper("Width: \(model.document.preset.width)",
                            value: $model.document.preset.width, in: 320...3840, step: 160)
                    Stepper("Frame rate: \(model.document.preset.frameRate)",
                            value: $model.document.preset.frameRate, in: 5...60)
                    Button("Save as preset", action: model.savePreset)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(6)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }
        }
        .onChange(of: model.document) { _, _ in model.persist() }
    }

    private var footer: some View {
        HStack {
            if model.exporting {
                ProgressView(value: model.exportProgress).frame(width: 180)
                Button("Cancel export", action: model.cancelExport)
            }
            if let url = model.finishedURL {
                Button("Copy file", action: model.copyFinished)
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            }
            Spacer()
            Button("Export", action: model.export)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.exporting)
        }
        .padding(12)
        .background(.bar)
    }

    private static func hex(_ color: Color) -> String {
        let value = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "#%02X%02X%02X", Int(value.redComponent * 255),
            Int(value.greenComponent * 255), Int(value.blueComponent * 255))
    }
}
