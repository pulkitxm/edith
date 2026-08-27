import AppKit
import Carbon.HIToolbox
import EdithKit
import Observation

protocol CaptureScreenshotCapturing: Sendable {
    func capture() async throws -> URL
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
    @ObservationIgnored private var readObserver: NSObjectProtocol?
    @ObservationIgnored private var screenshotObserver: NSObjectProtocol?
    @ObservationIgnored private var preview: CapturePreviewController?
    @ObservationIgnored private var generation = 0

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
        readObserver = IPC.observe(IPC.Name.requestScreenRead) { [weak self] in
            self?.start(.read)
        }
        screenshotObserver = IPC.observe(IPC.Name.requestScreenshot) { [weak self] in
            self?.start(.screenshot)
        }
    }

    func registerHotKeys() {
        GlobalHotKey.set(
            id: GlobalHotKey.ID.captureRead, keyCode: CaptureToolsHotKeys.readCode,
            modifiers: CaptureToolsHotKeys.readMods
        ) { [weak self] in self?.start(.read) }
        GlobalHotKey.set(
            id: GlobalHotKey.ID.captureScreenshot, keyCode: CaptureToolsHotKeys.screenshotCode,
            modifiers: CaptureToolsHotKeys.screenshotMods
        ) { [weak self] in self?.start(.screenshot) }
    }

    func start(_ operation: CaptureToolOperation) {
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

    func shutdown() {
        generation &+= 1
        task?.cancel()
        task = nil
        session.cancel()
        preview?.close()
        preview = nil
        GlobalHotKey.clear(id: GlobalHotKey.ID.captureRead)
        GlobalHotKey.clear(id: GlobalHotKey.ID.captureScreenshot)
        if let readObserver { IPC.stopObserving(readObserver) }
        if let screenshotObserver { IPC.stopObserving(screenshotObserver) }
        readObserver = nil
        screenshotObserver = nil
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
            let url = try await session.capture()
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
            let result = try finalize(recognition, data: data, operation: operation)
            let copied = operation == .read && copy(result)
            let sourceImage = NSImage(data: data) ?? NSImage(size: .zero)
            preview?.close()
            preview = CapturePreviewController(
                image: sourceImage, pngData: data, recognition: result,
                operation: operation, copyMode: copyMode(), copiedResult: copied)
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
        _ recognition: CaptureRecognition, data: Data, operation: CaptureToolOperation
    ) throws -> CaptureRecognition {
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
        }
        return result
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
}
