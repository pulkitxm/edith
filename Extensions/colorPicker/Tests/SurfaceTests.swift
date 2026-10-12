import EdithExtensionSupport
import Foundation
import Testing
@testable import ColorPickerExtension

struct ColorPickerExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let color = ColorSwatch(red: 1, green: 0, blue: 0, profile: .sRGB)
        let snapshot = ColorPickerSurface.snapshot(history: [color], error: nil)
        #expect(snapshot.metrics.first?.value == "1")
        #expect(snapshot.rows.first?.id == color.id.uuidString)
        #expect(snapshot.rows.first?.title.uppercased() == "#FF0000")
        #expect(snapshot.rows.first?.actions.first?.id == "copy:" + color.id.uuidString)
        #expect(snapshot.actions.first?.id == "pick")
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "colorPicker")
    }
}
