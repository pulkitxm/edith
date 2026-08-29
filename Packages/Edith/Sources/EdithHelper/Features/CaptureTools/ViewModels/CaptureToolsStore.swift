import AppKit
import Carbon.HIToolbox
import EdithKit
import Observation

protocol CaptureScreenshotCapturing: Sendable {
    func capture(_ mode: CaptureMode) async throws -> URL
    func cancel()
}

extension CaptureScreenshotSession: CaptureScreenshotCapturing {}

@MainActor
@Observable
final class CaptureToolsStore: FeatureModule {
    private(set) var history: [CaptureRecognition] = []
    private(set) var inProgress = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let session: any CaptureScreenshotCapturing
    @ObservationIgnored private let screenCaptureGranted: () -> Bool
    @ObservationIgnored private let requestScreenCapture: () -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var preview: CapturePreviewController?
    @ObservationIgnored private var library: CaptureLibraryController?
    @ObservationIgnored private var editors: [CaptureEditorController] = []
    @ObservationIgnored private var pins: [CapturePinController] = []
    @ObservationIgnored private let recorder = ScreenRecordingCoordinator()
    @ObservationIgnored private var generation = 0

    var recordingStatus: ScreenRecordingStatus { recorder.status }

    init() {
        session = CaptureScreenshotSession()
        screenCaptureGranted = { CGPreflightScreenCaptureAccess() }
        requestScreenCapture = { IPC.post(IPC.Name.grantScreenRecording) }
        history = CaptureHistoryStore.load()
        startObservers()
    }

    init(
        session: any CaptureScreenshotCapturing,
        screenCaptureGranted: @escaping () -> Bool,
        requestScreenCapture: @escaping () -> Void
    ) {
        self.session = session
        self.screenCaptureGranted = screenCaptureGranted
        self.requestScreenCapture = requestScreenCapture
        history = CaptureHistoryStore.load()
        startObservers()
    }

    private func startObservers() {
        observers = [
            IPC.observe(IPC.Name.requestScreenRead) { [weak self] in self?.start(.read) },
            IPC.observe(IPC.Name.requestCaptureArea) { [weak self] in self?.start(.area) },
            IPC.observe(IPC.Name.requestCaptureWindow) { [weak self] in self?.start(.window) },
            IPC.observe(IPC.Name.requestCaptureScreen) { [weak self] in self?.start(.screen) },
            IPC.observe(IPC.Name.requestCaptureLibrary) { [weak self] in self?.showLibrary() },
            IPC.observe(IPC.Name.requestRecordingArea) { [weak self] in self?.startRecording(.area)
            },
            IPC.observe(IPC.Name.requestRecordingWindow) { [weak self] in
                self?.startRecording(.window)
            },
            IPC.observe(IPC.Name.requestRecordingDisplay) { [weak self] in
                self?.startRecording(.display)
            },
            IPC.observe(IPC.Name.requestRecordingPause) { [weak self] in self?.recorder.pause() },
            IPC.observe(IPC.Name.requestRecordingResume) { [weak self] in self?.recorder.resume() },
            IPC.observe(IPC.Name.requestRecordingStop) { [weak self] in self?.recorder.stop() },
            IPC.observe(IPC.Name.requestRecordingCancel) { [weak self] in self?.recorder.cancel() },
            IPC.observe(IPC.Name.requestRecordingLibrary) { [weak self] in
                self?.recorder.showLibrary()
            },
        ]
    }

    func registerHotKeys() {
        GlobalHotKey.set(
            id: GlobalHotKey.ID.captureRead, keyCode: CaptureToolsHotKeys.readCode,
            modifiers: CaptureToolsHotKeys.readMods
        ) { [weak self] in self?.start(.read) }
        GlobalHotKey.set(
            id: GlobalHotKey.ID.captureScreenshot, keyCode: CaptureToolsHotKeys.screenshotCode,
            modifiers: CaptureToolsHotKeys.screenshotMods
        ) { [weak self] in self?.start(.area) }
        GlobalHotKey.set(
            id: GlobalHotKey.ID.captureRecording, keyCode: CaptureToolsHotKeys.recordingCode,
            modifiers: CaptureToolsHotKeys.recordingMods
        ) { [weak self] in
            if self?.recorder.status.state == .recording || self?.recorder.status.state == .paused {
                self?.recorder.stop()
            } else {
                self?.recorder.start(.area)
            }
        }
    }

