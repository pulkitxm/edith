import AppKit
import SwiftUI
import Testing

@testable import EdithKit

@MainActor
@Suite(.serialized) struct EdithButtonInteractionTests {
    @Test func everyRenderedRoleAcceptsPointerEventsAcrossItsSurface() async throws {
        var harnesses: [EdithButtonHarness] = []
        for role in EdithButtonRole.allCases {
            let probe = EdithButtonProbe()
            let harness = EdithButtonHarness(
                rootView: EdithButtonInteractionFixture(role: role, probe: probe))
            harnesses.append(harness)

            let frames = try await harness.frames(probe, role: role)
            let points = EdithButtonTestPoints.inside(frames)
            for point in points {
                let before = probe.activations
                harness.click(point)
                #expect(probe.activations == before + 1)
            }

            for point in EdithButtonTestPoints.outside(frames.button) {
                harness.click(point)
            }

            #expect(probe.activations == points.count)
        }
        harnesses.reversed().forEach { $0.close() }
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func disabledRenderedButtonRejectsEveryPointerEvent() async throws {
        let probe = EdithButtonProbe()
        let harness = EdithButtonHarness(
            rootView: EdithButtonInteractionFixture(
                role: .primary, disabled: true, probe: probe))
        defer { harness.close() }

        let frames = try await harness.frames(probe, role: .primary)
        for point in EdithButtonTestPoints.inside(frames) {
            harness.click(point)
        }

        #expect(probe.activations == 0)
    }

    @Test func fullWidthRowAcceptsClicksAcrossItsWhitespace() async throws {
        let probe = EdithButtonProbe()
        let harness = EdithButtonHarness(
            rootView: EdithButtonInteractionFixture(role: .row, probe: probe))
        defer { harness.close() }

        let frames = try await harness.frames(probe, role: .row)
        #expect(frames.button.width > frames.text.maxX - frames.icon.minX + 80)
        harness.click(CGPoint(x: frames.button.maxX - 3, y: frames.button.midY))
        harness.click(CGPoint(x: frames.text.maxX + 30, y: frames.button.midY))

        #expect(probe.activations == 2)
    }

    @Test func delegatedFeatureStyleUsesTheCanonicalHitTarget() async throws {
        let probe = EdithButtonProbe()
        let harness = EdithButtonHarness(
            rootView: EdithButtonDelegationFixture(probe: probe))
        defer { harness.close() }

        let frames = try await harness.frames(probe, role: .toolbar)
        let points = EdithButtonTestPoints.inside(frames)
        for point in points {
            let before = probe.activations
            harness.click(point)
            #expect(probe.activations == before + 1)
        }
        for point in EdithButtonTestPoints.outside(frames.button) {
            harness.click(point)
        }

        #expect(probe.activations == points.count)
    }

    @Test func roleGalleryActivatesEveryVisibleBound() async throws {
        let probe = EdithButtonGalleryProbe()
        let harness = EdithButtonHarness(
            rootView: EdithButtonRoleGallery(probe: probe),
            size: CGSize(width: 520, height: 620))
        defer { harness.close() }

        let frames = try await harness.galleryFrames(probe)
        for role in EdithButtonRole.allCases {
            let frame = try #require(frames[role])
            let inset = frame.insetBy(dx: 1, dy: 1)
            let points = [
                CGPoint(x: frame.midX, y: frame.midY),
                CGPoint(x: inset.minX, y: inset.minY),
                CGPoint(x: inset.maxX, y: inset.maxY),
            ]
            for point in points {
                let before = probe.activations[role, default: 0]
                harness.click(point)
                #expect(probe.activations[role, default: 0] == before + 1)
            }
        }
    }

    @Test func spaceShortcutActivatesOnce() async throws {
        let probe = EdithButtonProbe()
        let harness = EdithButtonHarness(
            rootView: EdithButtonInteractionFixture(
                role: .secondary, spaceAction: true, probe: probe))
        defer { harness.close() }

        _ = try await harness.frames(probe, role: .secondary)
        try await Task.sleep(for: .milliseconds(50))
        harness.key(code: 49, characters: " ")

        #expect(probe.activations == 1)
    }

    @Test func defaultButtonActivatesOnceWithReturn() async throws {
        let probe = EdithButtonProbe()
        let harness = EdithButtonHarness(
            rootView: EdithButtonInteractionFixture(
                role: .primary, defaultAction: true, probe: probe))
        defer { harness.close() }

        _ = try await harness.frames(probe, role: .primary)
        try await Task.sleep(for: .milliseconds(50))
        harness.key(code: 36, characters: "\r")

        #expect(probe.activations == 1)
    }

    @Test func siblingOverlayDeliversEachPointerEventExactlyOnce() async throws {
        let probe = EdithButtonOverlayProbe()
        let harness = EdithButtonHarness(rootView: EdithButtonOverlayFixture(probe: probe))
        defer { harness.close() }

        let frames = try await probe.frames()
        harness.click(CGPoint(x: frames.primary.minX + 2, y: frames.primary.minY + 2))
        harness.click(CGPoint(x: frames.secondary.minX - 12, y: frames.primary.midY))
        #expect(probe.primaryActivations == 2)
        #expect(probe.secondaryActivations == 0)

        harness.click(CGPoint(x: frames.secondary.midX, y: frames.secondary.midY))
        #expect(probe.primaryActivations == 2)
        #expect(probe.secondaryActivations == 1)
    }

}

@MainActor
private final class EdithButtonProbe {
    var activations = 0
    var buttonFrame: CGRect?
}

@MainActor
private final class EdithButtonGalleryProbe {
    var activations: [EdithButtonRole: Int] = [:]
    var frames: [EdithButtonRole: CGRect] = [:]
}

@MainActor
private final class EdithButtonOverlayProbe {
    var primaryActivations = 0
    var secondaryActivations = 0
    var primaryFrame: CGRect?
    var secondaryFrame: CGRect?

