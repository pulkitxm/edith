import AppKit
import EdithExtensionTestSupport
import SwiftUI
import Testing

@testable import EdithExtensionUI

@MainActor
@Suite(.serialized)
struct ButtonHoverRenderingTests {
    enum Control: String, CaseIterable, CustomStringConvertible {
        case primary, secondary, borderless, toolbar, destructive, row, iconOnly, selection
        case link, menu, chip, pageToolbar

        var description: String { rawValue }

        var role: EdithButtonRole? {
            switch self {
            case .primary: .primary
            case .secondary: .secondary
            case .borderless: .borderless
            case .toolbar: .toolbar
            case .destructive: .destructive
            case .row: .row
            case .iconOnly: .iconOnly
            case .selection: .selection
            case .link, .menu, .chip, .pageToolbar: nil
            }
        }

        @MainActor @ViewBuilder var view: some View {
            if let role {
                switch role {
                case .toolbar, .iconOnly:
                    Button {
                    } label: {
                        EdithIconView(.search).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.edith(role))
                    .accessibilityLabel("Search")
                case .row, .selection:
                    Button("Synthetic row") {}.buttonStyle(.edith(role)).frame(width: 180)
                default:
                    Button("Synthetic") {}.buttonStyle(.edith(role))
                }
            } else {
                switch self {
                case .link:
                    Button("Synthetic link") {}.buttonStyle(.edithLink)
                case .menu:
                    Menu {
                        Button("Item") {}
                    } label: {
                        Text("Synthetic menu")
                    }
                    .borderlessMenu()
                    .fixedSize()
                case .chip:
                    PageChip("Synthetic chip") {}
                default:
                    PageToolbarButton(action: {}, icon: .link, helperText: "Synthetic")
                }
            }
        }
    }

    nonisolated static let schemes: [ColorScheme] = [.dark, .light]

    private func probe<V: View>(
        _ view: V, preview: EdithInteractionPreview?, scheme: ColorScheme, name: String
    ) async throws -> NSBitmapImageRep {
        try await RenderCapture.render(
            name,
            variant: .init(
                name: scheme == .dark ? "dark" : "light", width: 240, height: 64, zoom: 1,
                scheme: scheme)
        ) {
            view
                .environment(\.edithInteractionPreview, preview)
                .padding(16)
        }
        .bitmap
    }

    private func size<V: View>(_ view: V, preview: EdithInteractionPreview?) -> CGSize {
        NSHostingView(
            rootView: view.fixedSize()
                .environment(\.edithInteractionPreview, preview)
                .environment(\.automaticViewActionsEnabled, false)
        ).fittingSize
    }

    private func differingPixels(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else {
            return .max
        }
        var count = 0
        for x in 0..<lhs.pixelsWide {
            for y in 0..<lhs.pixelsHigh {
                guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let distance =
                    abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                if distance > 0.02 { count += 1 }
            }
        }
        return count
    }

    @Test(arguments: Control.allCases, schemes)
    func hoverChangesTheRenderWithoutMovingTheFrame(control: Control, scheme: ColorScheme)
        async throws
    {
        let name = "button-hover-\(control.rawValue)"
        let idle = try await probe(control.view, preview: nil, scheme: scheme, name: name)
        let hovered = try await probe(
            control.view, preview: .hovered, scheme: scheme, name: name + "-hovered")
        let pressed = try await probe(
            control.view, preview: .pressed, scheme: scheme, name: name + "-pressed")
        #expect(differingPixels(idle, hovered) > 40, "\(control) hover")
        #expect(differingPixels(hovered, pressed) > 40, "\(control) press")
        let resting = size(control.view, preview: nil)
        #expect(size(control.view, preview: .hovered) == resting, "\(control) hover frame")
        #expect(size(control.view, preview: .pressed) == resting, "\(control) press frame")
    }

    @Test(arguments: Control.allCases)
    func disabledControlsIgnoreHover(control: Control) async throws {
        let name = "button-hover-disabled-\(control.rawValue)"
        let view = control.view.disabled(true)
        let idle = try await probe(view, preview: nil, scheme: .dark, name: name)
        let hovered = try await probe(view, preview: .hovered, scheme: .dark, name: name)
        #expect(differingPixels(idle, hovered) == 0, "\(control)")
    }

    @Test func iconOnlyButtonsKeepASquareTargetWhenHovered() {
        let button = PageToolbarButton(action: {}, icon: .search, helperText: "Search")
        let resting = size(button, preview: nil)
        #expect(resting.width == resting.height)
        #expect(size(button, preview: .hovered) == resting)
    }

    @Test func interactionStateResolvesPreviewAndDisabled() {
        #expect(
            EdithInteractionState.resolve(
                hovering: false, pressed: false, enabled: true, preview: .hovered)
                == EdithInteractionState(hovered: true, pressed: false))
        #expect(
            EdithInteractionState.resolve(
                hovering: false, pressed: false, enabled: true, preview: .pressed)
                == EdithInteractionState(hovered: true, pressed: true))
        #expect(
            !EdithInteractionState.resolve(
                hovering: true, pressed: true, enabled: false, preview: .pressed
            ).active)
    }

    @Test func compactLabelsGetAnOutsetPlateAndLargeOnesDoNot() {
        let small = EdithInteractionMetrics.plateSize(for: CGSize(width: 9, height: 9), scale: 1)
        #expect(small == CGSize(width: 20, height: 20))
        let text = EdithInteractionMetrics.plateSize(for: CGSize(width: 40, height: 16), scale: 1)
        #expect(text == CGSize(width: 48, height: 20))
        let card = CGSize(width: 300, height: 120)
        #expect(EdithInteractionMetrics.plateSize(for: card, scale: 1) == card)
    }

    @Test(arguments: schemes)
    func iconToolbarCaptures(scheme: ColorScheme) async throws {
        let icons: [(EdithIcon, String)] = [
            (.link, "Connections"), (.send, "Message"), (.search, "Search"),
        ]
        let rendered = try await RenderCapture.render(
            "icon-toolbar-hover",
            variant: .init(
                name: scheme == .dark ? "dark" : "light", width: 420, height: 200, zoom: 1,
                scheme: scheme)
        ) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach([EdithInteractionPreview?.none, .hovered, .pressed], id: \.self) { state in
                    HStack(spacing: 2) {
                        ForEach(icons.indices, id: \.self) { index in
                            PageToolbarButton(
                                action: {}, icon: icons[index].0, helperText: icons[index].1
                            )
                            .environment(\.edithInteractionPreview, index == 1 ? state : nil)
                        }
                        Text(state.map { String(describing: $0) } ?? "idle")
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                            .padding(.leading, 12)
                    }
                }
            }
            .padding(24)
        }
        #expect(RenderCapture.distinctColors(rendered.bitmap) > 2)
    }
}
