import EdithExtensionCore
import AppKit
import SwiftUI

public enum PageMetrics {
    public static let gutter = 24.0
    public static let compactGutter = 16.0
    public static let top = 20.0
    public static let headerBottom = 16.0
    public static let headerSpacing = 16.0
    public static let subtitleSpacing = 4.0
    public static let pinnedContentTop = 20.0
    public static let bottom = 32.0
    public static let titleSize = 28.0
    public static let compactTitleSize = 24.0
    public static let sectionSpacing = 16.0
    public static let cardSpacing = 12.0
    public static let cardPadding = 16.0
    public static let cardCornerRadius = 14.0
    public static let controlSpacing = 8.0
    public static let controlHeight = 32.0
    static let guideSpacing = 4.0
    static let guideRowTop = 8.0
    public static let chipHeight = 26.0
    public static let chipCornerRadius = 8.0
    public static let filterRowSpacing = 12.0
    public static let filterLabelSpacing = 12.0
    public static let readableWidth = 980.0
    public static let metricTitleHeight = 16.0
    public static let metricValueHeight = 28.0
    public static let metricValueSize = 24.0
    public static let metricRowSpacing = 4.0
    public static let metricMinimumWidth = 148.0
    public static let formWidth = 704.0
    public static let groupedFormInset = 20.0
    public static let settingsSliderWidth = 180.0
    public static let settingsReadoutWidth = 56.0
    public static let settingsNumberWidth = 56.0

    public static var chipFont: Font { .edithText(.subheadline).weight(.medium) }
    public static var capsFont: Font { .edithText(.caption2).weight(.semibold) }

    public static func gutter(_ compact: Bool) -> CGFloat {
        UIScale.pt(compact ? compactGutter : gutter)
    }

    public static func titleFont(_ compact: Bool) -> Font {
        DashSkin.heading(compact ? compactTitleSize : titleSize)
    }

    public static let tableNameMinimumWidth = 140.0

    public static func fittedColumns(
        count: Int, width: Double, minimum: Double, spacing: Double, limit: Int? = nil
    ) -> Int {
        let ceiling = max(1, min(count, limit ?? count))
        let pitch = minimum + spacing
        guard width.isFinite, pitch > 0 else { return ceiling }
        let fitted = (width + spacing) / pitch
        guard fitted >= 1 else { return 1 }
        return fitted < Double(ceiling) ? Int(fitted) : ceiling
    }

    public static func cardColumns(
        _ compact: Bool, minimum: Double, maximum: Double = .infinity,
        spacing: Double? = nil, alignment: Alignment = .top
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

    public static func adaptiveColumns(
        minimum: Double, maximum: Double = .infinity, spacing: Double? = nil,
        alignment: Alignment = .top
    ) -> [GridItem] {
        cardColumns(
            false, minimum: minimum, maximum: maximum, spacing: spacing, alignment: alignment)
    }
}

public enum PageContentWidth {
    case fluid
    case readable

    func maximum(compact: Bool) -> CGFloat? {
        switch self {
        case .fluid: nil
        case .readable: compact ? nil : UIScale.pt(PageMetrics.readableWidth)
        }
    }
}

public struct PageScaffold<Header: View, Content: View>: View {
    var width: PageContentWidth = .fluid
    var pinnedHeader = false
    var scrollIdentity = ""
    var activity = ContentActivity.idle
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @Environment(\.compactLayout) private var compact
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollingHeaderHeight: CGFloat = 0

