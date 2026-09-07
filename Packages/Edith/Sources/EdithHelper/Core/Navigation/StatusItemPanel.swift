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
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(percent.map { "\(Int(max(0, min(100, $0))))%" } ?? "Unavailable")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let percent {
                ProgressView(value: max(0, min(100, percent)), total: 100)
            }
            if let resetsAt {
                Text("Resets in \(resetsAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
