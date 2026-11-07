import EdithExtensionSupport
import EdithExtensionUI
import AppKit
import SwiftUI

@MainActor
public enum ProviderLogo {
    private static var sources: [String: NSImage?] = [:]
    private static var tinted: [TintKey: NSImage] = [:]

    private struct TintKey: Hashable {
        let name: String
        let color: NSColor
        let width: CGFloat
        let height: CGFloat
    }

    public static func image(_ provider: LimitProvider) -> NSImage? {
        image(named: provider.rawValue)
    }

    public static func image(named name: String) -> NSImage? {
        if let cached = sources[name] { return cached }
        let url = UsageResources.bundle.url(forResource: name, withExtension: "svg")
        let image = url.flatMap { NSImage(contentsOf: $0) }
        image?.isTemplate = true
        sources[name] = image
        return image
    }

    public static func tintedImage(
        _ provider: LimitProvider, color: NSColor, size: NSSize = NSSize(width: 13, height: 13)
    ) -> NSImage? {
        let key = TintKey(
            name: provider.rawValue, color: color, width: size.width, height: size.height)
        if let cached = tinted[key] { return cached }
        guard let source = image(provider) else { return nil }
        let result = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        if tinted.count > 64 { tinted.removeAll() }
        tinted[key] = result
        return result
    }
}

public struct ProviderLogoView: View {
    private let provider: LimitProvider

    public init(_ provider: LimitProvider) {
        self.provider = provider
    }

    public var body: some View {
        if let image = ProviderLogo.image(provider) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        }
    }
}

public struct ProviderSwitchButton: View {
    @Binding private var selection: LimitProvider
    private let providers: [LimitProvider]
    private let color: Color
    private let size: CGFloat
    @State private var showingProviders = false

    public init(
        selection: Binding<LimitProvider>, providers: [LimitProvider], color: Color,
        size: CGFloat = 15
    ) {
        _selection = selection
        self.providers = providers
        self.color = color
        self.size = size
    }

    public var body: some View {
        Button {
            guard providers.count > 1 else { return }
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                switchProvider()
            } else {
                showingProviders.toggle()
            }
        } label: {
            ProviderLogoView(selection)
                .frame(width: size, height: size)
                .foregroundStyle(color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .help(
            providers.count > 1
                ? "Choose provider, or Command-click to switch" : selection.label
        )
        .popover(isPresented: $showingProviders, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                ForEach(providers) { provider in
                    Button {
                        selection = provider
                        showingProviders = false
                    } label: {
                        HStack(spacing: UIScale.pt(8)) {
                            ProviderLogoView(provider)
                                .frame(width: UIScale.pt(14), height: UIScale.pt(14))
                            Text(provider.label)
                            Spacer(minLength: 12)
                            if selection == provider {
                                EdithIconView(.check)
                                    .font(.edithText(.caption).weight(.semibold))
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.edith(.row))
                }
            }
            .padding(UIScale.pt(6))
            .frame(width: UIScale.pt(132))
        }
    }

    private func switchProvider() {
        guard let index = providers.firstIndex(of: selection) else {
            selection = providers[0]
            return
        }
        selection = providers[(index + 1) % providers.count]
    }
}
