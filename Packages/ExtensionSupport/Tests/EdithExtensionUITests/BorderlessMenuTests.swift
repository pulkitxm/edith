import AppKit
import EdithExtensionTestSupport
import SwiftUI
import Testing
@testable import EdithExtensionUI

@MainActor
@Suite(.serialized, .exclusiveScale)
struct BorderlessMenuTests {
    private let tint = Color(red: 1, green: 0, blue: 0)

    private func ink<V: View>(_ view: V, scheme: ColorScheme) async throws -> NSColor {
        let rendered = try await RenderCapture.render(
            "borderless-menu",
            variant: .init(name: "probe", width: 80, height: 40, zoom: 1, scheme: scheme)
        ) {
            view.padding(8)
        }
        let bitmap = rendered.bitmap
        let background = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        var strongest = background
        var distance = 0.0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let difference =
                    abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if difference > distance {
                    distance = difference
                    strongest = color
                }
            }
        }
        return strongest
    }

    private func menu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            Button("Item") {}
        } label: {
            label()
        }
        .borderlessMenu()
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func width<V: View>(_ view: V) -> CGSize {
        NSHostingView(
            rootView: view.fixedSize().environment(\.automaticViewActionsEnabled, false)
        ).fittingSize
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func iconTakesTheAccent(scheme: ColorScheme) async throws {
        let color = try await ink(menu { EdithIcon.more.image() }.tint(tint), scheme: scheme)
        #expect(color.redComponent > 0.8)
        #expect(color.greenComponent < 0.4)
        #expect(color.blueComponent < 0.4)
    }

    @Test func secondaryIconIsNeutralAndNotBlackInDarkMode() async throws {
        let color = try await ink(
            menu { EdithIcon.more.image().foregroundStyle(.secondary) }.tint(tint), scheme: .dark)
        #expect(color.redComponent > 0.3)
        #expect(abs(color.redComponent - color.greenComponent) < 0.1)
        #expect(abs(color.redComponent - color.blueComponent) < 0.1)
    }

    @Test func nativeStyleStillDrawsTheIconBlackInDarkMode() async throws {
        let color = try await ink(
            Menu {
                Button("Item") {}
            } label: {
                EdithIcon.more.image()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(),
            scheme: .dark)
        #expect(color.redComponent < 0.1)
        #expect(color.greenComponent < 0.1)
        #expect(color.blueComponent < 0.1)
    }

    @Test func iconFollowsForegroundStyle() async throws {
        let color = try await ink(
            menu { EdithIcon.more.image().foregroundStyle(Color(red: 0, green: 0, blue: 1)) }
                .tint(tint),
            scheme: .dark)
        #expect(color.blueComponent > 0.8)
        #expect(color.redComponent < 0.4)
    }

    @Test func disabledDimsTheIcon() async throws {
        let color = try await ink(
            menu { EdithIcon.more.image().foregroundStyle(Color.white) }.disabled(true),
            scheme: .dark)
        #expect(color.redComponent < 0.75)
        #expect(color.redComponent > 0.3)
    }

    @Test func sizeMatchesTheNativeMenu() {
        let icon = EdithIcon.more.image()
        let plain = Menu {
            Button("Item") {}
        } label: {
            icon
        }
        let text = Menu {
            Button("Item") {}
        } label: {
            Text("Quick tools")
        }
        #expect(
            width(plain.borderlessMenu().menuIndicator(.hidden))
                == width(plain.menuStyle(.borderlessButton).menuIndicator(.hidden)))
        #expect(width(plain.borderlessMenu()) == width(plain.menuStyle(.borderlessButton)))
        #expect(
            width(text.borderlessMenu().menuIndicator(.hidden))
                == width(text.menuStyle(.borderlessButton).menuIndicator(.hidden)))
        #expect(width(text.borderlessMenu()) == width(text.menuStyle(.borderlessButton)))
    }
}
