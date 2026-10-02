import EdithKit
import SwiftUI

struct DatabaseSafetyCard<Content: View>: View {
    let title: String
    let symbol: String
    let dark: Bool
    var stroke: Color?
    @ViewBuilder let content: () -> Content
    @Environment(\.databaseAppTheme) private var appTheme

    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: appTheme)
    }

    init(
        title: String,
        symbol: String,
        dark: Bool,
        stroke: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.dark = dark
        self.stroke = stroke
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Label(title, systemImage: symbol)
                .font(DashSkin.heading(17))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(UIScale.pt(15))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .widgetBar(
            cornerRadius: 14,
            fill: palette.panel,
            stroke: stroke ?? palette.line,
            shadow: .black.opacity(dark ? 0.22 : 0.04),
            shadowRadius: 8,
            shadowY: 4)
    }
}

struct DatabaseSafetyFactsGrid: View {
    let facts: [DatabaseSafetyReviewFact]
    let dark: Bool
    @Environment(\.databaseAppTheme) private var appTheme

    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: appTheme)
    }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: UIScale.pt(120)),
                    spacing: UIScale.pt(14),
                    alignment: .topLeading)
            ],
            alignment: .leading,
            spacing: UIScale.pt(12)
        ) {
            ForEach(facts) { fact in
                HStack(alignment: .top, spacing: UIScale.pt(8)) {
                    Image(systemName: fact.symbol)
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                        .foregroundStyle(palette.inkFaint)
                        .frame(width: UIScale.pt(16))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(fact.label)
                            .font(.system(size: UIScale.pt(10.5), weight: .medium))
                            .foregroundStyle(palette.inkSoft)
                        Text(fact.value)
                            .font(.system(size: UIScale.pt(12), weight: .medium))
                            .foregroundStyle(palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(fact.value)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(fact.label): \(fact.value)")
            }
        }
    }
}

struct DatabaseSafetyCodeBlock: View {
    let text: String
    let dark: Bool
    @Environment(\.databaseAppTheme) private var appTheme

    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: appTheme)
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(DashSkin.mono(11))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
                .padding(UIScale.pt(11))
        }
        .frame(maxWidth: .infinity, minHeight: UIScale.pt(58), maxHeight: UIScale.pt(190))
        .background(palette.canvas, in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(9))
                .strokeBorder(palette.line)
        }
        .accessibilityLabel("Generated request")
        .accessibilityValue(text)
    }
}

struct DatabaseSafetyLabeledText: View {
    let label: String
    let text: String
    let monospaced: Bool
    let dark: Bool
    @Environment(\.databaseAppTheme) private var appTheme

    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: appTheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text(label)
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .foregroundStyle(palette.inkSoft)
            Text(text)
                .font(monospaced ? DashSkin.mono(10.5) : .system(size: UIScale.pt(11)))
                .foregroundStyle(palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(text)")
    }
}

struct DatabaseSafetyPill: View {
    let title: String
    let symbol: String
    let accentColor: Color
    let dark: Bool
    @Environment(\.databaseAppTheme) private var appTheme

    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: appTheme)
    }

    var body: some View {
        HStack(spacing: UIScale.pt(5)) {
            Image(systemName: symbol)
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(palette.ink)
        }
        .font(.system(size: UIScale.pt(10.5), weight: .semibold))
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(5))
        .background(accentColor.opacity(0.1), in: Capsule())
        .overlay { Capsule().strokeBorder(accentColor.opacity(0.35)) }
        .accessibilityLabel(title)
    }
}

struct DatabaseSafetyStatusLine: View {
    let text: String
    let symbol: String
    let color: Color
    let dark: Bool
    @Environment(\.databaseAppTheme) private var appTheme

    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: appTheme)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(6)) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
