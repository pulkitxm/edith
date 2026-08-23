import AppKit
import EdithKit
import Testing

@Suite @MainActor struct ColorPickerOperationTests {
    @Test func descriptorIsRegisteredForTheCLILeaf() throws {
        let descriptors =
            ColorPickerOperation.allCases.map(\.descriptor)
            + ColorSwatchOperation.allCases.map(\.descriptor)

        #expect(descriptors.map(\.id.rawValue) == ["color.pick", "color.copy"])
        #expect(descriptors.map(\.cli) == [["color", "pick"], ["color", "copy"]])
        #expect(descriptors.map(\.effect) == [.interactive, .write])
        for descriptor in descriptors {
            #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
            #expect(UserOperationCatalog.descriptor(cli: descriptor.cli) == descriptor)
        }
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

    @Test func copyFormatsTheSwatchOnceAndWritesThatExactValue() throws {
        let swatch = ColorSwatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            red: 1, green: 0.5, blue: 0, profile: .sRGB)
        var written: String?

        let result = try ColorSwatchOperationExecution.perform(
            .copy, swatch: swatch, format: .rgb,
            write: {
                written = $0
                return true
            })

        #expect(written == "rgb(255, 128, 0)")
        #expect(result.operation == .copy)
        #expect(result.swatchID == swatch.id)
        #expect(result.format == .rgb)
        #expect(result.value == written)
    }

    @Test func copyReportsPasteboardRejection() {
        let swatch = ColorSwatch(red: 0, green: 0, blue: 0, profile: .sRGB)

        #expect(throws: ColorSwatchOperationError.pasteboardRejected) {
            try ColorSwatchOperationExecution.perform(
                .copy, swatch: swatch, format: .hex, write: { _ in false })
        }
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
