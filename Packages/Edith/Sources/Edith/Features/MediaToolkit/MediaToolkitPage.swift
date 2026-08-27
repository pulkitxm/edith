import AppKit
import EdithKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum MediaToolkitMode: String, CaseIterable, Identifiable {
    case images
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: "Images"
        case .video: "Video"
        }
    }
}

final class MediaCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

@MainActor
@Observable
final class MediaToolkitPageModel {
    var mode = MediaToolkitMode.images {
        didSet {
            if mode != oldValue, !isProcessing { clearResults() }
        }
    }
    private(set) var imageURLs: [URL] = []
    private(set) var videoURL: URL?
    var outputDirectory: URL?
    private(set) var imageResults: [MediaImageResult] = []
    private(set) var videoResult: MediaVideoResult?
    private(set) var isProcessing = false
    private(set) var progress = 0.0
    private(set) var status = "Ready"
    private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private var cancellationToken: MediaCancellationToken?

    var canProcess: Bool {
        !isProcessing && (mode == .images ? !imageURLs.isEmpty : videoURL != nil)
    }

    var resolvedOutputDirectory: URL? {
        if let outputDirectory { return outputDirectory }
        switch mode {
        case .images: return imageURLs.first?.deletingLastPathComponent()
        case .video: return videoURL?.deletingLastPathComponent()
        }
    }

    func add(_ urls: [URL]) {
        guard !isProcessing else { return }
        let images = urls.filter(Self.isImage)
        let videos = urls.filter(Self.isVideo)
        if !images.isEmpty {
            mode = .images
            var seen = Set(imageURLs.map(\.standardizedFileURL))
            imageURLs += images.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        } else if let video = videos.first {
            mode = .video
            videoURL = video.standardizedFileURL
        } else {
            errorMessage = "Choose an image or video that macOS can read."
            return
        }
        clearResults()
    }

    func removeImage(_ url: URL) {
        imageURLs.removeAll { $0 == url }
        clearResults()
    }

    func removeVideo() {
        videoURL = nil
        clearResults()
    }

    func clearSelection() {
        imageURLs = []
        videoURL = nil
        clearResults()
    }

    func process(imageOptions: MediaImageOptions, videoOptions: MediaVideoOptions) {
        guard canProcess, let destination = resolvedOutputDirectory else { return }
        let token = MediaCancellationToken()
        cancellationToken = token
        isProcessing = true
        progress = 0
        status = mode == .images ? "Converting images" : "Compressing video"
        errorMessage = nil
        imageResults = []
        videoResult = nil
        let selectedMode = mode
        let images = imageURLs
        let video = videoURL
        task = Task { [weak self] in
            guard let model = self else { return }
            do {
                switch selectedMode {
                case .images:
                    let results = try await Task.detached(priority: .userInitiated) {
                        try MediaToolkit.convertImages(
                            images, to: destination, options: imageOptions,
                            progress: { completed, total in
                                Task { @MainActor in
                                    model.progress = Double(completed) / Double(max(1, total))
                                    model.status = "Converted \(completed) of \(total)"
                                }
                            },
                            cancelled: { token.isCancelled })
                    }.value
                    guard model.cancellationToken === token else { return }
                    model.imageResults = results
                    let succeeded = results.filter { $0.outputURL != nil }.count
                    model.status = "Converted \(succeeded) of \(results.count)"
                case .video:
                    guard let video else { return }
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await MediaToolkit.compressVideo(
                            video, to: destination, options: videoOptions,
                            progress: { value in
                                Task { @MainActor in
                                    model.progress = value
                                    model.status = "Compressing \(Int(value * 100))%"
                                }
                            },
                            cancelled: { token.isCancelled })
                    }.value
                    guard model.cancellationToken === token else { return }
                    model.videoResult = result
                    model.status = "Compression complete"
                }
                model.progress = 1
                model.finish()
            } catch is CancellationError {
                guard model.cancellationToken === token else { return }
                model.status = "Cancelled"
                model.progress = 0
                model.finish()
            } catch {
                guard model.cancellationToken === token else { return }
                model.errorMessage = error.localizedDescription
                model.status = "Could not finish"
                model.progress = 0
                model.finish()
            }
        }
    }

    func cancel() {
        guard isProcessing else { return }
        status = "Cancelling"
        cancellationToken?.cancel()
        task?.cancel()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func clearResults() {
        imageResults = []
        videoResult = nil
        errorMessage = nil
        progress = 0
        status = "Ready"
    }

    private func finish() {
        isProcessing = false
        task = nil
        cancellationToken = nil
    }

    private static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }
}