    func frames() async throws -> (primary: CGRect, secondary: CGRect) {
        for _ in 0..<40 {
            if let primaryFrame, let secondaryFrame {
                return (primaryFrame, secondaryFrame)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EdithButtonHarnessError.missingFrames
    }
}

private struct EdithButtonFrames {
    let button: CGRect
    let icon: CGRect
    let text: CGRect
}

private struct EdithButtonInteractionFixture: View {
    let role: EdithButtonRole
    var disabled = false
    var defaultAction = false
    var spaceAction = false
    let probe: EdithButtonProbe

    var body: some View {
        Group {
            if defaultAction {
                button.keyboardShortcut(.defaultAction)
            } else if spaceAction {
                button.keyboardShortcut(.space, modifiers: [])
            } else {
                button
            }
        }
        .padding(40)
        .frame(width: 360, height: 180)
    }

    private var button: some View {
        Button {
            probe.activations += 1
        } label: {
            HStack(spacing: 18) {
                Image(systemName: "sparkles")
                    .frame(width: 18, height: 18)
                Text("Activate")
                    .frame(width: 62, alignment: .leading)
                if role == .row || role == .selection { Spacer(minLength: 0) }
            }
        }
        .buttonStyle(EdithButtonStyle(role))
        .background(EdithButtonFrameReader(probe: probe))
        .disabled(disabled)
        .accessibilityLabel("Activate fixture")
    }
}

private struct EdithButtonDelegationFixture: View {
    let probe: EdithButtonProbe

    var body: some View {
        Button {
            probe.activations += 1
        } label: {
            HStack(spacing: 18) {
                Image(systemName: "sparkles")
                    .frame(width: 18, height: 18)
                Text("Activate")
                    .frame(width: 62, alignment: .leading)
            }
        }
        .buttonStyle(EdithButtonDelegatingStyle())
        .background(EdithButtonFrameReader(probe: probe))
        .accessibilityLabel("Delegated fixture")
        .padding(40)
        .frame(width: 360, height: 180)
    }
}

private struct EdithButtonDelegatingStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.45 : 0.25))
            .edithButtonTarget(.toolbar)
    }
}

private struct EdithButtonOverlayFixture: View {
    let probe: EdithButtonOverlayProbe

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                probe.primaryActivations += 1
            } label: {
                HStack {
                    Text("Open row")
                    Spacer(minLength: 0)
                    Color.clear.frame(width: 28, height: 28)
                }
                .frame(width: 240)
                .padding(8)
                .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .background(EdithButtonOverlayFrameReader(kind: .primary, probe: probe))

            Button {
                probe.secondaryActivations += 1
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.edith(.toolbar))
            .background(EdithButtonOverlayFrameReader(kind: .secondary, probe: probe))
            .padding(.trailing, 8)
        }
        .padding(40)
        .frame(width: 360, height: 180)
    }
}

private struct EdithButtonRoleGallery: View {
    let probe: EdithButtonGalleryProbe
    @State private var counts: [EdithButtonRole: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(EdithButtonRole.allCases, id: \.self) { role in
                Button {
                    probe.activations[role, default: 0] += 1
                    counts[role, default: 0] += 1
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: role == .destructive ? "trash" : "sparkles")
                        Text(String(describing: role))
                        if role == .row || role == .selection { Spacer(minLength: 0) }
                        Text("\(counts[role, default: 0])")
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.edith(role, selected: role == .selection))
                .background(EdithButtonGalleryFrameReader(role: role, probe: probe))
                .overlay {
                    Rectangle()
                        .stroke(Color.pink.opacity(0.9), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("\(String(describing: role)) fixture")
            }
        }
        .padding(40)
        .frame(width: 520, height: 620, alignment: .topLeading)
    }
}

