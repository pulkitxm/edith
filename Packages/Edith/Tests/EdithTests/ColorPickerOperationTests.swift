import AppKit
import EdithKit
import Testing

@Suite @MainActor struct ColorPickerOperationTests {
    @Test func descriptorIsRegisteredForTheCLILeaf() throws {
        let descriptor = ColorPickerOperation.pick.descriptor

        #expect(descriptor.id.rawValue == "color.pick")
        #expect(descriptor.cli == ["color", "pick"])
        #expect(descriptor.effect == .interactive)
        #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
        #expect(UserOperationCatalog.descriptor(cli: descriptor.cli) == descriptor)
    }

    @Test func requestUsesTheTypedNotification() {
        var posted: Notification.Name?

        let descriptor = ColorPickerOperationExecution.request(.pick) { posted = $0 }

        #expect(posted == IPC.Name.requestColorPick)
        #expect(descriptor == ColorPickerOperation.pick.descriptor)
    }

    @Test func performLaunchesTheSamplerAndForwardsItsSelection() {
        let sampled = NSColor(
            calibratedRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        var launched = false
        let selected = SelectedColorBox()

        ColorPickerOperationExecution.perform(
            .pick,
            show: { completion in
                launched = true
                completion(sampled)
            },
            selection: { selected.set($0) })

        #expect(launched)
        #expect(selected.value == sampled)
    }
}

private final class SelectedColorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NSColor?

    var value: NSColor? {
        lock.withLock { stored }
    }

    func set(_ color: NSColor?) {
        lock.withLock { stored = color }
    }
}
