import Foundation
import Testing

@testable import EdithHelper

final class PresenterBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

enum PresenterFixtures {
    static let zoomToolbar = PresenterWindowInfo(
        ownerName: "zoom.us", title: "", width: 300, height: 50, layer: 3)

    static func source(
        _ windows: PresenterBox<[PresenterWindowInfo]>, titles: Bool
    ) -> PresenterWindowSource {
        PresenterWindowSource(
            windows: { windows.value }, titlesAvailable: { titles }, recording: { false })
    }

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "test.presenter.\(UUID().uuidString)")!
    }
}

@MainActor
@Suite struct PresenterDetectorTests {
    private func detector(
        windows: PresenterBox<[PresenterWindowInfo]>, titles: Bool,
        apps: Set<String> = ["us.zoom.xos"], mirrored: PresenterBox<Bool> = PresenterBox(false)
    ) -> PresenterDetector {
        PresenterDetector(
            scanner: PresenterScanner(source: PresenterFixtures.source(windows, titles: titles)),
            system: PresenterSystem(
                runningBundleIDs: { apps }, remoteSessionActive: { false },
                displayMirrored: { mirrored.value }, announce: {}),
            defaults: PresenterFixtures.defaults(), monitoring: false)
    }

    private func scan(_ detector: PresenterDetector) {
        detector.applyScan(detector.scanner.scan())
    }

    @Test func geometryRulesWorkWithoutScreenRecordingAccess() {
        let windows = PresenterBox([PresenterFixtures.zoomToolbar])
        let detector = detector(windows: windows, titles: false)
        scan(detector)
        #expect(detector.publishedActive)
        #expect(detector.publishedReason == "Zoom share detected")
    }

    @Test func sessionTicksBetweenScansDoNotCountAsMisses() {
        let windows = PresenterBox([PresenterFixtures.zoomToolbar])
        let detector = detector(windows: windows, titles: true)
        scan(detector)
        #expect(detector.publishedActive)
        windows.value = []
        scan(detector)
        #expect(detector.publishedActive)
        detector.tickSession()
        detector.tickSession()
        #expect(detector.publishedActive)
        #expect(detector.publishedReason == "Zoom share detected")
        scan(detector)
        #expect(!detector.publishedActive)
        #expect(detector.publishedReason == nil)
    }

    @Test func withoutWindowScansEachTickCountsOnce() {
        let mirrored = PresenterBox(true)
        let detector = detector(
            windows: PresenterBox([]), titles: true, apps: [], mirrored: mirrored)
        #expect(detector.publishedActive)
        #expect(detector.publishedReason == "Mirrored display detected")
        mirrored.value = false
        detector.tickSession()
        #expect(detector.publishedActive)
        detector.tickSession()
        #expect(!detector.publishedActive)
    }

    @Test func signalsOnlyCountMissesFromCompletedScans() {
        var signals = PresenterSignals(paused: false)
        signals.windowReason = "Zoom share detected"
        #expect(signals.evaluate(completedScan: true).active)
        signals.windowReason = nil
        #expect(signals.evaluate(completedScan: false).active)
        #expect(signals.evaluate(completedScan: false).active)
        #expect(signals.evaluate(completedScan: true).active)
        #expect(!signals.evaluate(completedScan: true).active)
    }
}
