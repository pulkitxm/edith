import AppKit
import EdithIcons
import SwiftUI

public struct PageGuideAction: Equatable {
    public let id: String
    public let title: String
    public let perform: @MainActor () -> Void

    public init(id: String, title: String, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.perform = perform
    }

    public var helpText: String { "About " + title }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
    }

    var encoded: NSDictionary {
        let perform = self.perform
        let block: @convention(block) () -> Void = { MainActor.assumeIsolated { perform() } }
        return [
            PageGuideBridge.titleKey: title,
            PageGuideBridge.identityKey: id,
            PageGuideBridge.performKey: block as AnyObject,
        ]
    }

    init?(encoded: NSDictionary) {
        guard let title = encoded[PageGuideBridge.titleKey] as? String,
            let id = encoded[PageGuideBridge.identityKey] as? String,
            let object = encoded[PageGuideBridge.performKey] as AnyObject?
        else { return nil }
        typealias Block = @convention(block) () -> Void
        let block = unsafeBitCast(object, to: Block.self)
        self.init(id: id, title: title) { block() }
    }
}

private struct PageGuideKey: EnvironmentKey {
    static let defaultValue: PageGuideAction? = nil
}

extension EnvironmentValues {
    public var pageGuide: PageGuideAction? {
        get { self[PageGuideKey.self] }
        set { self[PageGuideKey.self] = newValue }
    }
}

struct PageGuidePlacedKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

public struct PageGuideButton: View {
    let guide: PageGuideAction
    @Environment(\.colorScheme) private var scheme

    public init(_ guide: PageGuideAction) {
        self.guide = guide
    }

    public var body: some View {
        PageToolbarButton(
            action: guide.perform, icon: .info, helperText: guide.helpText,
            tint: DashSkin.inkSoft(scheme == .dark)
        )
        .accessibilityIdentifier("introduction.reopen")
    }
}

public enum PageGuideBridge {
    static let titleKey = "title"
    static let identityKey = "identity"
    static let performKey = "perform"
    static let changed = Notification.Name("EdithPageGuideChanged")
    private static let key = unsafeBitCast(
        NSSelectorFromString("edithPageGuide"), to: UnsafeRawPointer.self)

    @MainActor public static func attach(_ guide: PageGuideAction?, to view: NSView) {
        let next = guide?.encoded ?? NSDictionary()
        let current = objc_getAssociatedObject(view, key) as? NSDictionary
        if let current, current[identityKey] as? String == next[identityKey] as? String,
            current[titleKey] as? String == next[titleKey] as? String
        {
            return
        }
        objc_setAssociatedObject(view, key, next, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        NotificationCenter.default.post(name: changed, object: view)
    }

    @MainActor static func guide(above view: NSView) -> PageGuideAction? {
        var candidate = view.superview
        while let current = candidate {
            if let value = objc_getAssociatedObject(current, key) as? NSDictionary {
                return PageGuideAction(encoded: value)
            }
            candidate = current.superview
        }
        return nil
    }
}

struct PageGuideProbe: NSViewRepresentable {
    let update: @MainActor (PageGuideAction?) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.update = update
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.update = update
    }

    final class ProbeView: NSView {
        var update: (@MainActor (PageGuideAction?) -> Void)?
        private var observer: NSObjectProtocol?
        private var published: PageGuideAction?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: PageGuideBridge.changed, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resolve() }
                }
            }
            resolve()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func resolve() {
            let next = window == nil ? nil : PageGuideBridge.guide(above: self)
            guard next != published else { return }
            published = next
            update?(next)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

struct PageGuideFallback: ViewModifier {
    @Environment(\.pageGuide) private var guide
    @Environment(\.compactLayout) private var compact
    @State private var placed = false

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let guide, !placed {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    PageGuideButton(guide)
                }
                .padding(.top, UIScale.pt(PageMetrics.guideRowTop))
                .padding(.trailing, PageMetrics.gutter(compact))
            }
            content
        }
        .onPreferenceChange(PageGuidePlacedKey.self) { placed = $0 }
    }
}

extension View {
    public func pageGuideFallback() -> some View {
        modifier(PageGuideFallback())
    }
}
