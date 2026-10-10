import EdithExtensionSupport
import Foundation
import Testing

@testable import CalendarExtension

@MainActor @Suite struct CalendarLifecycleTests {
    @Test func stopAndWaitJoinsReplacedAndCurrentReadsWithoutPublishingLateCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CalendarLifecycleReadGate()
        let store = CalendarStore(
            snapshotStore: .init(file: root.appendingPathComponent("agenda.json")),
            fetch: { _ in await gate.read() })
        store.refresh()
        await gate.entered(1)
        store.refresh()
        await gate.entered(2)
        var drained = false
        let drain = Task {
            await store.stopAndWait()
            drained = true
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(!drained)
        await gate.releaseFirst()
        for _ in 0..<5 { await Task.yield() }
        #expect(!drained)
        await gate.releaseFirst()
        await drain.value
        #expect(drained && store.events.isEmpty && store.groupedDays.isEmpty)
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("agenda.json").path)
        )
    }

    @Test func runtimeDisableRejectsIngressAndWaitsForItsOwnedPermissionTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CalendarStore(
            snapshotStore: .init(file: root.appendingPathComponent("agenda.json")),
            fetch: { _ in [] })
        let presentation = CalendarPresentationState(channel: nil)
        let gate = CalendarLifecycleReadGate()
        let engine = CalendarUIEngine(
            store: store, presentation: presentation, authorized: { false },
            grant: { _ = await gate.read() })
        let runtime = ExtensionRuntime(store: store, presentation: presentation, uiEngine: engine)
        var commandCompleted = false
        runtime.invoke(
            [
                "token": UUID().uuidString, "command": "calendar.ui.action",
                "payload": Data("{\"action\":\"permission\"}".utf8),
            ]
        ) { data, message in
            commandCompleted = true
            #expect(data == nil && message != nil)
        }
        await gate.entered(1)
        var drained = false
        runtime.prepareToStop { drained = true }
        #expect(commandCompleted)
        runtime.invoke(
            [
                "token": UUID().uuidString, "command": "calendar.cli.catalog",
                "payload": Data("{}".utf8),
            ]
        ) { data, message in #expect(data == nil && message != nil) }
        for _ in 0..<5 { await Task.yield() }
        #expect(!drained)
        await gate.releaseFirst()
        while !drained { await Task.yield() }
        #expect(!engine.snapshot().authorized && store.events.isEmpty)
    }
}

private actor CalendarLifecycleReadGate {
    private var reads: [CheckedContinuation<[CalendarEventPayload], Never>] = []
    private var count = 0

    func read() async -> [CalendarEventPayload] {
        await withCheckedContinuation {
            count += 1
            reads.append($0)
        }
    }

    func entered(_ expected: Int) async {
        while count < expected { await Task.yield() }
    }

    func releaseFirst() {
        guard !reads.isEmpty else { return }
        let start = Date()
        reads.removeFirst().resume(returning: [
            CalendarEventPayload(
                id: "late", title: "Synthetic late event", start: start,
                end: start.addingTimeInterval(600), isAllDay: false)
        ])
    }
}