    func start(_ operation: CaptureToolOperation) {
        guard operation != .library else {
            showLibrary()
            return
        }
        if inProgress {
            cancel()
            return
        }
        guard screenCaptureGranted() else {
            errorMessage = "Screen Recording access is required to capture the screen."
            requestScreenCapture()
            return
        }
        generation &+= 1
        let token = generation
        inProgress = true
        errorMessage = nil
        task = Task { [weak self] in
            await self?.run(operation, token: token)
        }
    }

    func cancel() {
        guard inProgress else { return }
        generation &+= 1
        task?.cancel()
        task = nil
        session.cancel()
        inProgress = false
        errorMessage = nil
    }

    func startRecording(_ source: ScreenRecordingSource) {
        guard screenCaptureGranted() else {
            errorMessage = "Screen Recording access is required to record the screen."
            requestScreenCapture()
            return
        }
        recorder.start(source)
    }

    func stopRecording() { recorder.stop() }

    func cancelRecording() { recorder.cancel() }

    func pauseOrResumeRecording() { recorder.pauseOrResume() }

    func showRecordingLibrary() { recorder.showLibrary() }

    func shutdown() {
        generation &+= 1
        task?.cancel()
        task = nil
        session.cancel()
        preview?.close()
        preview = nil
        library?.close()
        library = nil
        editors.forEach { $0.close() }
        editors = []
        pins.forEach { $0.close() }
        pins = []
        recorder.shutdown()
        GlobalHotKey.clear(id: GlobalHotKey.ID.captureRead)
        GlobalHotKey.clear(id: GlobalHotKey.ID.captureScreenshot)
        GlobalHotKey.clear(id: GlobalHotKey.ID.captureRecording)
        observers.forEach(IPC.stopObserving)
        observers = []
        inProgress = false
    }

    private func run(_ operation: CaptureToolOperation, token: Int) async {
        var temporaryURL: URL?
        defer {
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            if generation == token {
                inProgress = false
                task = nil
            }
        }
        do {
            guard let mode = operation.captureMode else { return }
            let url = try await session.capture(mode)
            temporaryURL = url
            guard !Task.isCancelled, generation == token else { return }
            let detectsCodes =
                SharedDefaults.store.object(forKey: AppStorageKeys.Capture.detectCodes) as? Bool
                ?? true
            let (data, recognition) = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                let image = try CaptureScreenshotImage.load(url)
                let recognition = try CaptureRecognizer.recognize(
                    image, detectCodes: detectsCodes)
                return (data, recognition)
            }.value
            guard !Task.isCancelled, generation == token else { return }
            let finalized = try finalize(
                recognition, data: data, operation: operation, mode: mode)
            let result = finalized.recognition
            let copied = operation == .read && copy(result)
            if operation != .read,
                SharedDefaults.store.object(forKey: AppStorageKeys.Capture.copyAfterCapture)
                    as? Bool == true
            {
                copyImage(data)
            }
            let sourceImage = NSImage(data: data) ?? NSImage(size: .zero)
            preview?.close()
            preview = CapturePreviewController(
                item: finalized.item, image: sourceImage, pngData: data,
                recognition: result, operation: operation, copyMode: copyMode(),
                copiedResult: copied,
                edit: { [weak self] in self?.openEditor($0) },
                pin: { [weak self] in self?.pin($0) },
                delete: { [weak self] item in
                    try? CaptureLibraryStore.remove(item)
                    self?.library?.reload()
                    IPC.post(IPC.Name.settingsChanged)
                })
            preview?.show()
        } catch CaptureScreenshotError.cancelled {
            errorMessage = nil
        } catch is CancellationError {
            errorMessage = nil
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func finalize(
        _ recognition: CaptureRecognition, data: Data, operation: CaptureToolOperation,
        mode: CaptureMode
    ) throws -> (recognition: CaptureRecognition, item: CaptureLibraryItem?) {
        var savedPath: String?
        let save =
            SharedDefaults.store.object(forKey: AppStorageKeys.Capture.saveScreenshots) as? Bool
            ?? false
        if operation == .read, save {
            savedPath = try CaptureScreenshotArchive.save(data).path
        }
        let result = CaptureRecognition(
            capturedAt: recognition.capturedAt, text: recognition.text,
            codes: recognition.codes, imagePath: savedPath)
        if operation == .read {
            let raw =
                SharedDefaults.store.object(forKey: AppStorageKeys.Capture.historySize) as? Int
                ?? 10
            CaptureHistoryStore.add(result, limit: min(max(raw, 1), 25))
            history = CaptureHistoryStore.load()
            IPC.post(IPC.Name.settingsChanged)
            return (result, nil)
        } else {
            let item = try CaptureLibraryStore.add(data, mode: mode, recognition: result)
            IPC.post(IPC.Name.settingsChanged)
            library?.reload()
            return (result, item)
        }
    }

    private func copyImage(_ data: Data) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setData(data, forType: .png) {
            IPC.post(IPC.Name.clipboardChanged)
        }
    }

