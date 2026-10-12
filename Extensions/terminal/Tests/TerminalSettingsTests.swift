import Foundation
import Testing
@testable import TerminalExtension

@Suite struct TerminalSettingsTests {
    @Test func isolatedSettingsClampInvalidValuesAndPreserveExplicitShellChoices() throws {
        let suite = "com.pulkit.edith.tests.terminal-settings." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(100, forKey: TerminalSettingsKeys.fontSize)
        defaults.set(" /bin/sh ", forKey: TerminalSettingsKeys.shell)
        defaults.set(false, forKey: TerminalSettingsKeys.loginShell)
        defaults.set(false, forKey: TerminalSettingsKeys.confirmClose)
        let settings = TerminalSettings.load(defaults)
        #expect(settings.fontSize == 24 && settings.shell == "/bin/sh")
        #expect(!settings.loginShell && !settings.confirmClose)
        #expect(TerminalSettings.clampedFontSize(.nan) == 13)
        #expect(TerminalSettings.clampedFontSize(3) == 9)
    }

    @Test func launchClearsWorkerAndNestedSessionVariablesWithoutInheritingSecrets() {
        let plan = TerminalLaunchPlan.make(
            settings: .init(shell: "/bin/sh", loginShell: false, startupCommand: "true"),
            base: [
                "HOME": "/tmp/mock-home", "PATH": "/usr/bin:/bin", "EDITH_EXTENSION_ID": "terminal",
                "HERDR_PANE_ID": "mock", "SYNTHETIC_SECRET": "not-inherited",
            ], home: "/tmp/mock-home")
        #expect(
            plan.executable == "/bin/sh" && plan.arguments.isEmpty && plan.startupCommand == "true")
        #expect(plan.environment.contains("EDITH_EXTENSION_ID="))
        #expect(plan.environment.contains("HERDR_PANE_ID="))
        #expect(!plan.environment.contains(where: { $0.hasPrefix("SYNTHETIC_SECRET=") }))
        #expect(plan.environment.contains("TERM=xterm-256color"))
    }

    @Test func missingOrInvalidShellAndFolderUseTheProvidedFallbacks() {
        let settings = TerminalSettings(
            shell: "/missing/synthetic-shell", startFolder: .custom,
            customFolder: "/missing/synthetic-folder")
        #expect(settings.shellPath(loginShell: { URL(fileURLWithPath: "/bin/sh") }) == "/bin/sh")
        #expect(settings.workingDirectory(home: "/tmp/mock-home") == "/tmp/mock-home")
        #expect(TerminalSettings(shell: "/bin/sh").shellPath() == "/bin/sh")
    }
}
