#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import Observation

@MainActor
@Observable
final class ColorPickerStore: FeatureModule {
    private(set) var history: [ColorSwatch] = []
    private(set) var copyError: String?
    private var stopped = false
    @ObservationIgnored private var requestObserver: NSObjectProtocol?

    private let fixture: WorkerFixtureAdmission?
    private(set) var fixtureCopies: [String] = []
    var systemResourceCount: Int { requestObserver == nil ? 0 : 1 }

    convenience init() { self.init(fixture: nil) }

    init(fixture: WorkerFixtureAdmission?) {
        precondition(fixture == nil || fixture?.extensionID == "colorPicker")
        self.fixture = fixture
        history = ColorHistoryStore.load()
        guard fixture == nil else { return }
        requestObserver = IPC.observe(IPC.Name.requestColorPick) { [weak self] in
            self?.pick()
        }
    }

    func shutdown() {
        stopped = true
        HotKeyRegistrar.clear(HotKeyCatalog.colorPicker)
        if let requestObserver { IPC.stopObserving(requestObserver) }
        requestObserver = nil
    }

    func reloadHistory() {
        guard !stopped else { return }
        history = ColorHistoryStore.load()
    }

    func registerHotKey() {
        guard fixture == nil, !stopped else { return }
        HotKeyRegistrar.install(HotKeyCatalog.colorPicker) { [weak self] in
            self?.pick()
        }
    }

    func pick() {
        guard !stopped else { return }
        if fixture != nil {
            commit(NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1)); return
        }
        ColorPickerOperationExecution.perform(.pick) { [weak self] color in
            guard let color else { return }
            Task { @MainActor in
                self?.commit(color)
            }
        }
    }

    func copyDefault(_ swatch: ColorSwatch) {
        copy(swatch, as: format)
    }

    private func commit(_ color: NSColor) {
        guard !stopped else { return }
        guard let converted = color.usingColorSpace(profile.nsColorSpace) else { return }
        let swatch = ColorSwatch(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            profile: profile)
        copy(swatch, as: format)
        ColorHistoryStore.add(swatch, limit: historySize)
        history = ColorHistoryStore.load()
        IPC.post(IPC.Name.settingsChanged)
    }

    func writeFixtureCopy(_ value: String) -> Bool {
        guard fixture != nil, !stopped else { return false }
        fixtureCopies.append(value)
        if fixtureCopies.count > 128 { fixtureCopies.removeFirst(fixtureCopies.count - 128) }
        return true
    }

    func copy(_ swatch: ColorSwatch, as format: ColorCopyFormat) {
        guard !stopped else { return }
        do {
            try ColorSwatchOperationExecution.perform(
                .copy, swatch: swatch, format: format,
                write: { value in
                    if self.fixture != nil { return self.writeFixtureCopy(value) }
                    NSPasteboard.general.clearContents()
                    return NSPasteboard.general.setString(value, forType: .string)
                })
            copyError = nil
        } catch {
            copyError = error.localizedDescription
            if fixture == nil { NSSound.beep() }
        }
    }

    private var format: ColorCopyFormat {
        let raw = SharedDefaults.store.string(forKey: AppStorageKeys.ColorPicker.copyFormat) ?? ""
        return ColorCopyFormat(rawValue: raw) ?? .hex
    }

    private var profile: ColorProfile {
        ColorProfile(
            rawValue: SharedDefaults.store.string(forKey: AppStorageKeys.ColorPicker.profile) ?? "")
            ?? .sRGB
    }

    private var historySize: Int {
        let raw =
            SharedDefaults.store.object(forKey: AppStorageKeys.ColorPicker.historySize) as? Int
            ?? 100
        return min(max(raw, 1), 100)
    }
}
