import AppKit
import SwiftUI

public enum ProviderLogo {
    private static let resources = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        .compactMap { $0?.appendingPathComponent("Edith_EdithKit.bundle") }
        .compactMap(Bundle.init(url:))
        .first

    public static func image(_ provider: LimitProvider) -> NSImage? {
        guard
            let url = resources?.url(forResource: provider.rawValue, withExtension: "svg"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        return image
    }

    public static func tintedImage(
        _ provider: LimitProvider, color: NSColor, size: NSSize = NSSize(width: 13, height: 13)
    ) -> NSImage? {
        guard let source = image(provider) else { return nil }
        let result = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
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
        .buttonStyle(.plain)
        .pointerCursor()
        .help(
            providers.count > 1
                ? "Choose provider, or Command-click to switch" : selection.label
        )
        .popover(isPresented: $showingProviders, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(providers) { provider in
                    Button {
                        selection = provider
                        showingProviders = false
                    } label: {
                        HStack(spacing: 8) {
                            ProviderLogoView(provider)
                                .frame(width: 14, height: 14)
                            Text(provider.label)
                            Spacer(minLength: 12)
                            if selection == provider {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(6)
            .frame(width: 132)
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
