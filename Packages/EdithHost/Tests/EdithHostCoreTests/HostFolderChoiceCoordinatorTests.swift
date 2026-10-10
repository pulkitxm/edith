import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostFolderChoiceCoordinatorTests {
    private func fixture() throws -> (HostWorkerNavigationRequest, HostFolderChoiceOrigin) {
        let data = try JSONSerialization.data(withJSONObject: [
            "identifier": "com.example.synthetic.chooser",
            "supportDirectory": "file:///tmp/synthetic-chooser",
            "extensionID": "herdr", "version": "1", "theme": "accent", "appearance": "system",
            "zoom": 1, "recoveryOnly": false,
        ])
        let config = try JSONDecoder().decode(HostWorkerConfiguration.self, from: data)
        let presentation = UUID()
        return (
            .init(
                configuration: config, section: "agentActivity", presentationID: presentation,
                location: "settings", folderChoice: true),
            .init(
                extensionID: "herdr", version: "1", presentationID: presentation,
                enginePID: 42, engineGeneration: "engine", rendererPID: 43,
                rendererGeneration: "renderer", windowRegistration: UUID())
        )
    }

    @Test func syntheticChoiceRequiresIdenticalOwnerAfterSelection() async throws {
        let (request, original) = try fixture()
        var validations = 0
        let coordinator = HostFolderChoiceCoordinator(
            origin: { _ in
                validations += 1; return original
            }, select: { _ in .init(selectedPath: "/tmp/Synthetic Project") },
            cancelSelection: { _ in })
        #expect(try await coordinator.choose(request).selectedPath == "/tmp/Synthetic Project")
        #expect(validations >= 2)
        #expect(coordinator.pendingCount == 0)
    }

    @Test func changedRendererEngineVersionPresentationOrWindowRejectsSelection() async throws {
        let (request, original) = try fixture()
        let changed: [HostFolderChoiceOrigin] = [
            .init(
                extensionID: "herdr", version: "2", presentationID: original.presentationID,
                enginePID: 42, engineGeneration: "engine", rendererPID: 43,
                rendererGeneration: "renderer", windowRegistration: original.windowRegistration),
            .init(
                extensionID: "herdr", version: "1", presentationID: UUID(),
                enginePID: 42, engineGeneration: "engine", rendererPID: 43,
                rendererGeneration: "renderer", windowRegistration: original.windowRegistration),
            .init(
                extensionID: "herdr", version: "1", presentationID: original.presentationID,
                enginePID: 42, engineGeneration: "reused", rendererPID: 43,
                rendererGeneration: "renderer", windowRegistration: original.windowRegistration),
            .init(
                extensionID: "herdr", version: "1", presentationID: original.presentationID,
                enginePID: 42, engineGeneration: "engine", rendererPID: 44,
                rendererGeneration: "renderer", windowRegistration: original.windowRegistration),
            .init(
                extensionID: "herdr", version: "1", presentationID: original.presentationID,
                enginePID: 42, engineGeneration: "engine", rendererPID: 43,
                rendererGeneration: "renderer", windowRegistration: UUID()),
        ]
        for replacement in changed {
            var current = original
            let coordinator = HostFolderChoiceCoordinator(
                origin: { _ in current },
                select: { _ in
                    current = replacement; return .init(selectedPath: "/tmp/mock")
                }, cancelSelection: { _ in })
            await #expect(throws: HostWorkerError.rejected) {
                try await coordinator.choose(request)
            }
            #expect(coordinator.pendingCount == 0)
        }
    }

    @Test func hiddenOwnerCancelsOutstandingSyntheticSelectionAndDrains() async throws {
        let (request, original) = try fixture()
        var active = true
        var began = false
        var cancellations = 0
        let coordinator = HostFolderChoiceCoordinator(
            origin: { _ in
                guard active else { throw HostWorkerError.rejected }; return original
            },
            select: { _ in
                began = true
                try await Task.sleep(for: .seconds(10))
                return .init(selectedPath: "/tmp/mock")
            }, cancelSelection: { _ in cancellations += 1 })
        let task = Task { try await coordinator.choose(request) }
        while !began { await Task.yield() }
        active = false
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancellations == 1)
        #expect(coordinator.pendingCount == 0)
    }

    @Test func explicitCancellationAndStopDrainWithoutSelection() async throws {
        for stop in [false, true] {
            let (request, original) = try fixture()
            var began = false
            var cancellations = 0
            let coordinator = HostFolderChoiceCoordinator(
                origin: { _ in original },
                select: { _ in
                    began = true; try await Task.sleep(for: .seconds(10));
                    return .init(cancelled: true)
                }, cancelSelection: { _ in cancellations += 1 })
            let task = Task { try await coordinator.choose(request) }
            while !began { await Task.yield() }
            if stop { coordinator.stop() } else { task.cancel() }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(cancellations == 1)
            #expect(coordinator.pendingCount == 0)
        }
    }
}
