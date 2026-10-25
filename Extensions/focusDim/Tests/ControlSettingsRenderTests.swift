import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import FocusDimExtension

@MainActor @Suite(.serialized) struct ControlSettingsRenderTests {
    @Test func originalRowsRenderAtCompactRegularZoomAndBothColorSchemes() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let defaults = SharedDefaults.store
        let oldZoom = defaults.object(forKey: WindowZoom.defaultsKey)
        let oldScale = UIScale.current
        defer {
            if let oldZoom {
                defaults.set(oldZoom, forKey: WindowZoom.defaultsKey)
            } else {
                defaults.removeObject(forKey: WindowZoom.defaultsKey)
            }
            UIScale.apply(oldScale)
        }
        let model = ControlPresentation(client: nil, defaults: defaults)
        defer { model.stop() }
        for width in [420.0, 900.0] {
            for zoom in [1.0, 1.5] {
                for scheme in [ColorScheme.light, .dark] {
                    defaults.set(zoom, forKey: WindowZoom.defaultsKey)
                    UIScale.apply(zoom)
                    let state = ExtensionPresentationState(
                        compact: width == 420,
                        visible: false, availableWidth: width, intrinsic: false)
                    let content = state.withContext {
                        ExtensionPageHost {
                            ControlSettingsHost(presentation: model) {
                                FocusDimSettings(presentation: model)
                            }
                        }
                    }
                    let hosting = NSHostingView(
                        rootView: content.environment(\.colorScheme, scheme))
                    hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    hosting.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    hosting.layoutSubtreeIfNeeded()
                    let bitmap = try #require(
                        hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide >= Int(width))
                    #expect(bitmap.pixelsHigh >= 900)
                    #expect(
                        hosting.fittingSize.width.isFinite && hosting.fittingSize.height.isFinite)
                    var colors: Set<UInt32> = []
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                                colors.insert(
                                    UInt32(color.redComponent * 255) << 16
                                        | UInt32(color.greenComponent * 255) << 8
                                        | UInt32(color.blueComponent * 255))
                            }
                        }
                    }
                    #expect(colors.count > 20)
                    #expect(!hosting.subviews.isEmpty)
                    #expect(!model.active)
                    #expect(model.error == nil)
                }
            }
        }
    }
}
