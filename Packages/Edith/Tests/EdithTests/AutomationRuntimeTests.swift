import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite struct AutomationRuntimeTests {
    @Test @MainActor func subscribesOnlyToEnabledTriggerKinds() {
        let scene = AutomationScene(name: "Focus", actions: [])
        let document = AutomationDocument(
            scenes: [scene],
            automations: [
                AutomationRule(name: "Wake", trigger: .wake, sceneID: scene.id),
                AutomationRule(
                    name: "Offline", trigger: .network(.unreachable), sceneID: scene.id),
                AutomationRule(
                    name: "Meeting", trigger: .calendar(titleContains: nil, phase: .starts),
                    sceneID: scene.id),
                AutomationRule(
                    name: "Disabled display", isEnabled: false, trigger: .display(.attached),
                    sceneID: scene.id),
            ])

        #expect(
            AutomationRuntime.requiredSubscriptions(for: document, calendarEnabled: false)
                == [.wake, .network])
        #expect(
            AutomationRuntime.requiredSubscriptions(for: document, calendarEnabled: true)
                == [.wake, .network, .calendar])
    }
}
