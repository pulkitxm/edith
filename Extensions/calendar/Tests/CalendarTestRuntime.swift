import EdithExtensionSupport
import Foundation

@testable import CalendarExtension

@MainActor
enum CalendarTestRuntime {
    static func make(
        store: CalendarStore? = nil, presentation: CalendarPresentationState? = nil,
        uiEngine: CalendarUIEngine? = nil, fixture: CalendarFixtureBackend? = nil
    ) -> ExtensionServiceRuntime {
        ExtensionServiceRuntime(id: "calendar", role: "app", bundle: .main) {
            guard let store, let presentation, let uiEngine else {
                return CalendarService(runtime: $0)
            }
            return CalendarService(
                runtime: $0, store: store, presentation: presentation, uiEngine: uiEngine,
                fixture: fixture)
        }
    }
}
