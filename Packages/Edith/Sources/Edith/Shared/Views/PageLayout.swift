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

extension View {
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
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text(title)
                .font(.system(size: UIScale.pt(15), weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: UIScale.pt(11)))
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
                    .scrollIndicators(.hidden)
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
