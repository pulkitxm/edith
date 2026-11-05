import EdithExtensionUI
import EdithStudio
import Testing

@testable import StudioExtension

struct StudioIconNamesTests {
    @Test func everyEngineIconNameResolves() {
        let names =
            StudioCatalog.tools.map(\.iconName) + StudioKind.allCases.map(\.iconName)
            + StudioQuickAction.allCases.map(\.iconName)
            + ImageAdjustments.Key.allCases.map(\.iconName)
        #expect(names.filter { !EdithIcon.isValid(name: $0) } == [])
    }
}