struct MediaToolkitPage: View {
    @State private var model = MediaToolkitPageModel()
    @State private var dropTargeted = false
    @AppStorage(AppStorageKeys.MediaToolkit.imageFormat, store: SharedDefaults.store)
    private var imageFormat = MediaImageFormat.jpeg.rawValue
    @AppStorage(AppStorageKeys.MediaToolkit.imageMaxDimension, store: SharedDefaults.store)
    private var imageMaxDimension = 1600
    @AppStorage(AppStorageKeys.MediaToolkit.imageQuality, store: SharedDefaults.store)
    private var imageQuality = 0.82
    @AppStorage(AppStorageKeys.MediaToolkit.videoKeepAudio, store: SharedDefaults.store)
    private var videoKeepAudio = true
    @AppStorage(AppStorageKeys.MediaToolkit.videoTargetMegabytes, store: SharedDefaults.store)
    private var videoTargetMegabytes = 20
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PageHeader(
                "Media Toolkit",
                trailing: {
                    Label("ON-DEVICE", systemImage: "lock.fill")
                        .font(DashSkin.mono(9, weight: .semibold))
                        .foregroundStyle(DashSkin.accent(dark))
                        .padding(.horizontal, UIScale.pt(10))
                        .padding(.vertical, UIScale.pt(6))
                        .background(DashSkin.accent(dark).opacity(0.1), in: Capsule())
                },
                accessory: {
                    Picker("Media type", selection: $model.mode) {
                        ForEach(MediaToolkitMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: compact ? .infinity : UIScale.pt(320))
                    .disabled(model.isProcessing)
                })
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    intro
                    dropZone
                    if hasSelection { selectionCard }
                    settingsCard
                    outputCard
                    actionCard
                    if hasResults { resultsCard }
                }
                .pageContent(compact, width: .readable)
            }
        }
        .background(DashSkin.paper(dark))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                model.add(await MediaToolkitDrop.urls(from: providers))
            }
            return true
        }
        .onDisappear { model.cancel() }
    }

    private var hasSelection: Bool {
        model.mode == .images ? !model.imageURLs.isEmpty : model.videoURL != nil
    }

    private var hasResults: Bool {
        !model.imageResults.isEmpty || model.videoResult != nil
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: UIScale.pt(14)) {
            Image(systemName: model.mode == .images ? "photo.stack" : "film.stack")
                .font(.system(size: UIScale.pt(22), weight: .medium))
                .foregroundStyle(DashSkin.accent(dark))
                .frame(width: UIScale.pt(42), height: UIScale.pt(42))
                .background(
                    DashSkin.accent(dark).opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                Text(model.mode == .images ? "Prepare a whole image batch" : "Make a video fit")
                    .font(DashSkin.serif(20))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(
                    model.mode == .images
                        ? "Convert formats, resize the longest edge, and keep every original untouched."
                        : "Create a complete H.264 MP4 under a hard size limit without trimming the timeline."
                )
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(16))
        .mediaCard(dark)
    }

    private var dropZone: some View {
        Button(action: chooseInputs) {
            VStack(spacing: UIScale.pt(9)) {
                Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "plus.circle")
                    .font(.system(size: UIScale.pt(30), weight: .light))
                    .foregroundStyle(DashSkin.accent(dark))
                Text(model.mode == .images ? "Drop images here" : "Drop a video here")
                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(model.mode == .images ? "or choose multiple files" : "or choose one file")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .frame(maxWidth: .infinity, minHeight: UIScale.pt(128))
            .background(
                dropTargeted ? DashSkin.accent(dark).opacity(0.1) : DashSkin.paper2(dark),
                in: RoundedRectangle(cornerRadius: UIScale.pt(14))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(14))
                    .stroke(
                        dropTargeted ? DashSkin.accent(dark) : DashSkin.lineStrong(dark),
                        style: StrokeStyle(lineWidth: 1.2, dash: [7, 5]))
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isProcessing)
        .accessibilityLabel(model.mode == .images ? "Choose input images" : "Choose input video")
    }

    private var selectionCard: some View {
        MediaToolkitCard(
            title: model.mode == .images ? "Selected images" : "Selected video",
            subtitle: model.mode == .images ? "\(model.imageURLs.count) files" : nil
        ) {
            if model.mode == .images {
                ForEach(model.imageURLs, id: \.self) { url in
                    MediaToolkitFileRow(url: url) {
                        model.removeImage(url)
                    }
                    if url != model.imageURLs.last { Divider().opacity(0.4) }
                }
            } else if let url = model.videoURL {
                MediaToolkitFileRow(url: url) { model.removeVideo() }
            }
            HStack {
                Button(model.mode == .images ? "Add more" : "Choose another") { chooseInputs() }
                Spacer()
                Button("Clear", role: .destructive) { model.clearSelection() }
            }
            .buttonStyle(.edith(.borderless))
            .disabled(model.isProcessing)
        }
    }

    @ViewBuilder
    private var settingsCard: some View {
        if model.mode == .images {
            MediaToolkitCard(title: "Image settings", subtitle: imageSettingsSummary) {
                Picker(
                    "Format",
                    selection: $imageFormat.configured(AppStorageKeys.MediaToolkit.imageFormat)
                ) {
                    ForEach(MediaImageFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Longest edge") {
                    Picker(
                        "Longest edge",
                        selection: $imageMaxDimension.configured(
                            AppStorageKeys.MediaToolkit.imageMaxDimension)
                    ) {
                        Text("Original").tag(0)
                        ForEach([512, 1024, 1600, 2048, 3840], id: \.self) { value in
                            Text("\(value) px").tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: UIScale.pt(150))
                }
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    LabeledContent("Quality") {
                        Text("\(Int(imageQuality * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $imageQuality.configured(AppStorageKeys.MediaToolkit.imageQuality),
                        in: 0.1...1, step: 0.01)
                    Text("Quality affects JPEG and HEIC. PNG remains lossless.")
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(model.isProcessing)
        } else {
            MediaToolkitCard(title: "Video settings", subtitle: "H.264 · MP4") {
                LabeledContent("Maximum size") {
                    Stepper(
                        "\(videoTargetMegabytes) MB",
                        value: $videoTargetMegabytes.configured(
                            AppStorageKeys.MediaToolkit.videoTargetMegabytes),
                        in: 1...512
                    )
                    .monospacedDigit()
                }
                HStack(spacing: UIScale.pt(6)) {
                    ForEach([5, 10, 20, 50, 100], id: \.self) { value in
                        Button("\(value) MB") { setVideoTarget(value) }
                            .buttonStyle(.edith(.borderless))
                            .padding(.horizontal, UIScale.pt(7))
                            .padding(.vertical, UIScale.pt(4))
                            .background(
                                videoTargetMegabytes == value
                                    ? DashSkin.accent(dark).opacity(0.12) : Color.clear,
                                in: Capsule())
                    }
                }
                Toggle(
                    "Keep audio",
                    isOn: $videoKeepAudio.configured(
                        AppStorageKeys.MediaToolkit.videoKeepAudio))
                Text(
                    "The complete timeline is preserved. Very small targets may be refused rather than trimming the video."
                )
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(model.isProcessing)
        }
    }

    private var outputCard: some View {
        MediaToolkitCard(title: "Output", subtitle: "Originals stay untouched") {
            HStack(spacing: UIScale.pt(10)) {
                Image(systemName: "folder")
                    .foregroundStyle(DashSkin.accent(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(
                        model.outputDirectory == nil ? "Beside the selected files" : "Chosen folder"
                    )
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    Text(
                        model.resolvedOutputDirectory?.path(percentEncoded: false)
                            ?? "Select media first"
                    )
                    .font(DashSkin.mono(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer(minLength: UIScale.pt(8))
                if model.outputDirectory != nil {
                    Button("Use source folder") { model.outputDirectory = nil }
                        .buttonStyle(.edith(.borderless))
                }
                Button("Choose folder") { chooseOutputDirectory() }
            }
            .disabled(model.isProcessing)
        }
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(11)) {
            HStack(spacing: UIScale.pt(10)) {
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(model.status)
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                    Text(actionDetail)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: UIScale.pt(10))
                if model.isProcessing {
                    Button("Cancel", role: .cancel) { model.cancel() }
                } else {
                    Button(actionTitle) { process() }
                        .buttonStyle(.edith(.primary))
                        .disabled(!model.canProcess)
                }
            }
            if model.isProcessing {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(UIScale.pt(14))
        .background(
            DashSkin.accent(dark).opacity(dark ? 0.08 : 0.06),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(14))
                .stroke(DashSkin.accent(dark).opacity(0.22), lineWidth: 1)
        }
    }

    private var resultsCard: some View {
        MediaToolkitCard(title: "Finished output", subtitle: resultSummary) {
            ForEach(model.imageResults, id: \.inputURL) { result in
                MediaToolkitResultRow(
                    name: result.inputURL.lastPathComponent,
                    outputURL: result.outputURL,
                    inputBytes: result.inputBytes,
                    outputBytes: result.outputBytes,
                    error: result.error,
                    open: model.open,
                    reveal: model.reveal)
                if result.inputURL != model.imageResults.last?.inputURL {
                    Divider().opacity(0.4)
                }
            }
            if let result = model.videoResult {
                MediaToolkitResultRow(
                    name: result.inputURL.lastPathComponent,
                    outputURL: result.outputURL,
                    inputBytes: result.inputBytes,
                    outputBytes: result.outputBytes,
                    error: nil,
                    open: model.open,
                    reveal: model.reveal)
            }
        }
    }

    private var imageSettingsSummary: String {
        let dimension = imageMaxDimension == 0 ? "original size" : "\(imageMaxDimension) px"
        return "\(imageFormat.uppercased()) · \(dimension)"
    }

    private var actionTitle: String {
        model.mode == .images ? "Convert images" : "Compress video"
    }

    private var actionDetail: String {
        if model.isProcessing { return "You can cancel without changing the originals." }
        if model.mode == .images {
            return model.imageURLs.isEmpty
                ? "Choose one or more images to begin."
                : "\(model.imageURLs.count) image\(model.imageURLs.count == 1 ? "" : "s") ready."
        }
        return model.videoURL == nil ? "Choose one video to begin." : "The full video is ready."
    }

    private var resultSummary: String? {
        if let result = model.videoResult {
            return MediaToolkitFormatting.change(from: result.inputBytes, to: result.outputBytes)
        }
        let successful = model.imageResults.filter { $0.outputURL != nil }
        guard !successful.isEmpty else { return nil }
        return "\(successful.count) file\(successful.count == 1 ? "" : "s") written"
    }

    private func process() {
        let format = MediaImageFormat(rawValue: imageFormat) ?? .jpeg
        model.process(
            imageOptions: MediaImageOptions(
                format: format, quality: imageQuality,
                maxDimension: imageMaxDimension == 0 ? nil : imageMaxDimension),
            videoOptions: MediaVideoOptions(
                targetMegabytes: videoTargetMegabytes, keepAudio: videoKeepAudio))
    }

    private func setVideoTarget(_ value: Int) {
        $videoTargetMegabytes.configured(AppStorageKeys.MediaToolkit.videoTargetMegabytes)
            .wrappedValue = value
    }

    private func chooseInputs() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = model.mode == .images
        panel.allowedContentTypes = model.mode == .images ? [.image] : [.movie]
        panel.prompt = model.mode == .images ? "Add" : "Choose"
        panel.message =
            model.mode == .images ? "Choose images to convert" : "Choose a video to compress"
        guard panel.runModal() == .OK else { return }
        model.add(panel.urls)
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where converted media should be written"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.outputDirectory = url
    }
}

struct MediaToolkitCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer(minLength: UIScale.pt(8))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(UIScale.pt(15))
        .mediaCard(dark)
    }
}

struct MediaToolkitFileRow: View {
    let url: URL
    let remove: () -> Void

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(url.lastPathComponent)
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .lineLimit(1)
                Text(MediaToolkitFormatting.fileSize(url))
                    .font(DashSkin.mono(9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: UIScale.pt(8))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(url.lastPathComponent)")
        }
    }
}

struct MediaToolkitResultRow: View {
    let name: String
    let outputURL: URL?
    let inputBytes: Int64
    let outputBytes: Int64
    let error: String?
    let open: (URL) -> Void
    let reveal: (URL) -> Void

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: outputURL == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: UIScale.pt(18)))
                .foregroundStyle(outputURL == nil ? .red : .green)
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(name)
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .lineLimit(1)
                Text(error ?? MediaToolkitFormatting.change(from: inputBytes, to: outputBytes))
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: UIScale.pt(8))
            if let outputURL {
                Button("Open") { open(outputURL) }
                    .buttonStyle(.edith(.borderless))
                Button("Reveal") { reveal(outputURL) }
                    .buttonStyle(.edith(.borderless))
            }
        }
    }
}

