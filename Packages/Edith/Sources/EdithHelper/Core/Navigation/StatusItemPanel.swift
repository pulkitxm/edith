import AppKit
import EdithKit
import SwiftUI

@MainActor
final class StatusItemPanel: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    func close() {
        popover.performClose(nil)
    }

    func toggle<Content: View>(from item: NSStatusItem, @ViewBuilder content: () -> Content) {
        if popover.isShown {
            close()
            return
        }
        guard let button = item.button else { return }
        popover.delegate = self
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: content())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

struct StatusPanel<Content: View>: View {
    let title: String
    let open: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text("Edith").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Tap to open", action: open)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Divider()
            content()
            Divider()
            Button("Open Edith", action: open)
            Button("Quit Edith") { AppRuntimeCenter().quitCompletely() }
        }
        .buttonStyle(.plain)
        .padding(20)
        .frame(width: 340)
    }
}

struct StatusProgressRow: View {
    let title: String
    let percent: Double?
    var resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(percent.map { "\(Int(max(0, min(100, $0))))%" } ?? "Unavailable")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let percent {
                ProgressView(value: max(0, min(100, percent)), total: 100)
                    .tint(.blue)
            }
            if let resetsAt {
                Text("Resets \(resetsAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
