import EdithKit
import SwiftUI

enum PageMetrics {
    static let gutter = 24.0
    static let compactGutter = 18.0
    static let top = 18.0
    static let headerBottom = 16.0
    static let bottom = 28.0
    static let titleSize = 34.0
    static let compactTitleSize = 28.0
    static let sectionSpacing = 16.0
    static let cardSpacing = 12.0
    static let readableWidth = 980.0

    static func gutter(_ compact: Bool) -> CGFloat {
        UIScale.pt(compact ? compactGutter : gutter)
    }

    static func titleFont(_ compact: Bool) -> Font {
        DashSkin.serif(compact ? compactTitleSize : titleSize)
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
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(title)
                    .font(.system(size: UIScale.pt(15), weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: UIScale.pt(8))
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(12)) {
                title()
                    .font(PageMetrics.titleFont(compact))
                    .foregroundStyle(DashSkin.ink(scheme == .dark))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: UIScale.pt(8))
                trailing()
            }
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageGutter(compact)
        .padding(.top, UIScale.pt(PageMetrics.top))
        .padding(.bottom, UIScale.pt(PageMetrics.headerBottom))
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
