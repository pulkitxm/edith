import EdithExtensionSupport
import EdithHostCore
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHost

@Suite @MainActor struct HostOnboardingJourneyTests {
    @Test func journeyMovesForwardAndBackThroughEveryStep() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        #expect(model.stage == .welcome)
        model.back()
        #expect(model.stage == .welcome)
        model.start()
        #expect(model.stage == .workflows)
        model.choose(.desk)
        #expect(model.stage == .tools)
        #expect(model.selected == ["hinge", "keystrokeHighlight", "system"])
        model.continueFromTools()
        #expect(model.stage == .permissions)
        model.back()
        #expect(model.stage == .tools)
        model.back()
        #expect(model.stage == .workflows)
        model.back()
        #expect(model.stage == .welcome)
    }

    @Test func toolsWithoutPermissionsGoStraightToInstall() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        model.toggle("plain")
        #expect(model.permissionItems.isEmpty)
        model.continueFromTools()
        await fixture.settle(model)
        #expect(model.stage == .finished)
        #expect(fixture.installs == ["plain"])
    }

    @Test func skippingEachStepAdvancesWithoutLosingTheApp() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.skipStep()
        #expect(model.stage == .workflows)
        model.skipStep()
        #expect(model.stage == .tools && model.workflow == .custom)
        model.toggle("plain")
        model.skipStep()
        #expect(model.stage == .finished)
        #expect(model.selected.isEmpty)
        #expect(!model.incomplete)
        #expect(fixture.installs.isEmpty)
    }

    @Test func skippingPermissionsInstallsTheSelectionAndDefersTheAsks() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.desk)
        model.continueFromTools()
        #expect(model.stage == .permissions)
        model.skipStep()
        await fixture.settle(model)
        #expect(model.stage == .finished)
        #expect(Set(fixture.installs) == ["hinge", "keystrokeHighlight", "system"])
        #expect(fixture.relaunches == 0)
    }

    @Test func skipEverythingFromWelcomeLeavesACompletedSetup() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.skip()
        #expect(model.stage == .finished && model.selected.isEmpty)
        #expect(!model.incomplete)
        model.dismiss()
        #expect(!model.presented)
        model.present()
        #expect(model.stage == .welcome)
    }

    @Test func relaunchedAppResumesOnThePermissionsStepWithItsSelection() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let first = fixture.model()
        first.present()
        first.choose(.desk)
        first.continueFromTools()
        #expect(first.stage == .permissions)
        let second = fixture.model()
        second.present()
        #expect(second.stage == .permissions)
        #expect(second.selected == ["hinge", "keystrokeHighlight", "system"])
        #expect(second.workflow == .desk)
    }

    @Test func resumeFallsBackWhenNothingIsSelectedOrStageIsUnknown() {
        #expect(
            HostWorkflowOnboardingModel.resumed(.permissions, hasSelection: false) == .workflows)
        #expect(HostWorkflowOnboardingModel.resumed(.tools, hasSelection: false) == .workflows)
        #expect(
            HostWorkflowOnboardingModel.resumed(.permissions, hasSelection: true) == .permissions)
        #expect(HostWorkflowOnboardingModel.resumed(.installing, hasSelection: true) == .tools)
        #expect(HostWorkflowOnboardingModel.resumed(nil, hasSelection: true) == .tools)
        #expect(HostWorkflowOnboardingModel.resumed(nil, hasSelection: false) == .welcome)
    }

    @Test func dismissingClearsTheResumePoint() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.desk)
        model.continueFromTools()
        model.dismiss()
        #expect(fixture.defaults.string(forKey: HostWorkflowEnvironment.resumeStageKey) == nil)
        #expect(!fixture.defaults.bool(forKey: HostWorkflowOnboardingModel.reviewPendingKey))
    }

    @Test func permissionsAreOrderedSoRelaunchOnesComeTogetherAtTheEnd() {
        let entries = Fixture.entries.filter {
            ["hinge", "keystrokeHighlight", "system", "calendar", "usage"].contains($0.id)
        }
        let items = HostOnboardingPermissionPlan.items(selected: entries, granted: [:])
        #expect(
            items.map(\.permission)
                == [.calendar, .notifications, .accessibility, .inputMonitoring, .screenRecording])
        let relaunchStart = items.firstIndex { $0.needsRelaunch }!
        let tail = Array(items[relaunchStart...])
        #expect(tail.allSatisfy { $0.needsRelaunch })
        #expect(items[..<relaunchStart].allSatisfy { !$0.needsRelaunch })
        let required = items.filter(\.isRequired).map(\.permission)
        #expect(Set(required) == [.calendar, .screenRecording, .inputMonitoring])
        let input = items.first { $0.permission == .inputMonitoring }!
        #expect(input.requiredBy.map(\.id) == ["keystrokeHighlight"])
        #expect(input.optionalFor.map(\.id) == ["system"])
    }

    @Test func currentPermissionIsTheFirstUngrantedNonDeferredAsk() {
        let entries = Fixture.entries.filter {
            ["calendar", "usage", "notchShelf"].contains($0.id)
        }
        var items = HostOnboardingPermissionPlan.items(selected: entries, granted: [:])
        #expect(HostOnboardingPermissionPlan.current(items, deferred: []) == .calendar)
        #expect(
            HostOnboardingPermissionPlan.current(items, deferred: [.calendar]) == .notifications)
        items = HostOnboardingPermissionPlan.items(selected: entries, granted: [.calendar: true])
        #expect(HostOnboardingPermissionPlan.current(items, deferred: []) == .notifications)
        let all = HostOnboardingPermissionPlan.items(
            selected: entries, granted: [.calendar: true, .notifications: true, .camera: true])
        #expect(HostOnboardingPermissionPlan.current(all, deferred: []) == nil)
        #expect(all.first { $0.permission == .bluetooth }?.asksOnFirstUse == true)
        #expect(HostOnboardingPermissionPlan.blockingRequired(all).isEmpty)
    }

    @Test func relaunchPermissionsAreBatchedIntoOneRelaunchAndSurviveIt() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.desk)
        model.continueFromTools()
        await model.requestPermission(.screenRecording)
        _ = model.permissions.openSettings(.inputMonitoring)
        #expect(Set(model.relaunchBatch) == [.screenRecording, .inputMonitoring])
        model.relaunch()
        #expect(fixture.relaunches == 1)
        #expect(model.relaunchBatch.isEmpty)
        #expect(fixture.defaults.bool(forKey: HostWorkflowOnboardingModel.reviewPendingKey))
        let relaunched = fixture.model()
        relaunched.present()
        #expect(relaunched.stage == .permissions)
        fixture.system.granted = [.screenRecording: true, .inputMonitoring: true]
        await relaunched.permissions.refresh()
        #expect(relaunched.permissionItems.filter(\.isGranted).map(\.permission).count == 2)
        #expect(relaunched.relaunchBatch.isEmpty)
    }

    @Test func relaunchDoesNothingWithoutAPendingBatch() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.desk)
        model.continueFromTools()
        model.relaunch()
        #expect(fixture.relaunches == 0)
    }

    @Test func livePermissionsNeverAskForRelaunch() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        model.toggle("calendar")
        model.continueFromTools()
        await model.requestPermission(.calendar)
        #expect(model.relaunchBatch.isEmpty)
        #expect(fixture.system.requests == [.calendar])
        #expect(!HostPermission.calendar.needsRelaunch)
        #expect(HostPermission.screenRecording.needsRelaunch)
    }

    @Test func grantedRelaunchPermissionNeedsNoRelaunch() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.system.grantOnRequest = true
        let model = fixture.model()
        model.present()
        model.choose(.desk)
        model.continueFromTools()
        await model.requestPermission(.screenRecording)
        #expect(model.relaunchBatch.isEmpty)
        #expect(model.permissions.awaitingRelaunch.isEmpty)
        #expect(fixture.system.opened.isEmpty)
    }

    @Test func onlyScreenInputAndDiskPermissionsWaitForARelaunch() {
        #expect(
            Set(HostPermission.allCases.filter(\.needsRelaunch))
                == [.inputMonitoring, .screenRecording, .fullDisk])
        #expect(!HostPermission.accessibility.needsRelaunch)
    }

    @Test func accessibilityGrantedInSettingsIsDetectedLiveWithoutARelaunch() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        model.toggle("system")
        model.continueFromTools()
        await model.requestPermission(.accessibility)
        #expect(model.relaunchBatch.isEmpty)
        #expect(fixture.system.opened.count == 1)
        fixture.system.granted[.accessibility] = true
        await model.permissions.refresh()
        #expect(model.permissionItems.first { $0.permission == .accessibility }?.isGranted == true)
        #expect(model.relaunchBatch.isEmpty)
        #expect(fixture.relaunches == 0)
    }

    @Test func settingsOpenOnlyWhenARequestLeavesThePermissionOff() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        model.toggle("calendar")
        model.continueFromTools()
        fixture.system.grantOnRequest = true
        await model.requestPermission(.calendar)
        #expect(fixture.system.opened.isEmpty)
        fixture.system.grantOnRequest = false
        fixture.system.granted = [:]
        await model.requestPermission(.calendar)
        #expect(fixture.system.opened == [HostPermission.calendar.settingsURL])
    }

    @Test func requestsRunOneAtATime() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.system.requestDelay = .seconds(2)
        let model = fixture.model()
        model.present()
        model.choose(.desk)
        model.continueFromTools()
        async let first: Void = model.requestPermission(.screenRecording)
        while fixture.system.requests.isEmpty { await Task.yield() }
        await model.requestPermission(.inputMonitoring)
        await first
        #expect(fixture.system.requests == [.screenRecording])
    }

    @Test func watchingDetectsGrantsWithoutManualRefreshAndStopsWhenLeavingTheStep() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.desk)
        model.continueFromTools()
        let watcher = Task { await model.watchPermissions(interval: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.permissionItems.allSatisfy { !$0.isGranted })
        fixture.system.granted = [.accessibility: true]
        for _ in 0..<50
        where model.permissionItems.first(where: { $0.permission == .accessibility })?.isGranted
            != true
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.permissionItems.first { $0.permission == .accessibility }?.isGranted == true)
        model.back()
        await watcher.value
        #expect(model.stage == .tools)
    }

    @Test func onlyOptionalPermissionsCanBeDeferredToFirstUse() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.desk)
        model.continueFromTools()
        #expect(model.currentPermission == .accessibility)
        model.deferPermission(.inputMonitoring, true)
        #expect(model.deferredPermissions.isEmpty)
        model.deferPermission(.accessibility, true)
        #expect(model.deferredPermissions == [.accessibility])
        #expect(model.currentPermission == .inputMonitoring)
        model.deferPermission(.accessibility, false)
        #expect(model.deferredPermissions.isEmpty)
    }

    @Test func deferringTheOnlyOptionalAskLeavesNothingToAllow() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        model.toggle("usage")
        model.continueFromTools()
        #expect(model.currentPermission == .notifications)
        model.deferPermission(.notifications, true)
        #expect(model.currentPermission == nil)
    }

    @Test func groupsListTheChosenWorkflowFirstAndSelectWholeCategories() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.utilities)
        #expect(model.groups.first?.category == "utilities")
        model.setGroup("desk", selected: true)
        #expect(model.groupSelected("desk"))
        model.setGroup("desk", selected: false)
        #expect(!model.groupSelected("desk"))
        #expect(model.selected.contains("calendar"))
    }

    @Test func taglinesPreferTheExtensionGuide() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        let guided = HostExtension(
            id: "guided", title: "Guided", icon: .heart, category: "desk",
            guide: HostExtensionGuide(tagline: "Does a thing.", summary: "", steps: []))
        #expect(model.tagline(for: guided) == "Does a thing.")
    }

    @Test func finishingOpensTheToolPageInTheSidebar() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        model.toggle("plain")
        model.continueFromTools()
        await fixture.settle(model)
        #expect(model.stage == .finished)
        let entry = Fixture.entries.first { $0.id == "plain" }!
        let page = model.destinations(for: entry).first!
        model.open(page: page.id)
        #expect(!model.presented)
        #expect(
            fixture.defaults.string(forKey: AppStorageKeys.General.mainWindowSection) == "plainPage"
        )
    }

    @Test func relaunchCommandWaitsForTheOldProcessThenOpensTheBundle() {
        let arguments = HostApplicationRelaunch.arguments(
            pid: 4242, bundlePath: "/Applications/Edith.app")
        #expect(arguments.first == "-c")
        #expect(arguments.suffix(2) == ["4242", "/Applications/Edith.app"])
        #expect(arguments[1].contains("kill -0") && arguments[1].contains("/usr/bin/open"))
        var spawned: [(String, [String])] = []
        var terminated = 0
        HostApplicationRelaunch.perform(
            pid: 7, bundleURL: URL(fileURLWithPath: "/Applications/Edith.app"),
            spawn: {
                spawned.append(($0, $1)); return true
            }, terminate: { terminated += 1 })
        #expect(spawned.count == 1 && spawned[0].0 == "/bin/sh" && terminated == 1)
        HostApplicationRelaunch.perform(
            pid: 7, bundleURL: URL(fileURLWithPath: "/tmp/not-an-app"),
            spawn: {
                spawned.append(($0, $1)); return true
            }, terminate: { terminated += 1 })
        #expect(spawned.count == 1 && terminated == 1)
        HostApplicationRelaunch.perform(
            pid: 7, bundleURL: URL(fileURLWithPath: "/Applications/Edith.app"),
            spawn: { _, _ in false }, terminate: { terminated += 1 })
        #expect(terminated == 1)
    }

    @MainActor final class System {
        var granted: [HostPermission: Bool] = [:]
        var requests: [HostPermission] = []
        var grantOnRequest = false
        var requestDelay = Duration.zero
        var opened: [URL?] = []
    }

    @MainActor final class Fixture {
        static let entries: [HostExtension] = [
            HostExtension(id: "hinge", title: "Hinge", icon: .ring, category: "desk"),
            HostExtension(
                id: "keystrokeHighlight", title: "Keystrokes", icon: .ring,
                category: "desk"),
            HostExtension(id: "system", title: "System", icon: .ring, category: "desk"),
            HostExtension(
                id: "calendar", title: "Calendar", icon: .calendar, category: "utilities"),
            HostExtension(id: "usage", title: "Usage", icon: .chartBar, category: "agents"),
            HostExtension(
                id: "notchShelf", title: "Notch", icon: .ring, category: "labs"),
            HostExtension(
                id: "plain", title: "Plain", icon: .ring, category: "media",
                pages: [HostPage(id: "plainPage", title: "Plain", icon: .ring, order: 0)]
            ),
        ]
        let name = "com.pulkit.edith.tests.journey.\(UUID().uuidString)"
        let defaults: UserDefaults
        let system = System()
        var installed = Set<String>()
        var installs: [String] = []
        var relaunches = 0
        init() { defaults = UserDefaults(suiteName: name)! }
        func remove() { defaults.removePersistentDomain(forName: name) }

        func package(_ id: String) -> ExtensionPackage {
            ExtensionPackage(
                id: id, version: "1.0.0", hostABI: HostContract.compatibility,
                downloadURL: URL(string: "https://example.invalid/\(id).zip")!,
                sha256: String(repeating: "a", count: 64), downloadBytes: 100, installedBytes: 200)
        }

        func model() -> HostWorkflowOnboardingModel {
            let system = system
            let permissions = HostPermissions(
                environment: HostPermissionEnvironment(
                    read: { system.granted },
                    request: { permission in
                        system.requests.append(permission)
                        if system.requestDelay > .zero {
                            try? await Task.sleep(for: system.requestDelay)
                        }
                        if system.grantOnRequest { system.granted[permission] = true }
                    },
                    openSettings: {
                        system.opened.append($0); return true
                    }),
                defaults: defaults, recordPrompt: {}, relaunch: { self.relaunches += 1 })
            return HostWorkflowOnboardingModel(
                entries: Self.entries, defaults: defaults,
                environment: HostWorkflowEnvironment(
                    available: {
                        Dictionary(
                            uniqueKeysWithValues: Self.entries.map { ($0.id, self.package($0.id)) })
                    },
                    installed: { self.installed }, active: { self.installed }, refresh: {},
                    install: { id, _ in
                        self.installs.append(id)
                        self.installed.insert(id)
                    }, restore: { throw HostWorkflowFailure("none") }, changed: {}),
                permissions: permissions)
        }

        func settle(_ model: HostWorkflowOnboardingModel) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while model.busy || model.stage == .installing, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}
