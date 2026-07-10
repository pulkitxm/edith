import AppKit
import EdithKit

@MainActor
final class SystemStatsStatusItem: NSObject, FeatureModule {
    private let item: NSStatusItem
    private var timer: Timer?
    private var previous: CPUTicks?
    private var sleepObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        previous = SystemStatsReader.readCPUTicks()
        update()
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

    @objc private func clicked() { MainApp.openDashboard() }

    private func update() {
        var cpu = 0.0
        if let previous, let current = SystemStatsReader.readCPUTicks() {
            cpu = SystemStatsReader.cpuUsage(previous: previous, current: current)
            self.previous = current
        } else {
            previous = SystemStatsReader.readCPUTicks()
        }
        let memory = SystemStatsReader.memoryUsedPercent()
        let title = NSMutableAttributedString()
        appendStat(symbol: "cpu", value: cpu, into: title)
        title.append(NSAttributedString(string: "  "))
        appendStat(symbol: "memorychip", value: memory, into: title)
        item.button?.attributedTitle = title
    }

    private var tint: NSColor {
        LimitsStatusItem.nsColor(hex: SharedDefaults.store.string(forKey: "menuBarStatsColorHex"))
            ?? .white
    }

    private func appendStat(symbol: String, value: Double, into out: NSMutableAttributedString) {
        let color = tint
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        {
            image.isTemplate = true
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0, y: -1.5, width: image.size.width, height: image.size.height)
            let glyph = NSMutableAttributedString(attachment: attachment)
            glyph.addAttribute(
                .foregroundColor, value: color,
                range: NSRange(location: 0, length: glyph.length))
            out.append(glyph)
            out.append(NSAttributedString(string: " "))
        }
        out.append(
            NSAttributedString(
                string: "\(Int(value.rounded()))",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: color,
                ]))
        out.append(
            NSAttributedString(
                string: "%",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: color.withAlphaComponent(0.75),
                ]))
    }
}