    public init(
        width: PageContentWidth = .fluid, pinnedHeader: Bool = false, scrollIdentity: String = "",
        activity: ContentActivity = .idle,
        @ViewBuilder header: @escaping () -> Header, @ViewBuilder content: @escaping () -> Content
    ) {
        self.width = width
        self.pinnedHeader = pinnedHeader
        self.scrollIdentity = scrollIdentity
        self.activity = activity
        self.header = header
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            if pinnedHeader {
                header().environment(\.pageColumnWidth, width.maximum(compact: compact))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !pinnedHeader {
                        header().environment(\.pageColumnWidth, width.maximum(compact: compact))
                            .onGeometryChange(for: CGFloat.self) {
                                $0.size.height
                            } action: {
                                scrollingHeaderHeight = $0
                            }
                    }
                    LazyVStack(
                        alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)
                    ) {
                        content()
                    }
                    .padding(.top, pinnedHeader ? UIScale.pt(PageMetrics.pinnedContentTop) : 0)
                    .pageContent(compact, width: width)
                }
                .background { PageScrollPosition(positions: .shared, key: scrollIdentity) }
            }
            .environment(\.pageViewportHeight, contentViewportHeight)
            .environment(\.pageViewportCenterShift, contentCenterShift)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { viewportHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in viewportHeight = height }
                }
            }
            .overlay(alignment: .top) {
                ContentActivityBadge(activity)
                    .padding(.top, UIScale.pt(8))
            }
        }
        .pageSurface()
    }

    private var contentViewportHeight: CGFloat {
        let top = pinnedHeader ? UIScale.pt(PageMetrics.pinnedContentTop) : scrollingHeaderHeight
        return max(0, viewportHeight - top - UIScale.pt(PageMetrics.bottom))
    }

    private var contentCenterShift: CGFloat {
        let top = pinnedHeader ? UIScale.pt(PageMetrics.pinnedContentTop) : 0
        return (UIScale.pt(PageMetrics.bottom) - top) / 2
    }
}

public struct PageWorkspace<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    public init(
        @ViewBuilder header: @escaping () -> Header, @ViewBuilder content: @escaping () -> Content
    ) {
        self.header = header
        self.content = content
    }

    public var body: some View {
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

private struct PageColumnWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct PageViewportHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct PageViewportCenterShiftKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    public var pageColumnWidth: CGFloat? {
        get { self[PageColumnWidthKey.self] }
        set { self[PageColumnWidthKey.self] = newValue }
    }

    var pageViewportHeight: CGFloat? {
        get { self[PageViewportHeightKey.self] }
        set { self[PageViewportHeightKey.self] = newValue }
    }

    var pageViewportCenterShift: CGFloat {
        get { self[PageViewportCenterShiftKey.self] }
        set { self[PageViewportCenterShiftKey.self] = newValue }
    }
}

private struct PageFillViewport: ViewModifier {
    @Environment(\.pageViewportHeight) private var viewportHeight
    @Environment(\.pageViewportCenterShift) private var centerShift

    func body(content: Content) -> some View {
        let viewport = viewportHeight
        let shift = centerShift
        content
            .alignmentGuide(VerticalAlignment.center) { dimensions in
                let room = max(0, ((viewport ?? 0) - dimensions.height) / 2)
                return dimensions[VerticalAlignment.center] - min(shift, room)
            }
            .frame(maxWidth: .infinity, minHeight: viewport, alignment: .center)
            .environment(\.pageViewportHeight, nil)
    }
}

extension View {
    public func pageFillViewport() -> some View {
        modifier(PageFillViewport())
    }

    public func pageSurface() -> some View {
        modifier(PageSurface())
    }

    public func pageTask<ID: Equatable>(
        id: ID, active: Bool = true, cancel: @escaping @MainActor () -> Void = {},
        operation: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(PageTask(id: id, active: active, cancel: cancel, operation: operation))
    }

    public func pageTask(
        active: Bool = true, cancel: @escaping @MainActor () -> Void = {},
        operation: @escaping @MainActor () async -> Void
    ) -> some View {
        pageTask(id: true, active: active, cancel: cancel, operation: operation)
    }

