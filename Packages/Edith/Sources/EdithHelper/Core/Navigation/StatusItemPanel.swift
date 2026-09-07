import AppKit
import EdithKit
import SwiftUI

@MainActor
final class StatusItemPanel {
    struct Action {
        let title: String
        var enabled = true
        let perform: () -> Void
    }

    private var menu: NSMenu?

    func close() {
        menu?.cancelTracking()
    }

    func show<Content: View>(
        from item: NSStatusItem, title: String, actions: [Action],
        @ViewBuilder content: () -> Content
    ) {
        guard let button = item.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let readings = NSMenuItem()
        let view = NSHostingView(
            rootView: content()
                .font(.system(size: NSFont.systemFontSize))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(width: 310))
        view.frame.size = view.fittingSize
        readings.isEnabled = false
        readings.view = view
        menu.addItem(readings)
        menu.addItem(.separator())
        for action in actions {
            let row = StatusPanelAction(title: action.title, perform: action.perform)
            row.isEnabled = action.enabled
            menu.addItem(row)
        }
        menu.addItem(.separator())
        menu.addItem(StatusPanelAction(title: "Quit Edith") { AppRuntimeCenter().quitCompletely() })
        self.menu = menu
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
        self.menu = nil
    }
}

@MainActor
private final class StatusPanelAction: NSMenuItem {
    private let perform: () -> Void

    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        perform()
    }
}

struct StatusProgressRow: View {
    let title: String
    let percent: Double?
    var resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if let resetsAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(MenuCountdown.remaining(until: resetsAt, now: context.date))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Time until reset")
                            .accessibilityValue(
                                MenuCountdown.remaining(until: resetsAt, now: context.date))
                    }
                    .fixedSize()
                }
            }
            HStack(spacing: 10) {
                ProgressView(value: percent.map { max(0, min(100, $0)) } ?? 0, total: 100)
                    .accessibilityLabel(title)
                Text(percent.map { "\(Int(max(0, min(100, $0))))%" } ?? "N/A")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                    .accessibilityLabel(
                        percent.map { "\(Int(max(0, min(100, $0)))) percent used" }
                            ?? "Usage unavailable")
            }
        }
    }
}

enum MenuCountdown {
    static func remaining(until reset: Date, now: Date) -> String {
        let interval = reset.timeIntervalSince(now)
        guard interval.isFinite, interval > 0 else { return "0s" }
        let total = Int(min(interval.rounded(.up), Double(Int.max / 2)))
        let days = total / 86400
        let hours = total % 86400 / 3600
        let minutes = total % 3600 / 60
        let seconds = total % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if days > 0 || hours > 0 { parts.append("\(hours)h") }
        if days > 0 || hours > 0 || minutes > 0 { parts.append("\(minutes)m") }
        parts.append("\(seconds)s")
        return parts.joined(separator: " ")
    }
}
