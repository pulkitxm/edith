import AppKit
import EdithExtensionUI
import Observation
import SwiftUI

@MainActor enum HostQuit {
    static func terminate() {
        for window in NSApp.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
    }

    static func closeWindows() {
        conceal()
        NSApp.setActivationPolicy(.accessory)
    }

    static func conceal() {
        for window in NSApp.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
        }
    }
}

@MainActor @Observable final class HostQuitWaitModel {
    var blockers: [String]
    @ObservationIgnored var quitNow: @MainActor () -> Void = {}
    @ObservationIgnored var keepOpen: @MainActor () -> Void = {}

    init(blockers: [String]) { self.blockers = blockers }

    var subject: String {
        switch blockers.count {
        case 0: "Some background work"
        case 1: blockers[0]
        case 2: "\(blockers[0]) and \(blockers[1])"
        default: "\(blockers[0]), \(blockers[1]) and \(blockers.count - 2) more"
        }
    }

    var message: String {
        let verb = blockers.count > 1 ? "are" : "is"
        return "\(subject) \(verb) still working. Edith quits on its own as soon as it is done."
    }

    var status: String {
        blockers.count == 1 ? "Waiting for \(blockers[0])" : "Waiting for \(blockers.count) tools"
    }
}

struct HostQuitWaitView: View {
    @Bindable var model: HostQuitWaitModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                PageGuideBadge(symbolName: "hourglass", size: 40)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text("Finishing up before quitting")
                        .font(.edithText(.headline))
                        .accessibilityAddTraits(.isHeader)
                    Text(model.message)
                        .font(.edithText(.callout))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: UIScale.pt(8)) {
                ProgressView().controlSize(.small)
                Text(model.status)
                    .font(.edithText(.caption))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
            }
            .padding(.horizontal, UIScale.pt(12))
            .frame(maxWidth: .infinity, minHeight: UIScale.pt(32), alignment: .leading)
            .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
            .accessibilityElement(children: .combine)
            Text("Quitting now stops this work, and anything it has not saved may be lost.")
                .font(.edithText(.caption))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: UIScale.pt(8)) {
                Spacer(minLength: 0)
                Button("Keep Edith Open") { model.keepOpen() }
                    .buttonStyle(.edith(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Quit Now") { model.quitNow() }
                    .buttonStyle(.edith(.destructive))
            }
        }
        .padding(UIScale.pt(20))
        .frame(width: UIScale.pt(400), alignment: .leading)
        .background(DashSkin.paper2(dark))
    }
}

@MainActor final class HostQuitWaitPanel {
    private let panel: NSPanel

    init(model: HostQuitWaitModel) {
        let hosting = NSHostingController(
            rootView: HostQuitWaitView(model: model)
                .controlSize(UIScale.controlSize)
                .themedControls())
        hosting.sizingOptions = .preferredContentSize
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: UIScale.pt(400), height: UIScale.pt(220)),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "Edith is finishing up"
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentViewController = hosting
    }

    static func present(_ model: HostQuitWaitModel) -> HostQuitWaitPanel {
        let wait = HostQuitWaitPanel(model: model)
        wait.show()
        return wait
    }

    func show() {
        guard !HostBackgroundTesting.enabled else {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderBack(nil)
            return
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { panel.close() }
}

@MainActor enum HostInstallLocationAlert {
    static func refuse() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Open Edith from Applications"
        alert.informativeText =
            "This copy of Edith is at \(Bundle.main.bundlePath). Only the copy in your "
            + "Applications folder runs Edith's background agent and menu bar. Move Edith to "
            + "Applications and open it from there."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }
}
