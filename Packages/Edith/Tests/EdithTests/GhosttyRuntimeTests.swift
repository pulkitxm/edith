import Testing

@testable import GhosttyTerminal

@Suite struct GhosttyRuntimeTests {
    @Test func initializationRemovesInheritedNoColor() {
        var unsetNames: [String] = []

        GhosttyRuntime.prepareProcessEnvironment { unsetNames.append($0) }

        #expect(unsetNames == ["NO_COLOR"])
    }

    @Test func childLaunchesRemoveExplicitNoColor() {
        let launch = GhosttyLaunch(
            executable: "/bin/zsh", arguments: [],
            environment: ["TERM=xterm-256color", "NO_COLOR=1", "COLORTERM=truecolor"])

        #expect(launch.environment == ["TERM=xterm-256color", "COLORTERM=truecolor"])
    }
}
