import AppKit
import EdithKit
import UserNotifications

@MainActor
final class SystemStatsStatusItem: NSObject, FeatureModule {
    private let item: NSStatusItem
    private var timer: Timer?
    private let sampler = SystemMonitorSampler()
    private var cpuAlert = SustainedThresholdGate()
    private var memoryAlert = SustainedThresholdGate()
    private var diskAlert = SustainedThresholdGate()
    private var batteryAlert = SustainedThresholdGate()
    private var sleepObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var cachedTintHex: String?
    private var cachedGlyphs: [String: NSAttributedString] = [:]
    private var numberAttributes: [NSAttributedString.Key: Any] = [:]
    private var percentAttributes: [NSAttributedString.Key: Any] = [:]

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        StatusItemMenu.attach(to: item, target: self, action: #selector(clicked))
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
        sampler.reset()
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
        sampler.reset()
        resetAlerts()
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
        let snapshot = sampler.sample()
        ensureStyleCache()
        let title = NSMutableAttributedString()
        appendStat(symbol: "cpu", value: snapshot.cpuPercent, into: title)
        title.append(NSAttributedString(string: "  "))
        appendStat(symbol: "memorychip", value: snapshot.memoryPercent, into: title)
        item.button?.attributedTitle = title
        item.button?.toolTip = details(snapshot)
        evaluateAlerts(snapshot)
    }

    private func ensureStyleCache() {
        let hex = SharedDefaults.store.string(forKey: AppStorageKeys.MenuBar.statsColorHex)
        guard cachedTintHex != hex || cachedGlyphs.isEmpty else { return }
        cachedTintHex = hex
        let color = LimitsStatusItem.nsColor(hex: hex) ?? .white
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

    private func details(_ snapshot: SystemMonitorSnapshot) -> String {
        let gpu = snapshot.gpuPercent.map { String(format: "%.0f%%", $0) } ?? "unavailable"
        let storage =
            snapshot.rootDiskUsedPercent.map { String(format: "%.0f%% used", $0) }
            ?? "unavailable"
        let battery: String
        if let value = snapshot.battery {
            let watts = value.watts.map { String(format: " · %+.1f W", $0) } ?? ""
            battery = "\(value.percent)% · \(value.status)\(watts)"
        } else {
            battery = "not installed"
        }
        return [
            String(
                format: "CPU %.0f%% · Memory %.0f%% · GPU %@", snapshot.cpuPercent,
                snapshot.memoryPercent, gpu),
            "Network ↓ \(ByteFormatter.rate(snapshot.network.inboundBytesPerSecond))  ↑ \(ByteFormatter.rate(snapshot.network.outboundBytesPerSecond))",
            "Disk read \(ByteFormatter.rate(snapshot.disk.inboundBytesPerSecond))  write \(ByteFormatter.rate(snapshot.disk.outboundBytesPerSecond))",
            "Startup disk \(storage) · Battery \(battery)",
        ].joined(separator: "\n")
    }

    private func evaluateAlerts(_ snapshot: SystemMonitorSnapshot) {
        let defaults = SharedDefaults.store
        guard defaults.bool(forKey: AppStorageKeys.MenuBar.statsAlerts) else {
            resetAlerts()
            return
        }
        let duration: TimeInterval = 12
        if cpuAlert.evaluate(
            value: snapshot.cpuPercent,
            threshold: threshold(AppStorageKeys.MenuBar.statsCPUThreshold, fallback: 90),
            readAt: snapshot.sampledAt, sustainedSeconds: duration, direction: .atLeast)
        {
            SystemMonitorNotifier.send(.cpu(snapshot.cpuPercent))
        }
        if memoryAlert.evaluate(
            value: snapshot.memoryPercent,
            threshold: threshold(AppStorageKeys.MenuBar.statsMemoryThreshold, fallback: 90),
            readAt: snapshot.sampledAt, sustainedSeconds: duration, direction: .atLeast)
        {
            SystemMonitorNotifier.send(.memory(snapshot.memoryPercent))
        }
        if diskAlert.evaluate(
            value: snapshot.rootDiskUsedPercent,
            threshold: threshold(AppStorageKeys.MenuBar.statsDiskThreshold, fallback: 90),
            readAt: snapshot.storageReadAt, sustainedSeconds: duration, direction: .atLeast)
        {
            SystemMonitorNotifier.send(.disk(snapshot.rootDiskUsedPercent ?? 0))
        }
        let batteryValue = snapshot.battery.flatMap { $0.externalPower ? nil : Double($0.percent) }
        if batteryAlert.evaluate(
            value: batteryValue,
            threshold: threshold(AppStorageKeys.MenuBar.statsBatteryThreshold, fallback: 20),
            readAt: snapshot.batteryReadAt, sustainedSeconds: duration, direction: .atMost)
        {
            SystemMonitorNotifier.send(.battery(snapshot.battery?.percent ?? 0))
        }
    }

    private func threshold(_ key: String, fallback: Double) -> Double {
        SharedDefaults.store.object(forKey: key) as? Double ?? fallback
    }

    private func resetAlerts() {
        cpuAlert.reset()
        memoryAlert.reset()
        diskAlert.reset()
        batteryAlert.reset()
    }
}

private enum SystemMonitorAlert {
    case cpu(Double)
    case memory(Double)
    case disk(Double)
    case battery(Int)

    var identifier: String {
        switch self {
        case .cpu: "system-monitor.cpu"
        case .memory: "system-monitor.memory"
        case .disk: "system-monitor.disk"
        case .battery: "system-monitor.battery"
        }
    }

    var title: String {
        switch self {
        case .cpu: "CPU pressure is staying high"
        case .memory: "Memory pressure is staying high"
        case .disk: "The startup disk is almost full"
        case .battery: "Battery is running low"
        }
    }

    var body: String {
        switch self {
        case let .cpu(value): String(format: "CPU usage has held at %.0f%% or higher.", value)
        case let .memory(value):
            String(format: "Memory usage has held at %.0f%% or higher.", value)
        case let .disk(value): String(format: "The startup disk is %.0f%% full.", value)
        case let .battery(value): "Battery has stayed at \(value)% while unplugged."
        }
    }
}

private enum SystemMonitorNotifier {
    static func send(_ alert: SystemMonitorAlert, center: UNUserNotificationCenter = .current()) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        center.removeDeliveredNotifications(withIdentifiers: [alert.identifier])
        center.add(
            UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
    }
}
