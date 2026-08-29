import Foundation
import Testing

@testable import EdithKit

@Suite struct AutomationTests {
    @Test func triggersRoundTripWithAssociatedValues() throws {
        let triggers: [AutomationTrigger] = [
            .schedule(hour: 9, minute: 30, weekdays: [.monday, .friday]),
            .application(bundleIdentifier: "com.apple.Safari", event: .launched),
            .powerSource(.adapter),
            .battery(level: 25, direction: .fallsBelow),
            .display(.attached),
            .screen(.locked),
            .wake,
            .network(.reachable),
            .calendar(titleContains: "focus", phase: .starts),
        ]

        let data = try JSONEncoder().encode(triggers)
        #expect(try JSONDecoder().decode([AutomationTrigger].self, from: data) == triggers)
        #expect(Set(triggers.map(\.kind)) == Set(AutomationTriggerKind.allCases))
    }

    @Test func plannerResolvesCatalogOperationsAndPermissions() throws {
        let operation = try #require(UserOperationCatalog.descriptors.first)
        let scene = AutomationScene(
            name: "Focus",
            actions: [
                AutomationAction(
                    operationID: operation.id.rawValue, arguments: ["value"],
                    requiredPermissions: [.accessibility])
            ])

        let blocked = AutomationPlanner.plan(scene: scene)
        #expect(!blocked.isRunnable)
        #expect(blocked.steps.first?.command == operation.cli + ["value"])
        #expect(blocked.steps.first?.missingPermissions == [.accessibility])

        let ready = AutomationPlanner.plan(scene: scene, grantedPermissions: [.accessibility])
        #expect(ready.isRunnable)
        #expect(ready.steps.first?.effect == operation.effect)
    }

    @Test func executorOrdersStepsAndContinuesAfterFailure() async throws {
        let operations = Array(UserOperationCatalog.descriptors.prefix(3))
        let scene = AutomationScene(
            name: "Ordered",
            actions: operations.map { AutomationAction(operationID: $0.id.rawValue) },
            errorPolicy: .continueOnError)
        let recorder = CommandRecorder(failingCommand: operations[1].cli)
        let executor = AutomationExecutor(runner: { command in
            try await recorder.run(command)
        })

        let runID = try await executor.start(scene: scene, origin: .commandLine)
        let record = try #require(await executor.wait(for: runID))

        #expect(await recorder.commands == operations.map(\.cli))
        #expect(record.steps.map(\.state) == [.succeeded, .failed, .succeeded])
    }

    @Test func executorStopsAndPreventsRecursion() async throws {
        let operation = try #require(UserOperationCatalog.descriptors.first)
        let scene = AutomationScene(
            name: "Single", actions: [AutomationAction(operationID: operation.id.rawValue)])
        let gate = CommandGate()
        let executor = AutomationExecutor(runner: { command in
            await gate.run(command)
        })

        let runID = try await executor.start(scene: scene, origin: .trigger)
        await #expect(throws: AutomationExecutionError.alreadyRunning) {
            try await executor.start(scene: scene, origin: .trigger)
        }
        await gate.release()
        _ = await executor.wait(for: runID)
    }

    @Test func storageBoundsHistoryAndDryRunsImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AutomationStorage(root: root, historyLimit: 2, historyMaxAge: 600)
        let scene = AutomationScene(name: "Focus", actions: [])
        let document = AutomationDocument(scenes: [scene])
        try storage.save(document)
        #expect(try storage.load() == document)

        let export = root.appendingPathComponent("copy.json")
        try storage.export(to: export)
        let imported = try storage.importDocument(from: export, dryRun: true)
        #expect(imported == document)

        for index in 0..<3 {
            try storage.append(
                AutomationRunRecord(
                    id: UUID(), sceneID: scene.id, sceneName: scene.name, automationID: nil,
                    origin: .app, startedAt: Date().addingTimeInterval(Double(index)),
                    duration: 0, steps: []))
        }
        #expect(try storage.history().count == 2)
    }

}

private actor CommandRecorder {
    let failingCommand: [String]
    var commands: [[String]] = []

    init(failingCommand: [String]) {
        self.failingCommand = failingCommand
    }

    func run(_ command: [String]) throws -> String {
        commands.append(command)
        if command == failingCommand { throw TestFailure.failed }
        return command.joined(separator: " ")
    }
}

private actor CommandGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func run(_ command: [String]) async -> String {
        await withCheckedContinuation { continuation = $0 }
        return command.joined(separator: " ")
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum TestFailure: Error {
    case failed
}
