import AppKit
import EdithKit

@MainActor
final class SystemStatsStatusItem: NSObject, FeatureModule {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var previous: CPUTicks?
    private var sleepObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var cachedTintKey: String?
    private var cachedGlyphs: [String: NSAttributedString] = [:]
    private var numberAttributes: [NSAttributedString.Key: Any] = [:]
    private var percentAttributes: [NSAttributedString.Key: Any] = [:]

    override init() {
        super.init()
        ensureStyleCache()
        previous = SystemStatsReader.readCPUTicks()
        let initialTitle = title(cpu: 0, memory: SystemStatsReader.memoryUsedPercent())
        let sizingTitle = title(cpu: 100, memory: 100)
        item = NSStatusBar.system.statusItem(
            withLength: StatusItemSizing.titleLength(sizingTitle))
        item.autosaveName = "systemStats.v2"
        item.isVisible = true
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
        stopTimer()
        for observer in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sleepObservers = []
        for observer in lockObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        lockObservers = []
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clicked() {
        StatusItemMenu.handleClick(on: item) { MainApp.open(section: "system") }
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
        ensureStyleCache()
        item.button?.attributedTitle = title(cpu: cpu, memory: memory)
    }

    private func title(cpu: Double, memory: Double) -> NSAttributedString {
        let title = NSMutableAttributedString()
        appendStat(symbol: "cpu", value: cpu, into: title)
        title.append(NSAttributedString(string: "  "))
        appendStat(symbol: "memorychip", value: memory, into: title)
        return title
    }

    private func ensureStyleCache() {
        let defaults = SharedDefaults.store
        let mode = MenuBarTintMode(
            preference: defaults.string(forKey: AppStorageKeys.MenuBar.statsColorMode))
        let hex = defaults.string(forKey: AppStorageKeys.MenuBar.statsColorHex)
        let key = "\(mode):\(hex ?? "")"
        guard cachedTintKey != key || cachedGlyphs.isEmpty else { return }
        cachedTintKey = key
        let color = mode.color(custom: LimitsStatusItem.nsColor(hex: hex))
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