    private func showLibrary() {
        if library == nil {
            library = CaptureLibraryController(
                edit: { [weak self] in self?.openEditor($0) },
                pin: { [weak self] in self?.pin($0) })
        }
        library?.show()
    }

    private func openEditor(_ item: CaptureLibraryItem) {
        guard let image = NSImage(contentsOf: CaptureLibraryStore.imageURL(for: item)),
            let editor = CaptureEditorController(
                item: item, image: image,
                updated: { [weak self] in
                    self?.library?.reload()
                    IPC.post(IPC.Name.settingsChanged)
                }, pin: { [weak self] in self?.pin($0) })
        else {
            NSSound.beep()
            return
        }
        editors.removeAll { !$0.isVisible }
        editors.append(editor)
        editor.show()
    }

    private func pin(_ data: Data) {
        guard let controller = CapturePinController(data: data) else {
            NSSound.beep()
            return
        }
        pins.removeAll { !$0.isVisible }
        pins.append(controller)
        controller.show()
    }

    private func copy(_ result: CaptureRecognition) -> Bool {
        let output = result.output(for: copyMode())
        guard !output.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(output, forType: .string)
        if copied { IPC.post(IPC.Name.clipboardChanged) }
        return copied
    }

    private func copyMode() -> CaptureCopyMode {
        let raw = SharedDefaults.store.string(forKey: AppStorageKeys.Capture.copyMode) ?? ""
        return CaptureCopyMode(rawValue: raw) ?? .smart
    }
}

enum CaptureToolsHotKeys {
    static var readCode: Int {
        SharedDefaults.store.object(forKey: AppStorageKeys.Capture.readHotKeyCode) as? Int
            ?? kVK_ANSI_R
    }
    static var readMods: Int {
        SharedDefaults.store.object(forKey: AppStorageKeys.Capture.readHotKeyMods) as? Int
            ?? (controlKey | optionKey | cmdKey)
    }
    static var readLabel: String {
        SharedDefaults.store.string(forKey: AppStorageKeys.Capture.readHotKeyLabel) ?? "⌃⌥⌘R"
    }
    static var screenshotCode: Int {
        SharedDefaults.store.object(forKey: AppStorageKeys.Capture.screenshotHotKeyCode) as? Int
            ?? kVK_ANSI_S
    }
    static var screenshotMods: Int {
        SharedDefaults.store.object(forKey: AppStorageKeys.Capture.screenshotHotKeyMods) as? Int
            ?? (controlKey | optionKey | cmdKey)
    }
    static var screenshotLabel: String {
        SharedDefaults.store.string(forKey: AppStorageKeys.Capture.screenshotHotKeyLabel)
            ?? "⌃⌥⌘S"
    }
    static var recordingCode: Int {
        SharedDefaults.store.object(forKey: AppStorageKeys.Capture.recordingHotKeyCode) as? Int
            ?? kVK_ANSI_V
    }
    static var recordingMods: Int {
        SharedDefaults.store.object(forKey: AppStorageKeys.Capture.recordingHotKeyMods) as? Int
            ?? (controlKey | optionKey | cmdKey)
    }
    static var recordingLabel: String {
        SharedDefaults.store.string(forKey: AppStorageKeys.Capture.recordingHotKeyLabel)
            ?? "⌃⌥⌘V"
    }
}
