import AppKit
import SwiftUI
import Testing

@testable import EdithKit
@testable import Edith

@MainActor
@Suite(.serialized) struct SharedScreenInteractionTests {
    @Test(arguments: [280.0, 340.0], [1.0, 1.6])
    func longSegmentsRemainClickableInsideInspector(width: Double, zoom: Double) async throws {
        let previousZoom = UIScale.current
        UIScale.apply(zoom)
        defer { UIScale.apply(previousZoom) }
        let probe = SharedSelectionProbe()
        let options = ["Automatic", "Edith Camera", "OBS Virtual Camera"]
        let host = NSHostingView(
            rootView: EdithSegmentedPicker(
                "Sends to",
                selection: Binding(get: { probe.selection }, set: { probe.selection = $0 }),
                options: options, label: { $0 }
            )
            .padding(.horizontal, 16)
            .frame(width: width, height: 100))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))

        let controlWidth = width - 32
        for (index, option) in options.enumerated() {
            let point = NSPoint(x: 16 + controlWidth * (Double(index) + 0.5) / 3, y: 50)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(30))
            #expect(probe.selection == option)
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    @Test func loadingDoesNotConstructComputeHeavyContent() async throws {
        let probe = SharedLoadingProbe()
        let host = NSHostingView(rootView: loadingView(.loading, probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 220)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        #expect(probe.contentBuilds == 0)
        #expect(probe.placeholderBuilds > 0)

        host.rootView = loadingView(.content, probe: probe)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.contentBuilds > 0)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    @Test func compactHeadersKeepEveryActionVisible() throws {
        let host = try auditHost(
            PageHeader("Extension library") {
                HStack {
                    Button("Open library") {}
                    Button("Install extension") {}
                }
                .buttonStyle(.edith(.secondary))
            }
            .environment(\.compactLayout, true),
            size: CGSize(width: 320, height: 180))
        let text = try auditText(host)
        #expect(text.contains("Extension library"))
        #expect(text.contains("Open library"))
        #expect(text.contains("Install extension"))
    }

    @Test func pageWorkStopsOnceAndOnlyRestartsWhenVisibleAndEnabled() async throws {
        let probe = SharedPageWorkProbe()
        let host = NSHostingView(rootView: pageWork(probe, id: 1, visible: true, enabled: true))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.starts == 1)

        host.rootView = pageWork(probe, id: 1, visible: false, enabled: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.stops == 1)
        host.rootView = pageWork(probe, id: 2, visible: false, enabled: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.starts == 1)

        host.rootView = pageWork(probe, id: 2, visible: true, enabled: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.starts == 2)
        host.rootView = pageWork(probe, id: 2, visible: true, enabled: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.stops == 2)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    private func pageWork(
        _ probe: SharedPageWorkProbe, id: Int, visible: Bool, enabled: Bool
    ) -> some View {
        Text("Page work")
            .pageTask(id: id, cancel: { probe.stops += 1 }) {
                probe.starts += 1
                try? await Task.sleep(for: .seconds(30))
            }
            .environment(\.windowVisible, visible)
            .environment(\.automaticViewActionsEnabled, enabled)
    }

    private func loadingView(_ state: ContentLoadingState, probe: SharedLoadingProbe)
        -> some View
    {
        LoadingContainer(state: state) {
            probe.contentBuilds += 1
            return Text("Ready")
        } placeholder: {
            probe.placeholderBuilds += 1
            return SkeletonBlock(height: 80)
        }
    }
}

@MainActor
private final class SharedSelectionProbe {
    var selection = "Automatic"
}

@MainActor
private final class SharedLoadingProbe {
    var contentBuilds = 0
    var placeholderBuilds = 0
}

@MainActor
private final class SharedPageWorkProbe {
    var starts = 0
    var stops = 0
}