enum MediaToolkitFormatting {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func fileSize(_ url: URL) -> String {
        let value = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return bytes(value)
    }

    static func change(from input: Int64, to output: Int64) -> String {
        guard input > 0 else { return bytes(output) }
        let percent = Int(((1 - Double(output) / Double(input)) * 100).rounded())
        let direction = percent >= 0 ? "smaller" : "larger"
        return "\(bytes(input)) to \(bytes(output)) · \(abs(percent))% \(direction)"
    }
}

enum MediaToolkitDrop {
    @MainActor
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = try? await provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier) as? URL
            {
                urls.append(url)
            } else if let data = try? await provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil)
            {
                urls.append(url)
            }
        }
        return urls
    }
}

extension View {
    fileprivate func mediaCard(_ dark: Bool) -> some View {
        background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(14))
                    .stroke(DashSkin.line(dark), lineWidth: 1)
            }
    }
}

struct MediaToolkitRows: View {
    @AppStorage(AppStorageKeys.Tabs.mediaToolkitEnabled, store: SharedDefaults.store)
    private var enabled = false
    @AppStorage(AppStorageKeys.MediaToolkit.imageFormat, store: SharedDefaults.store)
    private var imageFormat = MediaImageFormat.jpeg.rawValue
    @AppStorage(AppStorageKeys.MediaToolkit.imageMaxDimension, store: SharedDefaults.store)
    private var imageMaxDimension = 1600
    @AppStorage(AppStorageKeys.MediaToolkit.imageQuality, store: SharedDefaults.store)
    private var imageQuality = 0.82
    @AppStorage(AppStorageKeys.MediaToolkit.videoKeepAudio, store: SharedDefaults.store)
    private var videoKeepAudio = true
    @AppStorage(AppStorageKeys.MediaToolkit.videoTargetMegabytes, store: SharedDefaults.store)
    private var videoTargetMegabytes = 20

