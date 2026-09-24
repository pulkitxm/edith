import EdithKit
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

final class PresenterScriptedDecider: JevDeciding, @unchecked Sendable {
    private let lock = NSLock()
    private let probability: Double
    private var captured: [JevRequest] = []

    init(probability: Double) {
        self.probability = probability
    }

    var requests: [JevRequest] { lock.withLock { captured } }

    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        lock.withLock { captured.append(request) }
        return JevDecision(
            response: JevResponse(
                model: JevRequest.defaultModel,
                answers: ["presenting": JevAnswer(type: "noul", noul: probability)]),
            milliseconds: 10)
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

    static let silentJev = PresenterJevCheck(enabled: { false }, decider: { nil })
}

@MainActor
@Suite struct PresenterDetectorTests {
    private func detector(
        windows: PresenterBox<[PresenterWindowInfo]>, titles: Bool,
        apps: Set<String> = ["us.zoom.xos"], mirrored: PresenterBox<Bool> = PresenterBox(false)
    ) -> PresenterDetector {
        PresenterDetector(
            scanner: PresenterScanner(
                source: PresenterFixtures.source(windows, titles: titles),
                jev: PresenterFixtures.silentJev),
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

@Suite struct PresenterJevCheckTests {
    static let meetWindows = [
        PresenterWindowInfo(
            ownerName: "Google Chrome", title: "Meet - weekly sync", width: 1440, height: 900),
        PresenterWindowInfo(ownerName: "Xcode", title: "Edith", width: 1440, height: 900),
    ]

    private func check(
        _ decider: PresenterScriptedDecider?, enabled: Bool = true,
        clock: PresenterBox<Date> = PresenterBox(Date(timeIntervalSince1970: 1_000))
    ) -> PresenterJevCheck {
        PresenterJevCheck(
            enabled: { enabled }, decider: { decider }, now: { clock.value })
    }

    @Test func aConfidentAnswerNamesTheCallApp() async {
        let decider = PresenterScriptedDecider(probability: 0.8)
        let check = check(decider)
        #expect(check.reason(for: Self.meetWindows) == nil)
        await check.settle()
        #expect(check.reason(for: Self.meetWindows) == "Jev: screen sharing in Google Chrome")
        #expect(decider.requests.count == 1)
        let request = decider.requests[0]
        #expect(request.questions["presenting"] != nil)
        guard case .fields(let state) = request.state else {
            Issue.record("expected fields")
            return
        }
        #expect(state["windows"]?.contains("Google Chrome | Meet - weekly sync | 1440x900") == true)
    }

    @Test func aDoubtfulAnswerIsAMiss() async {
        let decider = PresenterScriptedDecider(probability: 0.79)
        let check = check(decider)
        _ = check.reason(for: Self.meetWindows)
        await check.settle()
        #expect(check.reason(for: Self.meetWindows) == nil)
        #expect(decider.requests.count == 1)
    }

    @Test func theSameWindowListIsAnsweredFromTheCache() async {
        let decider = PresenterScriptedDecider(probability: 0.95)
        let clock = PresenterBox(Date(timeIntervalSince1970: 1_000))
        let check = check(decider, clock: clock)
        _ = check.reason(for: Self.meetWindows)
        await check.settle()
        for _ in 0..<5 {
            clock.value += 60
            #expect(check.reason(for: Self.meetWindows) != nil)
            await check.settle()
        }
        #expect(decider.requests.count == 1)
    }

    @Test func aChangedWindowListWaitsForTheRateLimit() async {
        let decider = PresenterScriptedDecider(probability: 0.95)
        let clock = PresenterBox(Date(timeIntervalSince1970: 1_000))
        let check = check(decider, clock: clock)
        _ = check.reason(for: Self.meetWindows)
        await check.settle()
        var changed = Self.meetWindows
        changed.append(
            PresenterWindowInfo(ownerName: "Notes", title: "Agenda", width: 600, height: 500))
        clock.value += 10
        _ = check.reason(for: changed)
        await check.settle()
        #expect(decider.requests.count == 1)
        clock.value += PresenterJevCheck.interval
        _ = check.reason(for: changed)
        await check.settle()
        #expect(decider.requests.count == 2)
    }

    @Test func nothingIsAskedWithoutAKeyOrWithTheSettingOff() async {
        let decider = PresenterScriptedDecider(probability: 0.95)
        let noKey = PresenterJevCheck(
            enabled: { true },
            decider: { AgentJevDecider.configured(defaults: PresenterFixtures.defaults()) })
        let off = check(decider, enabled: false)
        let noCallApp = check(decider)
        #expect(noKey.reason(for: Self.meetWindows) == nil)
        #expect(off.reason(for: Self.meetWindows) == nil)
        #expect(noCallApp.reason(for: Array(Self.meetWindows.suffix(1))) == nil)
        await noKey.settle()
        await off.settle()
        await noCallApp.settle()
        #expect(decider.requests.isEmpty)
    }

    @Test func theScannerOnlyAsksWhenTitlesAreAvailableAndNoRuleMatched() async {
        let decider = PresenterScriptedDecider(probability: 0.95)
        let jev = check(decider)
        let windows = PresenterBox(Self.meetWindows)
        let untitled = PresenterScanner(
            source: PresenterFixtures.source(windows, titles: false), jev: jev)
        #expect(untitled.scan().windowReason == nil)
        windows.value = [PresenterFixtures.zoomToolbar] + Self.meetWindows
        let titled = PresenterScanner(
            source: PresenterFixtures.source(windows, titles: true), jev: jev)
        #expect(titled.scan().windowReason == "Zoom share detected")
        await jev.settle()
        #expect(decider.requests.isEmpty)
        windows.value = Self.meetWindows
        _ = titled.scan()
        await jev.settle()
        #expect(titled.scan().windowReason == "Jev: screen sharing in Google Chrome")
        #expect(decider.requests.count == 1)
    }

    @Test func theWindowSummaryIsBoundedAndRedacted() {
        let secret = "ghp" + String(repeating: "a1", count: 15)
        let windows =
            [
                PresenterWindowInfo(
                    ownerName: "Terminal",
                    title: "export TOKEN=\(secret) " + String(repeating: "x", count: 200),
                    width: 800, height: 600)
            ]
            + (0..<40).map {
                PresenterWindowInfo(ownerName: "App\($0)", title: "Window", width: 500, height: 400)
            }
            + [
                PresenterWindowInfo(
                    ownerName: "Window Server", title: "Menubar", width: 1440, height: 24)
            ]
        let lines = PresenterJevCheck.summary(of: windows).split(separator: "\n")
        #expect(lines.count == PresenterJevCheck.windowLimit)
        #expect(!lines[0].contains(secret))
        #expect(lines[0].contains(JevText.redaction))
        #expect(lines.allSatisfy { !$0.contains("Window Server") })
        let title = lines[0].split(separator: "|")[1].trimmingCharacters(in: .whitespaces)
        #expect(title.count <= PresenterJevCheck.titleLimit)
    }
}
