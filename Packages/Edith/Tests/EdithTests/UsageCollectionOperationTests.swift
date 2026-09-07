import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct UsageCollectionOperationTests {
    private func defaults() -> UserDefaults {
        let suite = "usage-collection-operation-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test func catalogCarriesAllSixExactUIInvocations() {
        let expected: [UsageCollectionOperation: (String, String, [String])] = [
            .limitsRefresh: (
                "Rate limit cards", "refresh the limits now",
                ["usage", "limits", "--refresh"]
            ),
            .refresh: ("Dashboard", "re-collect agent usage", ["usage", "refresh"]),
            .machineEnable: (
                "Dashboard machines menu", "count a machine's agent usage too",
                ["usage", "machines", "enable", "box"]
            ),
            .machineDisable: (
                "Dashboard machines menu", "stop counting a machine",
                ["usage", "machines", "disable", "box"]
            ),
            .machineCollect: (
                "Dashboard machines menu", "collect from the machines now",
                ["usage", "machines", "collect"]
            ),
            .machineForget: (
                "Dashboard machines menu", "drop what a machine already gave",
                ["usage", "machines", "forget", "box"]
            ),
        ]
        #expect(expected.count == UsageCollectionOperation.allCases.count)
        for operation in UsageCollectionOperation.allCases {
            let descriptor = operation.descriptor
            let action = UserInterfaceActionCatalog.actions.first {
                $0.operation.id == descriptor.id
            }
            let placement = expected[operation]
            #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
            #expect(UserOperationCatalog.descriptor(cli: descriptor.cli) == descriptor)
            #expect(action?.surface == placement?.0)
            #expect(action?.action == placement?.1)
            #expect(action?.cli == placement?.2)
        }
        #expect(UsageCollectionOperation.machineForget.descriptor.effect == .destructive)
        #expect(!UsageCollectionOperation.machineForget.descriptor.requiresPreview)
    }

    @Test func signalsMapToTheExactCrossProcessRequests() {
        var delivered: [Notification.Name] = []
        let limits = UsageCollectionOperationExecution.request(.limitsRefresh) {
            delivered.append($0)
        }
        let refresh = UsageCollectionOperationExecution.request(.refresh) {
            delivered.append($0)
        }
        #expect(limits == .limitsRefresh)
        #expect(refresh == .refresh)
        #expect(delivered == [IPC.Name.requestLimitsRefresh, IPC.Name.requestUsageRefresh])
    }

    @Test func refreshStartsOrAttachesThroughOneExecutionPath() async throws {
        let events: [UsageRefreshEvent] = [.finished(seconds: 2.5)]
        let started = try await UsageCollectionOperationExecution.refresh(
            follow: false, driver: .scripted(events: events))
        #expect(!started.followed)
        #expect(started.refresh.seconds == 2.5)

        var attachedAfterBusy = false
        let attached = try await UsageCollectionOperationExecution.refresh(
            follow: false, driver: .scripted(events: events, busy: true),
            onBusyAttach: { attachedAfterBusy = true })
        #expect(attached.followed)
        #expect(attachedAfterBusy)
    }

    @Test func followingWithoutAnActiveRefreshKeepsItsSpecificError() async {
        await #expect(throws: UsageCollectionOperationError.noRefreshRunning) {
            try await UsageCollectionOperationExecution.refresh(
                follow: true, driver: .scripted(events: []))
        }
    }

    @Test func machineMergePreservesBusyAsASuccessfulHandoff() async {
        let completed = await UsageCollectionOperationExecution.mergeMachineChanges(
            driver: .scripted(events: []))
        let busy = await UsageCollectionOperationExecution.mergeMachineChanges(
            driver: .scripted(events: [], busy: true))
        #expect(completed == .completed)
        #expect(busy == .alreadyRunning)
    }

    @Test func machineSelectionUsesTheTypedEnableAndDisableOperations() {
        let store = defaults()
        let id = UUID()
        #expect(
            UsageCollectionOperationExecution.setMachineCounted(
                true, machineID: id, store: store) == .machineEnable)
        #expect(MachineUsageSelection.includes(id, store))
        #expect(
            UsageCollectionOperationExecution.setMachineCounted(
                false, machineID: id, store: store) == .machineDisable)
        #expect(!MachineUsageSelection.includes(id, store))
    }

    @Test func collectionIncludesOnlyMachinesThatActuallySucceeded() async {
        let store = defaults()
        let first = Machine(id: UUID(), name: "first", host: "first")
        let second = Machine(id: UUID(), name: "second", host: "second")
        let summary = MachineUsageSummary(
            machineID: second.id, name: second.name, slug: "second", host: second.host,
            collectedAt: Date(), sources: ["cli"], days: 1, cost: 2, tokens: 3)
        var changed = false
        let result = await UsageCollectionOperationExecution.collectMachines(
            UsageMachineCollectionInput(
                targets: [first, second], registry: [first, second],
                dataDirectory: FileManager.default.temporaryDirectory,
                timeout: 1, verbose: false),
            includeSuccessfulMachines: true, store: store,
            afterChange: { changed = true },
            collect: { _, _ in MachineUsageRoundResult(collected: [summary]) })
        #expect(result.includedMachineIDs == [second.id])
        #expect(!MachineUsageSelection.includes(first.id, store))
        #expect(MachineUsageSelection.includes(second.id, store))
        #expect(changed)
    }

    @Test func forgetDropsStoredUsageAndAlwaysStopsCounting() throws {
        let store = defaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-forget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        MachineUsageSelection.include(id, store)
        try Data("{}".utf8).write(
            to: UsageCollector.machineFile(id: id, in: directory))
        var refreshed = false

        let dropped = UsageCollectionOperationExecution.forgetMachine(
            machineID: id, store: store, directory: directory,
            afterDrop: { refreshed = true })

        #expect(dropped)
        #expect(refreshed)
        #expect(!MachineUsageSelection.includes(id, store))
        #expect(
            !FileManager.default.fileExists(
                atPath: UsageCollector.machineFile(id: id, in: directory).path))
    }
}

@Suite struct UsageCollectionOperationCLITests {
    @Test func machineEnableAndDisableKeepPlainJSONAndSelectionContracts() async {
        await CLIProbe.inWorld { world in
            let machine = Machine(name: "Builder", host: "10.0.0.9")
            MachineRegistry.add(machine)

            let enabled = await CLIProbe.capture([
                "usage", "machines", "enable", "Builder", "--json",
            ])
            #expect(enabled.code == 0)
            #expect(enabled.object?["counted"] as? Bool == true)
            #expect(MachineUsageSelection.includes(machine.id, world.shared))

            let disabled = await CLIProbe.capture([
                "usage", "machines", "disable", "Builder",
            ])
            #expect(disabled.code == 0)
            #expect(
                disabled.stdoutLines == [
                    "Builder is no longer collected; run `forget` to drop its numbers"
                ])
            #expect(!MachineUsageSelection.includes(machine.id, world.shared))
        }
    }

    @Test func limitsRefreshUsesTheAgentAndUnavailableExitContract() async {
        await CLIProbe.inWorld { world in
            world.configureLimitsRefreshAgent()
            world.answers { name in name == IPC.Name.limitsUpdated ? [:] : nil }

            let result = await CLIProbe.capture(["usage", "limits", "--refresh", "--json"])

            #expect(world.postedNames() == [IPC.Name.limitsUpdated.rawValue])
            #expect(result.code == 0 || result.code == ExitCodes.unavailable)
            if result.code != 0 { #expect(result.stdout.isEmpty) }
        }
    }
}
