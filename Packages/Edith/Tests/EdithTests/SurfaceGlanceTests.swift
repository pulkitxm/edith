import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite struct SurfaceGlanceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func context(_ phases: [AgentActivityPhase] = []) -> SurfaceGlanceContext {
        let sessions = phases.enumerated().map { index, phase in
            AgentActivitySession(
                event: AgentActivityEvent(
                    provider: .claude,
                    sessionID: "demo-\(index)", eventName: "PostToolUse", phase: phase,
                    project: "/tmp/demo", receivedAt: now))
        }
        return SurfaceGlanceContext(
            agents: AgentActivityPresentation(
                activity: AgentActivitySnapshot(sessions: sessions, refreshedAt: now), now: now),
            observing: true, monitoringStalls: true, now: now)
    }

    @Test func automaticIndicatorsPrioritizeInputOverMusic() throws {
        var value = context([.working, .working, .waiting, .stuck])
        value.hasMusic = true
        #expect(value.resolve(.automatic, leading: true)?.source == .workingAgents)
        #expect(value.resolve(.automatic, leading: true)?.value == "2")
        #expect(value.resolve(.automatic, leading: false)?.source == .waitingAgents)
        #expect(value.resolve(.automatic, leading: false)?.value == "1")
        #expect(value.resolve(.automatic, leading: false)?.tab == .agents)
        value.agents.approvals = [
            AgentApprovalRequest(
                event: AgentActivityEvent(
                    provider: .claude, sessionID: "demo", eventName: "PermissionRequest",
                    phase: .permission, project: "/tmp/demo", receivedAt: now), now: now,
                lifetime: 118)
        ]
        #expect(value.resolve(.automatic, leading: false)?.source == .permissions)
        #expect(value.resolve(.automatic, leading: false)?.urgency == 1)
    }

    @Test func errorsAndQuietSessionsStayVisibleBesideOtherActivity() {
        var value = context([.working, .error])
        value.hasMusic = true
        #expect(value.resolve(.automatic, leading: false)?.source == .failedAgents)
        value = context([.working, .quiet])
        value.hasMusic = true
        #expect(value.resolve(.automatic, leading: false)?.source == .quietAgents)
    }

    @Test func disabledMonitoringIsDistinctFromZeroAndQuiet() {
        var value = context([.quiet])
        value.monitoringStalls = false
        #expect(value.resolve(.stuckAgents, leading: false)?.value == "Off")
        #expect(value.resolve(.quietAgents, leading: false)?.value == "1")
        #expect(value.resolve(.workingAgents, leading: false)?.value == "0")
        value.observing = false
        #expect(value.resolve(.workingAgents, leading: false)?.value == "Off")
    }

    @Test func idleIndicatorsDisappearUnlessExplicitlySelected() {
        var value = context()
        #expect(value.resolve(.automatic, leading: true) == nil)
        #expect(value.resolve(.none, leading: false) == nil)
        #expect(value.resolve(.clock, leading: true)?.value.isEmpty == false)
        value.files = 3
        #expect(value.resolve(.automatic, leading: true)?.value == "3")
        #expect(value.resolve(.automatic, leading: false)?.source == .clock)
        value.hasMusic = true
        #expect(value.resolve(.automatic, leading: true)?.source == .music)
    }

    @Test func countdownsAndQuotaRemainBounded() {
        var value = context()
        value.focus = AttentionFocusSession(
            name: "Demo", startedAt: now,
            plannedDuration: 90)
        #expect(value.resolve(.focus, leading: true)?.value == "1:30")
        value.now = now.addingTimeInterval(120)
        #expect(value.resolve(.focus, leading: true)?.value == "0:00")
        #expect(value.resolve(.focus, leading: true)?.urgency == 1)
        value.quotaRemaining = -20
        #expect(value.resolve(.limits, leading: true)?.value == "0%")
        value.quotaRemaining = 150
        #expect(value.resolve(.limits, leading: true)?.value == "100%")
    }

    @Test func indicatorsAndCameraCutoutUseTheSameGeometry() {
        let base = CGSize(width: 150, height: 28)
        let shape = NotchGeometry.collapsedSize(base: base, wingWidth: 76)
        #expect(shape == CGSize(width: 302, height: 28))
        let panel = NotchGeometry.panelSize(forShape: shape)
        let camera = NotchGeometry.hardwareNotchRect(in: panel, collapsedSize: base)
        #expect(camera.midX == panel.width / 2)
        #expect(camera.width == base.width)
        #expect(NotchGeometry.collapsedSize(base: base, wingWidth: 0) == base)
    }

    @Test func layoutsRetainIndependentIndicatorsAndPermissionBehavior() {
        var layout = SurfaceLayout.standard(.notch)
        layout.notchLeadingGlance = .focus
        layout.notchTrailingGlance = .permissions
        layout.notchWingWidth = 999
        layout.notchAgentSources = ["codex"]
        layout.notchIncludeSubagents = false
        layout.notchExpandPermissions = true
        layout.notchPrioritizePermissions = false
        let restored = SurfaceLayout.decode(layout.encoded, target: .notch)
        #expect(restored.notchLeadingGlance == .focus)
        #expect(restored.notchTrailingGlance == .permissions)
        #expect(restored.notchWingWidth == 140)
        #expect(restored.notchAgentSources == ["codex"])
        #expect(!restored.notchIncludeSubagents)
        #expect(restored.notchExpandPermissions)
        #expect(!restored.notchPrioritizePermissions)
    }
}
