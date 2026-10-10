#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Observation
import SwiftUI

@MainActor
final class SystemStatsStatusItem: NSObject, FeatureModule {
    private let panel = StatusItemPanel()
    let snapshot = SystemMenuSnapshot()
    private var item: NSStatusItem?
    private let fixture: WorkerFixtureAdmission?
    var systemResourceCount: Int {
        (item == nil ? 0 : 1) + (timer == nil ? 0 : 1) + sleepObservers.count + lockObservers.count
    }
    private var timer: Timer?
    private var previous: CPUTicks?
    private var sleepObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var cachedTintKey: String?
    private var displayedTitle: (cpu: Int, memory: Int, tint: String?)?
    private var cachedGlyphs: [String: NSAttributedString] = [:]
    private var numberAttributes: [NSAttributedString.Key: Any] = [:]
    private var percentAttributes: [NSAttributedString.Key: Any] = [:]

    override convenience init() { self.init(fixture: nil) }

    init(fixture: WorkerFixtureAdmission?) {
        precondition(fixture == nil || fixture?.extensionID == "systemStats")
        self.fixture = fixture
        super.init()
        if fixture != nil { snapshot.cpu = 12; snapshot.memory = 34; return }
        ensureStyleCache()
        previous = SystemStatsReader.readCPUTicks()
        let initialTitle = title(cpu: 0, memory: SystemStatsReader.memoryUsedPercent())
        let item = NSStatusBar.system.statusItem(
            withLength: StatusItemSizing.titleLength(initialTitle))
        self.item = item
        StatusItemMenu.attach(to: item, target: self, action: #selector(clicked))
        item.button?.attributedTitle = initialTitle
        startTimer()
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            workspace.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.stopTimer() }
            },
            workspace.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.startTimer() }
            },
        ]
        let dnc = DistributedNotificationCenter.default()
        lockObservers = [
            dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.stopTimer() }
            },
            dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main)
            { [weak self] _ in
                Task { @MainActor in self?.startTimer() }
            },
        ]
    }

    private func startTimer() {
        guard timer == nil else { return }
        previous = SystemStatsReader.readCPUTicks()
        update()
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func shutdown() {
        panel.close()
        stopTimer()
        for observer in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sleepObservers = []
        for observer in lockObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        lockObservers = []
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    @objc private func clicked() {
        guard let item else { return }
        StatusItemMenu.handleClick(on: item) {
            let snapshot = snapshot
            panel.show(
                from: item, title: "System",
                actions: [
                    .init(title: "Open Settings…") { ExtensionPresentation.showWindow() }
                ]
            ) {
                SystemMenuReadings(snapshot: snapshot)
            }
        }
    }

    private func update() {
        var cpu = 0.0
        if let previous, let current = SystemStatsReader.readCPUTicks() {
            cpu = SystemStatsReader.cpuUsage(previous: previous, current: current)
            self.previous = current
        } else {
            previous = SystemStatsReader.readCPUTicks()
        }
        let memory = SystemStatsReader.memoryUsedPercent()
        snapshot.cpu = cpu
        snapshot.memory = memory
        ensureStyleCache()
        let shown = (cpu: Int(cpu.rounded()), memory: Int(memory.rounded()), tint: cachedTintKey)
        if let displayedTitle, displayedTitle == shown { return }
        displayedTitle = shown
        let title = title(cpu: cpu, memory: memory)
        item?.length = StatusItemSizing.titleLength(title)
        item?.button?.attributedTitle = title
    }

    private func title(cpu: Double, memory: Double) -> NSAttributedString {
        let title = NSMutableAttributedString()
        appendStat(symbol: "cpu", value: cpu, into: title)
        title.append(NSAttributedString(string: " "))
        appendStat(symbol: "memorychip", value: memory, into: title)
        return title
    }

    private func ensureStyleCache() {
        let defaults = SharedDefaults.store
        let preference = SystemStatsColorPreference(defaults: defaults)
        guard cachedTintKey != preference.cacheKey || cachedGlyphs.isEmpty else { return }
        cachedTintKey = preference.cacheKey
        let color = preference.tint
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        var glyphs: [String: NSAttributedString] = [:]
        for symbol in ["cpu", "memorychip"] {
            guard
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
            else { continue }
            image.isTemplate = true
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0, y: -1.5, width: image.size.width, height: image.size.height)
            let glyph = NSMutableAttributedString(attachment: attachment)
            glyph.addAttribute(
                .foregroundColor, value: color,
                range: NSRange(location: 0, length: glyph.length))
            glyph.append(NSAttributedString(string: " "))
            glyphs[symbol] = glyph
        }
        cachedGlyphs = glyphs
        numberAttributes = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color,
        ]
        percentAttributes = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(0.75),
        ]
    }

    private func appendStat(symbol: String, value: Double, into out: NSMutableAttributedString) {
        if let glyph = cachedGlyphs[symbol] {
            out.append(glyph)
        }
        out.append(
            NSAttributedString(string: "\(Int(value.rounded()))", attributes: numberAttributes))
        out.append(NSAttributedString(string: "%", attributes: percentAttributes))
    }
}

@MainActor
@Observable
final class SystemMenuSnapshot {
    var cpu = 0.0
    var memory = 0.0
}

struct SystemMenuReadings: View {
    private let snapshot: SystemMenuSnapshot?
    private let cpu: Double
    private let memory: Double

    init(snapshot: SystemMenuSnapshot) {
        self.snapshot = snapshot
        cpu = 0
        memory = 0
    }

    init(cpu: Double, memory: Double) {
        snapshot = nil
        self.cpu = cpu
        self.memory = memory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusProgressRow(title: "CPU", percent: snapshot?.cpu ?? cpu)
            StatusProgressRow(title: "Memory", percent: snapshot?.memory ?? memory)
        }
    }
}
