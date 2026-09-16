import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIBifrostTests {
    private func seedIndex() {
        BifrostIndexStore.shared.save(
            BifrostIndex(
                generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                applications: [
                    BifrostApplication(
                        name: "Google Chrome", path: "/Applications/Google Chrome.app",
                        bundleID: "com.google.Chrome"),
                    BifrostApplication(name: "Safari", path: "/Applications/Safari.app"),
                ]))
    }

    @Test func openRequiresTheExtensionBeforeTheApp() async {
        await CLIProbe.inWorld { world in
            world.helperRunning(false)

            let result = await CLIProbe.capture(["bifrost", "open", "--json"])

            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("extensions enable bifrost"))
            #expect(world.postedNames().isEmpty)
        }
    }

    @Test func openRequiresTheRunningApp() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Bifrost.enabled)
            world.helperRunning(false)

            let result = await CLIProbe.capture(["bifrost", "open", "--json"])

            #expect(result.code == ExitCodes.unavailable)
            #expect(world.postedNames().isEmpty)
        }
    }

    @Test func openCarriesItsQueryToThePanel() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Bifrost.enabled)
            world.helperRunning(true)

            let result = await CLIProbe.capture(["bifrost", "open", "12 km in miles", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["operation"] as? String == "bifrost.open")
            #expect(result.object?["query"] as? String == "12 km in miles")
            #expect(world.postedNames() == [IPC.Name.requestBifrostPanel.rawValue])
            #expect(
                world.postedPayloads(for: IPC.Name.requestBifrostPanel)
                    .first?[BifrostPanelIPC.queryKey] as? String == "12 km in miles")
        }
    }

    @Test func openWithoutAQueryPostsNoPayload() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Bifrost.enabled)
            world.helperRunning(true)

            let result = await CLIProbe.capture(["bifrost", "open"])

            #expect(result.code == 0)
            #expect(result.stdout.contains("launcher requested"))
            #expect(
                world.postedPayloads(for: IPC.Name.requestBifrostPanel)
                    .first?[BifrostPanelIPC.queryKey] == nil)
        }
    }

    @Test func listReportsAnEmptyIndexAsNotFound() async {
        await CLIProbe.inWorld { _ in
            BifrostIndexStore.shared.remove()

            let result = await CLIProbe.capture(["bifrost", "ls", "--json"])

            #expect(result.code == ExitCodes.notFound)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("bifrost reindex"))
        }
    }

    @Test func listPrintsTheIndexedApplications() async {
        await CLIProbe.inWorld { _ in
            seedIndex()

            let result = await CLIProbe.capture(["bifrost", "ls", "--json"])
            let rows = result.array as? [[String: Any]] ?? []

            #expect(result.code == 0)
            #expect(rows.compactMap { $0["name"] as? String } == ["Google Chrome", "Safari"])
            #expect(rows.first?["bundleID"] as? String == "com.google.Chrome")
            #expect(rows.last?["bundleID"] is NSNull)
        }
    }

    @Test func listRanksAgainstASearchTheWayTheBarDoes() async {
        await CLIProbe.inWorld { _ in
            seedIndex()

            let result = await CLIProbe.capture(["bifrost", "ls", "--search", "chrome", "--json"])
            let rows = result.array as? [[String: Any]] ?? []

            #expect(result.code == 0)
            #expect(rows.compactMap { $0["name"] as? String } == ["Google Chrome"])
        }
    }

    @Test func listRefusesANegativeLimit() async {
        await CLIProbe.inWorld { _ in
            seedIndex()

            let result = await CLIProbe.capture(["bifrost", "ls", "--limit", "-1"])

            #expect(result.code == ExitCodes.usage)
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func calcPrintsTheUngroupedAnswer() async {
        await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture(["bifrost", "calc", "1000 * 1000", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["value"] as? Double == 1_000_000)
            #expect(result.object?["display"] as? String == "1,000,000")

            let plain = await CLIProbe.capture(["bifrost", "calc", "1000 * 1000"])
            #expect(plain.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1000000")
        }
    }

    @Test func calcRefusesWhatIsNotAnExpression() async {
        await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture(["bifrost", "calc", "safari", "--json"])

            #expect(result.code == ExitCodes.notFound)
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func convertNamesBothUnitsById() async {
        await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture(
                ["bifrost", "convert", "12 km in miles", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["from"] as? String == "kilometer")
            #expect(result.object?["to"] as? String == "mile")
            #expect(result.object?["dimension"] as? String == "length")
        }
    }

    @Test func convertRefusesCrossedDimensions() async {
        await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture(
                ["bifrost", "convert", "12 km in kilograms", "--json"])

            #expect(result.code == ExitCodes.notFound)
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func reindexAsksTheRunningApp() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Bifrost.enabled)
            world.helperRunning(true)

            let result = await CLIProbe.capture(["bifrost", "reindex", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["operation"] as? String == "bifrost.reindex")
            #expect(world.postedNames() == [IPC.Name.requestBifrostReindex.rawValue])
        }
    }

    @Test func clearEmptiesTheLedgerWithoutTheAppOrTheExtension() async {
        await CLIProbe.inWorld { world in
            var ledger = BifrostUsageLedger()
            ledger.record("app:/Applications/Safari.app", at: Date())
            ledger.save(to: world.shared, key: AppStorageKeys.Bifrost.usage)
            world.helperRunning(false)

            let result = await CLIProbe.capture(["bifrost", "clear", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["cleared"] as? Int == 1)
            #expect(
                BifrostUsageLedger.load(from: world.shared, key: AppStorageKeys.Bifrost.usage)
                    .entries.isEmpty)
            #expect(world.postedNames() == [IPC.Name.settingsChanged.rawValue])
        }
    }

    @Test func clearOnAnEmptyLedgerStillSucceeds() async {
        await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture(["bifrost", "clear", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["cleared"] as? Int == 0)
        }
    }
}
