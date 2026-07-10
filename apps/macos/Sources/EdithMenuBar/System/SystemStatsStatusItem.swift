import AppKit
import EdithKit

@MainActor
final class SystemStatsStatusItem: NSObject, FeatureModule {
    private let item: NSStatusItem
    private var timer: Timer?
    private var previous: CPUTicks?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        previous = SystemStatsReader.readCPUTicks()
        update()
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
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
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        item.button?.title = String(format: "CPU %.0f%%  RAM %.0f%%", cpu, memory)
    }
}
