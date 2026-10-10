import Foundation
import Testing
@testable import HostLifecycleHarness

@Suite struct UsageLauncherFixtureTests {
    @Test func currentSelectedApplicationIsRecapturedForEveryReplacementAndRestoration() throws {
        var captured: [URL] = []
        let identifier = "com.pulkit.edith.tests.worker-20000000-0000-0000-0000-000000000001"
        for path in [
            "/synthetic/original/Fixture.app/Contents/MacOS/Edith",
            "/synthetic/replacement/UpdatedFixture.app/Contents/MacOS/Edith",
            "/synthetic/replacement/UpdatedFixture.app/Contents/MacOS/Edith",
        ] {
            let executable = URL(fileURLWithPath: path)
            let value = try #require(
                UsageLauncherFixture.capture(
                    extensionID: "usage", executable: executable, hostIdentifier: identifier
                ) { application, actualIdentifier in
                    #expect(actualIdentifier == identifier)
                    captured.append(application)
                    return application
                })
            #expect(value.appendingPathComponent("Contents/MacOS/Edith") == executable)
        }
        #expect(captured.count == 3)
        #expect(captured[0] != captured[1])
        #expect(captured[1] == captured[2])
    }

    @Test func unrelatedOwnersNeverCaptureAndInvalidSelectedLauncherFailsClosed() {
        let executable = URL(fileURLWithPath: "/synthetic/Fixture.app/Contents/MacOS/Edith")
        let absent: String? = UsageLauncherFixture.capture(
            extensionID: "calendar", executable: executable, hostIdentifier: "unused"
        ) { _, _ in
            Issue.record("Only the Usage fixture admits the public launcher")
            return "unexpected"
        }
        #expect(absent == nil)
        enum Failure: Error { case rejected }
        #expect(throws: Failure.self) {
            try UsageLauncherFixture.capture(
                extensionID: "usage", executable: executable, hostIdentifier: "synthetic"
            ) { _, _ -> String in
                throw Failure.rejected
            }
        }
    }
}
