import EdithExtensionSupport
import SwiftUI

public enum PageSkeletonLayout: CaseIterable, Sendable {
    case analytics
    case list
    case cards
    case editor
}

public struct PageLoading<Content: View>: View {
    let state: ContentLoadingState
    var title = "No content yet"
    var message = "There is nothing to show yet."
    var layout: PageSkeletonLayout = .list
    var refreshing = false
    var retry: (() -> Void)?
    var cancel: (() -> Void)?
    @ViewBuilder let content: () -> Content

    public init(
        state: ContentLoadingState, title: String = "No content yet",
        message: String = "There is nothing to show yet.", layout: PageSkeletonLayout = .list,
        refreshing: Bool = false, retry: (() -> Void)? = nil, cancel: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.state = state
        self.title = title
        self.message = message
        self.layout = layout
        self.refreshing = refreshing
        self.retry = retry
        self.cancel = cancel
        self.content = content
    }

    public var body: some View {
        LoadingContainer(
            state: state, title: title, message: message, retry: retry, cancel: cancel,
            refreshing: refreshing
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                content()
            }
        } placeholder: {
            PageSkeleton(layout: layout)
        }
    }
}

public struct PageSkeleton: View {
    var layout: PageSkeletonLayout = .list
    @Environment(\.compactLayout) private var compact

    public init(layout: PageSkeletonLayout = .list) { self.layout = layout }

    public var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                PageSkeletonControls()
                switch layout {
                case .analytics:
                    LazyVGrid(
                        columns: PageMetrics.cardColumns(compact, minimum: 170, spacing: 12),
                        spacing: UIScale.pt(PageMetrics.cardSpacing)
                    ) {
                        ForEach(0..<4, id: \.self) { _ in
                            PageSkeletonCard {
                                SkeletonBlock(width: 80, height: 10)
                                SkeletonBlock(width: 96, height: 24)
                                SkeletonBlock(width: 120, height: 9)
                            }
                        }
                    }
                    PageSkeletonCard {
                        SkeletonBlock(width: 160, height: 15)
                        PageSkeletonChart()
                    }
                    PageSkeletonCard { PageSkeletonRows() }
                case .list:
                    PageSkeletonCard { PageSkeletonRows() }
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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading content")
    }
}

public struct PageSkeletonControls: View {
    public init() {}
    public var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            SkeletonBlock(width: 120, height: 28, corner: 7)
            SkeletonBlock(width: 88, height: 28, corner: 7)
            Spacer(minLength: 0)
            SkeletonBlock(width: 28, height: 28, corner: 7)
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
