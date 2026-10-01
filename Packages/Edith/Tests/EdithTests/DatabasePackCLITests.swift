import EdithDatabase
import Testing

@testable import Edith
@testable import EdithCLI

@Suite struct DatabasePackCLITests {
    @Test func statusAndRemoveSpeakJSONWithoutAPack() async {
        let status = await CLIProbe.run(["database", "pack", "status", "--json"])
        #expect(status.code == 0)
        #expect(status.object?["state"] as? String == "missing")
        #expect(status.object?["changed"] as? Bool == false)
        #expect(status.stdout.contains("error:") == false)

        let removed = await CLIProbe.run(["database", "pack", "remove", "--json"])
        #expect(removed.code == 0)
        #expect(removed.object?["state"] as? String == "missing")
        #expect(removed.object?["changed"] as? Bool == false)
    }

    @Test func installJSONReportsTheInjectedPack() async {
        let result = await CLIProbe.runInWorld(["database", "pack", "install", "--json"]) { _ in
            DatabaseCLIEnvironment.installPack = { _ in
                DatabasePackInspection(
                    state: .current,
                    installedVersion: "9.9.9",
                    expectedVersion: "9.9.9",
                    path: "/tmp/synthetic/edith-database")
            }
        }
        #expect(result.code == 0)
        #expect(result.object?["state"] as? String == "current")
        #expect(result.object?["installedVersion"] as? String == "9.9.9")
        #expect(result.object?["changed"] as? Bool == true)
        #expect(!result.stdout.contains("error:"))
    }
}

@MainActor
@Suite struct DatabasePackInstallModelTests {
    @Test func aRejectedSignatureBecomesTheVisibleFailure() async {
        let model = DatabasePackInstallModel { _ in
            throw DatabasePackInstallError.signatureRejected
        }
        await model.run()
        #expect(model.failure == "The database pack signature was rejected.")
        #expect(!model.finished)
    }

    @Test func aCurrentPackFinishesAtFullProgress() async {
        let model = DatabasePackInstallModel { _ in
            DatabasePackInspection(
                state: .current,
                installedVersion: "1.0.0",
                expectedVersion: "1.0.0",
                path: "/tmp/synthetic/edith-database")
        }
        await model.run()
        #expect(model.finished)
        #expect(model.failure == nil)
        #expect(model.fraction == 1)
    }
}