    var body: some View {
        Section("Image conversion") {
            Picker(
                "Format",
                selection: $imageFormat.configured(AppStorageKeys.MediaToolkit.imageFormat)
            ) {
                ForEach(MediaImageFormat.allCases) { format in
                    Text(format.rawValue.uppercased()).tag(format.rawValue)
                }
            }
            Picker(
                "Longest edge",
                selection: $imageMaxDimension.configured(
                    AppStorageKeys.MediaToolkit.imageMaxDimension)
            ) {
                Text("Original size").tag(0)
                ForEach([512, 1024, 1600, 2048, 3840], id: \.self) { value in
                    Text("\(value) px").tag(value)
                }
            }
            LabeledContent("Quality") {
                HStack {
                    Slider(
                        value: $imageQuality.configured(AppStorageKeys.MediaToolkit.imageQuality),
                        in: 0.1...1, step: 0.01
                    )
                    .frame(width: UIScale.pt(150))
                    Text("\(Int(imageQuality * 100))%")
                        .monospacedDigit()
                        .frame(width: UIScale.pt(38), alignment: .trailing)
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section("Video compression") {
            Stepper(
                "Maximum size: \(videoTargetMegabytes) MB",
                value: $videoTargetMegabytes.configured(
                    AppStorageKeys.MediaToolkit.videoTargetMegabytes),
                in: 1...512)
            Toggle(
                "Keep audio",
                isOn: $videoKeepAudio.configured(AppStorageKeys.MediaToolkit.videoKeepAudio))
            Button("Open Media Toolkit") { SectionWindow.open(.mediaToolkit) }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
