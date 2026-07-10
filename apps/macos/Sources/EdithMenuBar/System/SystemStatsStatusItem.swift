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
