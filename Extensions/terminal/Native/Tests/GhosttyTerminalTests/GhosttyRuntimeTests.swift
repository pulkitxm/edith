import Testing

@testable import GhosttyTerminal

@Suite struct GhosttyRuntimeTests {
    @Test func initializationRemovesInheritedNoColor() {
        var unsetNames: [String] = []

        GhosttyRuntime.prepareProcessEnvironment { unsetNames.append($0) }

        #expect(unsetNames == ["NO_COLOR"])
    }

}