private struct EdithButtonGalleryFrameReader: NSViewRepresentable {
    let role: EdithButtonRole
    let probe: EdithButtonGalleryProbe

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            probe.frames[role] = view.convert(view.bounds, to: nil)
        }
    }
}

private struct EdithButtonFrameReader: NSViewRepresentable {
    let probe: EdithButtonProbe

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            probe.buttonFrame = view.convert(view.bounds, to: nil)
        }
    }
}

private enum EdithButtonOverlayFrameKind {
    case primary
    case secondary
}

private struct EdithButtonOverlayFrameReader: NSViewRepresentable {
    let kind: EdithButtonOverlayFrameKind
    let probe: EdithButtonOverlayProbe

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            let frame = view.convert(view.bounds, to: nil)
            switch kind {
            case .primary: probe.primaryFrame = frame
            case .secondary: probe.secondaryFrame = frame
            }
        }
    }
}

@MainActor
private final class EdithButtonHarness {
    private static var retained: [EdithButtonHarness] = []
    private let window: NSWindow

    init<Content: View>(rootView: Content, size: CGSize = CGSize(width: 360, height: 180)) {
        NSApplication.shared.activate()
        let host = NSHostingView(rootView: rootView)
        host.frame = CGRect(origin: .zero, size: size)
        window = EdithButtonWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.acceptsMouseMovedEvents = true
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
        host.layoutSubtreeIfNeeded()
    }

    func frames(_ probe: EdithButtonProbe, role: EdithButtonRole) async throws
        -> EdithButtonFrames
    {
        for _ in 0..<40 {
            if let button = probe.buttonFrame, button.width > 0, button.height > 0 {
                let metrics = EdithButtonMetrics.metrics(for: role)
                let labelWidth = 98.0
                let iconX =
                    role == .row || role == .selection
                    ? button.minX + metrics.horizontalPadding : button.midX - labelWidth / 2
                let icon = CGRect(x: iconX, y: button.midY - 9, width: 18, height: 18)
                let text = CGRect(x: icon.maxX + 18, y: button.midY - 9, width: 62, height: 18)
                return EdithButtonFrames(button: button, icon: icon, text: text)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EdithButtonHarnessError.missingFrames
    }

    func click(_ point: CGPoint) {
        mouse(.leftMouseDown, at: point)
        mouse(.leftMouseUp, at: point)
        settle()
    }

    func galleryFrames(_ probe: EdithButtonGalleryProbe) async throws
        -> [EdithButtonRole: CGRect]
    {
        for _ in 0..<40 {
            if probe.frames.count == EdithButtonRole.allCases.count {
                return probe.frames
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EdithButtonHarnessError.missingFrames
    }

    func key(code: UInt16, characters: String) {
        key(.keyDown, code: code, characters: characters)
        key(.keyUp, code: code, characters: characters)
        settle()
    }

    func close() {
        window.orderOut(nil)
        Self.retained.append(self)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0)
        window.sendEvent(event!)
    }

    private func key(_ type: NSEvent.EventType, code: UInt16, characters: String) {
        let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)
        window.sendEvent(event!)
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.012))
    }
}

private enum EdithButtonHarnessError: Error {
    case missingFrames
}

private final class EdithButtonWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private enum EdithButtonTestPoints {
    static func inside(_ frames: EdithButtonFrames) -> [CGPoint] {
        let frame = frames.button
        let inset = frame.insetBy(dx: 1, dy: 1)
        return [
            CGPoint(x: frame.midX, y: frame.midY),
            CGPoint(x: frames.icon.midX, y: frames.icon.midY),
            CGPoint(x: frames.text.midX, y: frames.text.midY),
            CGPoint(x: (frames.icon.maxX + frames.text.minX) / 2, y: frame.midY),
            CGPoint(x: inset.minX, y: inset.minY),
            CGPoint(x: inset.maxX, y: inset.minY),
            CGPoint(x: inset.minX, y: inset.maxY),
            CGPoint(x: inset.maxX, y: inset.maxY),
            CGPoint(x: frame.midX, y: inset.minY),
            CGPoint(x: frame.midX, y: inset.maxY),
            CGPoint(x: inset.minX, y: frame.midY),
            CGPoint(x: inset.maxX, y: frame.midY),
            CGPoint(x: inset.minX + 4, y: frame.midY),
        ]
    }

    static func outside(_ frame: CGRect) -> [CGPoint] {
        [
            CGPoint(x: frame.minX - 2, y: frame.midY),
            CGPoint(x: frame.maxX + 2, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.minY - 2),
            CGPoint(x: frame.midX, y: frame.maxY + 2),
        ]
    }
}
