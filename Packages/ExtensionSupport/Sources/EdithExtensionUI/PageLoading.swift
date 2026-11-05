import EdithExtensionCore
import SwiftUI

public enum PageSkeletonLayout: CaseIterable, Sendable {
    case analytics
    case list
    case cards
    case editor
    case form
    case fullList

    var rendersContentDirectly: Bool { self == .editor || self == .form }
}

public struct PageLoading<Content: View>: View {
    let state: ContentLoadingState
    var title: String?
    var errorTitle: String?
    var message = "There is nothing to show yet."
    var layout: PageSkeletonLayout = .list
    var showsSkeletonControls = true
    var refreshing = false
    var activity: ContentActivity?
    var retry: (() -> Void)?
    var cancel: (() -> Void)?
    @ViewBuilder let content: () -> Content

    public init(
        state: ContentLoadingState, title: String? = nil, errorTitle: String? = nil,
        message: String = "There is nothing to show yet.", layout: PageSkeletonLayout = .list,
        showsSkeletonControls: Bool = true, refreshing: Bool = false,
        activity: ContentActivity? = nil, retry: (() -> Void)? = nil,
        cancel: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content
    ) {
        self.state = state
        self.title = title
        self.errorTitle = errorTitle
        self.message = message
        self.layout = layout
        self.showsSkeletonControls = showsSkeletonControls
        self.refreshing = refreshing
        self.activity = activity
        self.retry = retry
        self.cancel = cancel
        self.content = content
    }

    public var body: some View {
        container
            .modifier(PageLoadingFill(active: !state.presentsContent && state != .loading))
    }

    var errorHeading: String { errorTitle ?? title ?? ContentStatusCopy.errorTitle }

    private var container: some View {
        LoadingContainer(
            state: state, title: title ?? "No content yet", errorTitle: errorHeading,
            message: message, retry: retry, cancel: cancel,
            refreshing: activity == nil && refreshing, updating: activity == .updating
        ) {
            if layout.rendersContentDirectly {
                content()
            } else {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                    content()
                }
            }
        } placeholder: {
            PageSkeleton(layout: layout, showsControls: showsSkeletonControls)
        }
    }
}

private struct PageLoadingFill: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.pageFillViewport()
        } else {
            content
        }
    }
}

public struct PageSkeleton: View {
    var layout: PageSkeletonLayout = .list
    var showsControls = true
    @Environment(\.compactLayout) private var compact
    @Environment(\.pageViewportHeight) private var viewportHeight

    public init(layout: PageSkeletonLayout = .list, showsControls: Bool = true) {
        self.layout = layout
        self.showsControls = showsControls
    }

    public var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                if showsControls, layout != .form { PageSkeletonControls() }
                switch layout {
                case .analytics:
                    PageMetricGrid {
                        ForEach(0..<4, id: \.self) { _ in PageMetricSkeleton() }
                    }
                    PageSkeletonCard {
                        SkeletonBlock(width: 160, height: 15)
                        PageSkeletonChart()
                    }
                    PageSkeletonCard { PageSkeletonRows() }
                case .list:
                    PageSkeletonCard { PageSkeletonRows() }
                case .fullList:
                    PageSkeletonCard { PageSkeletonRows(count: 40) }
                        .frame(height: viewportHeight)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .clipped()
                case .cards:
                    LazyVGrid(
                        columns: PageMetrics.cardColumns(compact, minimum: 260, spacing: 12),
                        spacing: UIScale.pt(PageMetrics.cardSpacing)
                    ) {
                        ForEach(0..<6, id: \.self) { _ in
                            PageSkeletonCard {
                                SkeletonBlock(width: 32, height: 32, corner: 8)
                                SkeletonBlock(width: 160, height: 14)
                                SkeletonBlock(height: 9)
                                SkeletonBlock(width: 120, height: 9)
                            }
                        }
                    }
                case .editor:
                    PageSkeletonCard {
                        SkeletonBlock(height: 280, corner: 12)
                        PageSkeletonControls()
                    }
                case .form:
                    ForEach([3, 2], id: \.self) { rows in
                        PageSkeletonCard { PageSkeletonFormRows(count: rows) }
                    }
                }
            }
            .frame(maxWidth: layout == .form ? PageMetrics.formWidth : nil)
        }
        .frame(maxWidth: .infinity, alignment: layout == .form ? .top : .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading content")
    }
}

public struct PageSkeletonControls: View {
    public init() {}
    public var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            SkeletonBlock(
                width: 120, height: PageMetrics.chipHeight, corner: PageMetrics.chipCornerRadius)
            SkeletonBlock(
                width: 88, height: PageMetrics.chipHeight, corner: PageMetrics.chipCornerRadius)
            Spacer(minLength: 0)
            SkeletonBlock(
                width: 32, height: PageMetrics.chipHeight, corner: PageMetrics.chipCornerRadius)
        }
    }
}

struct PageSkeletonCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    public var body: some View {
        PageCard(content: content)
    }
}

struct PageSkeletonRows: View {
    var count = 6

    public var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: UIScale.pt(10)) {
                    SkeletonBlock(width: 28, height: 28, corner: 7)
                    VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                        SkeletonBlock(width: index.isMultiple(of: 2) ? 160 : 120, height: 11)
                        SkeletonBlock(width: 90, height: 8)
                    }
                    Spacer(minLength: 0)
                    SkeletonBlock(width: 56, height: 11)
                }
            }
        }
    }
}

struct PageSkeletonFormRows: View {
    let count: Int

    var body: some View {
        VStack(spacing: UIScale.pt(16)) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: UIScale.pt(12)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        SkeletonBlock(width: index.isMultiple(of: 2) ? 140 : 180, height: 11)
                        SkeletonBlock(width: index.isMultiple(of: 2) ? 240 : 200, height: 8)
                    }
                    Spacer(minLength: 0)
                    SkeletonBlock(width: 44, height: 22, corner: 7)
                }
            }
        }
    }
}

struct PageSkeletonChart: View {
    public var body: some View {
        HStack(alignment: .bottom, spacing: UIScale.pt(6)) {
            ForEach(0..<12, id: \.self) { index in
                SkeletonBlock(height: Double(40 + index * 37 % 110), corner: 4)
            }
        }
        .frame(height: UIScale.pt(160), alignment: .bottom)
    }
}
