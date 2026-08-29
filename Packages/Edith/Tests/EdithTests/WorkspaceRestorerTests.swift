import EdithKit
import Foundation
import Testing

@Suite("Workspace restorer")
struct WorkspaceRestorerTests {
    @Test("display identities survive resize and reordering")
    func displayIdentitySurvivesTopologyChanges() {
        let saved = [
            display(10, x: 0, width: 1_440, height: 900, order: 0),
            display(20, x: 1_440, width: 2_560, height: 1_440, order: 1),
        ]
        let current = [
            display(20, x: -2_560, width: 2_560, height: 1_440, order: 0),
            display(10, x: 0, width: 1_512, height: 982, order: 1),
        ]

        let mapping = WorkspaceRestorerGeometry.displayMapping(saved: saved, current: current)

        #expect(mapping == [10: 10, 20: 20])
    }

    @Test("missing displays map deterministically by geometry and position")
    func missingDisplaysRemapDeterministically() {
        let saved = [
            display(10, x: -1_920, width: 1_920, height: 1_080, order: 0),
            display(20, x: 0, width: 1_440, height: 900, order: 1),
            display(30, x: 1_440, width: 2_560, height: 1_440, order: 2),
        ]
        let current = [
            display(100, x: 0, width: 1_512, height: 982, order: 0),
            display(200, x: 1_512, width: 2_560, height: 1_440, order: 1),
        ]

        let first = WorkspaceRestorerGeometry.displayMapping(saved: saved, current: current)
        let second = WorkspaceRestorerGeometry.displayMapping(
            saved: saved.reversed(), current: current.reversed())

        #expect(first == second)
        #expect(first[10] == 100)
        #expect(first[20] == 100)
        #expect(first[30] == 200)
    }

    @Test("window frames scale and remain inside resized visible frames")
    func framesScaleAndClamp() {
        let source = CGRect(x: 0, y: 0, width: 2_000, height: 1_000)
        let destination = CGRect(x: -1_200, y: 40, width: 1_200, height: 800)
        let result = WorkspaceRestorerGeometry.remappedFrame(
            CGRect(x: 1_000, y: 500, width: 1_200, height: 700), from: source,
            to: destination)

        #expect(destination.contains(result))
        #expect(result.width == 720)
        #expect(result.height == 560)
    }

    @Test("exact titled windows receive exact confidence")
    func exactWindowMatching() {
        let profile = profile(
            windows: [window(title: "Quarterly plan", order: 0, displayID: 10)])
        let candidate = WorkspaceCandidateWindow(
            token: "501:8", bundleIdentifier: "com.example.Editor", title: "Quarterly plan",
            role: "AXWindow", subrole: "AXStandardWindow",
            frame: CGRect(x: 20, y: 20, width: 800, height: 600), displayID: 10, order: 0)

        let plan = WorkspaceRestorerPlanner.plan(
            profile: profile, candidates: [candidate], displays: profile.displays,
            launchPolicy: .never)

        #expect(plan.items.count == 1)
        #expect(plan.items[0].candidateToken == "501:8")
        #expect(plan.items[0].confidence == .exact)
        #expect(plan.items[0].disposition == .move)
    }

    @Test("each current window is matched at most once")
    func currentWindowsAreNotReused() {
        let profile = profile(windows: [
            window(title: "Notes", order: 0, displayID: 10),
            window(title: "Notes", order: 1, displayID: 10),
        ])
        let candidate = WorkspaceCandidateWindow(
            token: "501:8", bundleIdentifier: "com.example.Editor", title: "Notes",
            role: "AXWindow", subrole: "AXStandardWindow",
            frame: CGRect(x: 20, y: 20, width: 800, height: 600), displayID: 10, order: 0)

        let plan = WorkspaceRestorerPlanner.plan(
            profile: profile, candidates: [candidate], displays: profile.displays,
            launchPolicy: .never)

        #expect(plan.items.filter { $0.candidateToken != nil }.count == 1)
        #expect(plan.items.filter { $0.confidence == .missing }.count == 1)
    }

    @Test("missing applications follow launch policy")
    func launchMissingAppsPolicy() {
        let profile = profile(windows: [window(title: "Notes", order: 0, displayID: 10)])

        let never = WorkspaceRestorerPlanner.plan(
            profile: profile, candidates: [], displays: profile.displays, launchPolicy: .never)
        let missing = WorkspaceRestorerPlanner.plan(
            profile: profile, candidates: [], displays: profile.displays, launchPolicy: .missing)

        #expect(never.items[0].disposition == .skip)
        #expect(missing.items[0].disposition == .launch)
    }

    @Test("profiles rename duplicate and cap history")
    func libraryOperations() throws {
        let original = profile(name: "Desk", windows: [])
        var library = WorkspaceRestorerLibrary(profiles: [original])

        let renamed = try library.rename("Desk", to: "Writing")
        let duplicate = try library.duplicate("Writing", as: "Research")
        for index in 0..<30 {
            library.record(
                WorkspaceRestoreRun(
                    profileID: renamed.id, profileName: renamed.name,
                    startedAt: Date(timeIntervalSince1970: Double(index)), dryRun: false,
                    cancelled: false, items: []))
        }

        #expect(renamed.name == "Writing")
        #expect(duplicate.id != renamed.id)
        #expect(library.profiles.map(\.name) == ["Research", "Writing"])
        #expect(library.history.count == 25)
        #expect(library.history.first?.startedAt == Date(timeIntervalSince1970: 29))
    }

    private func display(
        _ id: UInt32, x: CGFloat, width: CGFloat, height: CGFloat, order: Int
    ) -> WorkspaceDisplaySnapshot {
        WorkspaceDisplaySnapshot(
            id: id, name: "Display \(id)", frame: CGRect(x: x, y: 0, width: width, height: height),
            visibleFrame: CGRect(x: x, y: 0, width: width, height: height), order: order)
    }

    private func window(
        title: String, order: Int, displayID: UInt32
    ) -> WorkspaceWindowSnapshot {
        WorkspaceWindowSnapshot(
            bundleIdentifier: "com.example.Editor", applicationName: "Editor",
            applicationURL: "/Applications/Editor.app", title: title, role: "AXWindow",
            subrole: "AXStandardWindow", frame: CGRect(x: 20, y: 20, width: 800, height: 600),
            minimized: false, fullScreen: false, displayID: displayID, order: order)
    }

    private func profile(
        name: String = "Desk", windows: [WorkspaceWindowSnapshot]
    ) -> WorkspaceProfile {
        WorkspaceProfile(
            name: name, displays: [display(10, x: 0, width: 1_440, height: 900, order: 0)],
            windows: windows, activeBundleIdentifier: "com.example.Editor")
    }
}
