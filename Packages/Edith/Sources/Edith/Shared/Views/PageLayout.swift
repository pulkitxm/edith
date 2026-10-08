import EdithKit
import SwiftUI

enum PageMetrics {
    static let gutter = 24.0
    static let compactGutter = 18.0
    static let top = 18.0
    static let headerBottom = 16.0
    static let bottom = 28.0
    static let titleSize = 28.0
    static let compactTitleSize = 24.0
    static let sectionSpacing = 16.0
    static let cardSpacing = 12.0
    static let readableWidth = 980.0

    static func gutter(_ compact: Bool) -> CGFloat {
        UIScale.pt(compact ? compactGutter : gutter)
    }

    static func titleFont(_ compact: Bool) -> Font {
        DashSkin.heading(compact ? compactTitleSize : titleSize)
    }

    static func cardColumns(
        _ compact: Bool, minimum: Double, maximum: Double = .infinity,
        spacing: Double? = nil, alignment: Alignment = .center
    ) -> [GridItem] {
        let maximum = UIScale.pt(maximum)
        return [
            GridItem(
                compact
                    ? .flexible(minimum: 0, maximum: maximum)
                    : .adaptive(minimum: UIScale.pt(minimum), maximum: maximum),
                spacing: spacing.map { CGFloat(UIScale.pt($0)) }, alignment: alignment)
        ]
    }
}

enum PageContentWidth {
    case fluid
    case readable

    func maximum(compact: Bool) -> CGFloat? {
        switch self {
        case .fluid: nil
        case .readable: compact ? nil : UIScale.pt(PageMetrics.readableWidth)
        }
    }
}

struct PageScaffold<Header: View, Content: View>: View {
    var width: PageContentWidth = .fluid
    var pinnedHeader = false
    var scrollIdentity = ""
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @Environment(\.compactLayout) private var compact
    @Environment(\.pageLocation) private var location
    @Environment(\.windowSessionOwner) private var sessions

    var body: some View {
        VStack(spacing: 0) {
            if pinnedHeader { header() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !pinnedHeader { header() }
                    LazyVStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing))
                    {
                        content()
                    }
                    .pageContent(compact, width: width)
                }
                .background {
                    if let location, let sessions {
                        PageScrollPosition(
                            positions: sessions.scrollPositions,
                            key: location + "/" + scrollIdentity)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .pageSurface()
    }
}

struct PageWorkspace<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header()
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageSurface()
    }
}

private struct PageSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.windowVisible) private var visible
    @Environment(\.loadingAnimationsEnabled) private var animationsEnabled

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DashSkin.paper(scheme == .dark))
            .environment(\.loadingAnimationsEnabled, visible && animationsEnabled)
    }
}

private struct PageTaskIdentity<ID: Equatable>: Equatable {
    let value: ID
    let visible: Bool
    let enabled: Bool
}

@MainActor
private final class PageTaskOwner {
    private var request: UUID?
    private var cancellation: (() -> Void)?

    func begin(cancel: @escaping () -> Void) -> UUID {
        stop()
        let request = UUID()
        self.request = request
        cancellation = cancel
        return request
    }

    func stop(_ request: UUID? = nil) {
        if let request, self.request != request { return }
        let cancellation = cancellation
        self.request = nil
        self.cancellation = nil
        cancellation?()
    }
}

private struct PageTask<ID: Equatable>: ViewModifier {
    let id: ID
    let active: Bool
    let cancel: @MainActor () -> Void
    let operation: @MainActor () async -> Void
    @Environment(\.windowVisible) private var visible
    @Environment(\.automaticViewActionsEnabled) private var enabled
    @State private var owner = PageTaskOwner()

    func body(content: Content) -> some View {
        content.task(id: PageTaskIdentity(value: id, visible: visible, enabled: enabled && active))
        {
            guard visible, enabled, active, !Task.isCancelled else { return }
            let request = owner.begin(cancel: cancel)
            defer { if Task.isCancelled { owner.stop(request) } }
            await operation()
        }
        .onDisappear { owner.stop() }
        .onChange(of: visible) { _, visible in
            if !visible { owner.stop() }
        }
        .onChange(of: enabled) { _, enabled in
            if !enabled { owner.stop() }
        }
        .onChange(of: active) { _, active in
            if !active { owner.stop() }
        }
    }
}

extension View {
    func pageSurface() -> some View {
        modifier(PageSurface())
    }

    func pageTask<ID: Equatable>(
        id: ID, active: Bool = true, cancel: @escaping @MainActor () -> Void = {},
        operation: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(PageTask(id: id, active: active, cancel: cancel, operation: operation))
    }

    func pageTask(
        active: Bool = true, cancel: @escaping @MainActor () -> Void = {},
        operation: @escaping @MainActor () async -> Void
    ) -> some View {
        pageTask(id: true, active: active, cancel: cancel, operation: operation)
    }

    func pageRefresh(
        active: Bool = true,
        interval: @escaping @MainActor () -> Duration,
        cancel: @escaping @MainActor () -> Void = {},
        operation: @escaping @MainActor () async -> Void
    ) -> some View {
        pageTask(active: active, cancel: cancel) {
            while !Task.isCancelled {
                await operation()
                guard !Task.isCancelled else { return }
                do {
                    try await Task.sleep(for: interval(), tolerance: .milliseconds(500))
                } catch {
                    return
                }
            }
        }
    }

    func pageGutter(_ compact: Bool) -> some View {
        padding(.horizontal, PageMetrics.gutter(compact))
    }

    func pageContent(_ compact: Bool, width: PageContentWidth = .fluid) -> some View {
        pageGutter(compact)
            .padding(.bottom, UIScale.pt(PageMetrics.bottom))
            .frame(maxWidth: width.maximum(compact: compact), alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct PageSectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: String, subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(12)) {
                heading.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: UIScale.pt(8))
                trailing().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                heading
                ScrollView(.horizontal) {
                    trailing()
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text(title)
                .font(.edithText(.headline))
            if let subtitle {
                Text(subtitle)
                    .font(.edithText(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PageHeader<Title: View, Trailing: View, Accessory: View>: View {
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    private let title: () -> Title
    private let trailing: () -> Trailing
    private let accessory: () -> Accessory

    init(
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.trailing = trailing
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(12)) {
                    heading.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: UIScale.pt(8))
                    trailing().fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    heading
                    ScrollView(.horizontal) {
                        trailing()
                    }
                    .scrollIndicators(.automatic)
                }
            }
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageGutter(compact)
        .padding(.top, UIScale.pt(PageMetrics.top))
        .padding(.bottom, UIScale.pt(PageMetrics.headerBottom))
    }

    private var heading: some View {
        title()
            .font(PageMetrics.titleFont(compact))
            .foregroundStyle(DashSkin.ink(scheme == .dark))
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }
}

extension PageHeader where Title == Text {
    init(
        _ title: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.init(title: { Text(title) }, trailing: trailing, accessory: accessory)
    }
}