    public func pageRefresh(
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

    public func pageGutter(_ compact: Bool) -> some View {
        padding(.horizontal, PageMetrics.gutter(compact))
    }

    public func pageContent(_ compact: Bool, width: PageContentWidth = .fluid) -> some View {
        pageGutter(compact)
            .padding(.bottom, UIScale.pt(PageMetrics.bottom))
            .pageColumn(width.maximum(compact: compact))
    }

    public func pageColumn(_ width: CGFloat?) -> some View {
        frame(maxWidth: width, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

public struct PageSectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let icon: EdithIcon?
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.colorScheme) private var scheme

    public init(
        _ title: String, subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = nil
        self.trailing = trailing
    }

    public init(
        _ title: String, icon: EdithIcon, subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                heading.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: UIScale.pt(12))
                trailing().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                heading
                if Trailing.self != EmptyView.self {
                    ScrollView(.horizontal) {
                        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) { trailing() }
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: UIScale.pt(12)) {
            if let icon {
                PageGuideBadge(icon: icon, size: 24, tint: DashSkin.inkSoft(scheme == .dark))
                    .flushLeading()
            }
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title)
                    .font(.edithText(.headline))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.edithText(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

public struct PageSubtitle: View {
    private let text: Text

    public init(_ text: String) { self.text = Text(text) }
    public init(_ text: Text) { self.text = text }

    public var body: some View {
        text.font(.edithText(.body)).foregroundStyle(.secondary).lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct PageHeader<Title: View, Trailing: View, Accessory: View>: View {
    @Environment(\.compactLayout) private var compact
    @Environment(\.pageColumnWidth) private var columnWidth
    @Environment(\.colorScheme) private var scheme
    @Environment(\.pageGuide) private var guide

    private let title: () -> Title
    private let subtitle: String?
    private let divider: Bool
    private let trailing: () -> Trailing
    private let accessory: () -> Accessory

    public init(
        subtitle: String? = nil, divider: Bool = false,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.divider = divider
        self.trailing = trailing
        self.accessory = accessory
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.headerSpacing)) {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.subtitleSpacing)) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 0) {
                            heading.fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: UIScale.pt(12))
                            actions.fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                            heading
                            if Trailing.self != EmptyView.self || guide != nil {
                                ScrollView(.horizontal) {
                                    HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                                        actions
                                    }
                                }
                                .scrollIndicators(.never)
                            }
                        }
                    }
                    if let subtitle {
                        PageSubtitle(subtitle)
                            .frame(maxWidth: UIScale.pt(720), alignment: .leading)
                    }
                }
                accessory().environment(\.pageGuide, nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pageGutter(compact)
            .pageColumn(columnWidth)
            .padding(.top, UIScale.pt(PageMetrics.top))
            .padding(.bottom, UIScale.pt(PageMetrics.headerBottom))
            if divider { PageHeaderDivider() }
        }
        .preference(key: PageGuidePlacedKey.self, value: guide != nil)
    }

    @ViewBuilder private var actions: some View {
        if let guide {
            HStack(spacing: UIScale.pt(PageMetrics.guideSpacing)) {
                trailing()
                PageGuideButton(guide)
            }
            .buttonStyle(.edith(.secondary))
        } else {
            trailing()
                .buttonStyle(.edith(.secondary))
        }
    }

    private var heading: some View {
        title()
            .font(PageMetrics.titleFont(compact))
            .foregroundStyle(DashSkin.ink(scheme == .dark))
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .accessibilityAddTraits(.isHeader)
    }
}

extension PageHeader where Title == Text {
    public init(
        _ title: String, subtitle: String? = nil, divider: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.init(
            subtitle: subtitle, divider: divider, title: { Text(title) }, trailing: trailing,
            accessory: accessory)
    }
}

public struct PageHeaderDivider: View {
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(DashSkin.line(scheme == .dark))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

extension PageHeader where Title == Text, Accessory == EmptyView {
    public init(
        _ title: String, subtitle: String? = nil, divider: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            subtitle: subtitle, divider: divider, title: { Text(title) }, trailing: trailing,
            accessory: { EmptyView() })
    }
}

extension PageHeader where Accessory == EmptyView {
    public init(
        subtitle: String? = nil, divider: Bool = false,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            subtitle: subtitle, divider: divider, title: title, trailing: trailing,
            accessory: { EmptyView() })
    }
}
