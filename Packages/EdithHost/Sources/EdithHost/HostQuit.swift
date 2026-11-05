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
    var blockers: [String] {
        didSet {
            finished.append(contentsOf: oldValue.filter { !blockers.contains($0) })
            finished.removeAll { blockers.contains($0) }
        }
    }
    private(set) var finished: [String] = []
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
        let finish = blockers.count > 1 ? "they finish" : "it finishes"
        return "\(subject) \(verb) still working. Edith quits on its own as soon as \(finish)."
    }

    var status: String {
        blockers.count == 1 ? "Waiting for \(blockers[0])" : "Waiting for \(blockers.count) tools"
    }

    var progress: String? {
        let total = finished.count + blockers.count
        return total > 1 ? "\(finished.count) of \(total) done" : nil
    }
}

struct HostQuitWaitView: View {
    @Bindable var model: HostQuitWaitModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                PageGuideBadge(icon: .hourglass, size: 40)
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
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack(spacing: UIScale.pt(8)) {
                    Text(model.status)
                        .font(.edithText(.caption)).fontWeight(.medium)
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let progress = model.progress {
                        Text(progress)
                            .font(.edithText(.caption)).monospacedDigit()
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
                HostQuitFinishingBar()
                if model.progress != nil { rows(dark: dark) }
            }
            .padding(UIScale.pt(12))
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func rows(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            ForEach(model.finished, id: \.self) { row($0, done: true, dark: dark) }
            ForEach(model.blockers, id: \.self) { row($0, done: false, dark: dark) }
        }
    }

    private func row(_ title: String, done: Bool, dark: Bool) -> some View {
        HStack(spacing: UIScale.pt(6)) {
            EdithIconView(done ? .success : .scan)
                .font(.system(size: UIScale.pt(11), weight: .medium))
                .foregroundStyle(done ? DashSkin.sage : DashSkin.accent(dark))
                .accessibilityHidden(true)
            Text(title).font(.edithText(.caption))
                .foregroundStyle(done ? DashSkin.inkFaint(dark) : DashSkin.inkSoft(dark))
                .lineLimit(1)
        }
    }
}

struct HostQuitFinishingBar: View {
    static let period = 1.6
    static let sweep = 0.35
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func offset(at time: TimeInterval, width: CGFloat) -> CGFloat {
        let progress = time.truncatingRemainder(dividingBy: period) / period
        return CGFloat(progress) * (width * (1 + sweep)) - width * sweep
    }

    var body: some View {
        let dark = scheme == .dark
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            GeometryReader { proxy in
                let width = proxy.size.width
                Capsule().fill(DashSkin.line(dark))
                    .overlay(alignment: .leading) {
                        Capsule().fill(DashSkin.accent(dark))
                            .frame(width: reduceMotion ? width : width * Self.sweep)
                            .offset(
                                x: reduceMotion
                                    ? 0
                                    : Self.offset(
                                        at: context.date.timeIntervalSinceReferenceDate,
                                        width: width))
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(height: UIScale.pt(6))
        .accessibilityHidden(true)
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
