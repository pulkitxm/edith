import AppKit
import Foundation

@MainActor
public final class ExtensionBundlePresentation {
    public let controller: NSViewController
    private let context: NSObject

    init(context: NSObject, controller: NSViewController) {
        self.context = context
        self.controller = controller
    }

    public func update(compact: Bool, visible: Bool, width: Double, intrinsic: Bool) throws {
        guard width.isFinite, (0...16_384).contains(width) else {
            throw MarketplaceError.invalidBundle
        }
        try Self.configure(
            context,
            input: [
                "compact": compact, "visible": visible, "width": width,
                "intrinsic": intrinsic,
            ])
    }

    static func configure(_ context: NSObject, input: NSDictionary) throws {
        let selector = NSSelectorFromString("configure:")
        guard context.responds(to: selector) else { throw MarketplaceError.invalidBundle }
        typealias Configure = @convention(c) (AnyObject, Selector, NSDictionary) -> Bool
        let configure = unsafeBitCast(context.method(for: selector), to: Configure.self)
        guard configure(context, selector, input) else { throw MarketplaceError.invalidBundle }
    }

    static func make(
        context: NSObject, input: NSDictionary,
        factory: @escaping @convention(block) () -> NSViewController?
    ) throws -> ExtensionBundlePresentation? {
        try configure(context, input: input)
        let selector = NSSelectorFromString("view:")
        guard context.responds(to: selector) else { throw MarketplaceError.invalidBundle }
        typealias View =
            @convention(c) (
                AnyObject, Selector, @convention(block) () -> NSViewController?
            ) -> NSViewController?
        let view = unsafeBitCast(context.method(for: selector), to: View.self)
        guard let controller = view(context, selector, factory) else { return nil }
        return ExtensionBundlePresentation(context: context, controller: controller)
    }
}
