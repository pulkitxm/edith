import EdithExtensionSupport
import Foundation

enum ColorPickerSurface {
    static func snapshot(history: [ColorSwatch], error: String?) -> SurfaceSnapshot {
        .init(
            providerID: "colorPicker",
            metrics: [.init("total", "Recent colors", history.count.description)],
            rows: history.prefix(100).map { color in
                .init(
                    color.id.uuidString, title: color.string(for: .hex),
                    detail: color.profile.displayName, icon: "eyedropper",
                    actions: [.init("copy:" + color.id.uuidString, "Copy", "doc.on.doc")])
            }, actions: [.init("pick", "Pick color", "eyedropper")],
            message: error.map { String($0.prefix(2048)) })
    }
}
