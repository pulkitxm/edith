import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct DatabaseServiceProgressView: View {
    let title: String
    let detail: String
    var fraction: Double?
    let compact: Bool
    let palette: DatabaseThemePalette
    let theme: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progress
            catalog
        }
    }

    @ViewBuilder
    private var progress: some View {
        if let fraction {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                Text(title)
                    .font(.system(size: UIScale.pt(15), weight: .semibold))
                Text(detail)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
                LoadingProgress(value: fraction)
                    .accessibilityLabel(title)
            }
            .pageGutter(compact)
            .padding(.top, UIScale.pt(16))
        }
    }

    private var catalog: some View {
        SkeletonReplica("\(title). \(detail)") {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    HStack(alignment: .center, spacing: UIScale.pt(12)) {
                        Text("Connections")
                            .font(
                                .system(
                                    size: UIScale.pt(compact ? 17 : 20), weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.clockwise")
                            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                        Label("Add connection", systemImage: "plus")
                            .frame(minHeight: UIScale.pt(28))
                    }
                    EdithTextField(
                        placeholder: "Search saved connections",
                        text: .constant(""),
                        icon: "magnifyingglass",
                        compact: true,
                        clearable: true
                    )
                    .frame(maxWidth: UIScale.pt(560))
                }
                .pageGutter(compact)
                .padding(.vertical, UIScale.pt(compact ? 14 : 18))
                .background(palette.panel.opacity(0.64))
                Divider().opacity(0.35)
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(
                                    minimum: UIScale.pt(compact ? 220 : 270),
                                    maximum: UIScale.pt(360)),
                                spacing: UIScale.pt(14),
                                alignment: .top)
                        ],
                        alignment: .leading,
                        spacing: UIScale.pt(14)
                    ) {
                        ForEach(0..<6, id: \.self) { index in
                            DatabaseServiceConnectionCard(
                                index: index, palette: palette, theme: theme)
                        }
                    }
                    .pageGutter(compact)
                    .padding(.vertical, UIScale.pt(compact ? 18 : 24))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.canvas)
        }
    }
}

struct DatabaseServiceRecoveryView: View {
    let detail: String
    let theme: Color
    @Binding var showsDetails: Bool
    let repair: () -> Void

    var body: some View {
        ScrollView {
            recoveryContent
        }
        .accessibilityElement(children: .contain)
    }

    private var recoveryContent: some View {
        VStack(spacing: UIScale.pt(18)) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: UIScale.pt(34), weight: .medium))
                .foregroundStyle(DashSkin.warn)
                .accessibilityHidden(true)
            VStack(spacing: UIScale.pt(7)) {
                Text("Database needs a quick repair")
                    .font(.system(size: UIScale.pt(20), weight: .semibold))
                Text(
                    "Edith can repair its local database tools and reopen your saved connections."
                )
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            Button("Repair and continue", action: repair)
                .buttonStyle(.edith(.primary, tint: theme))
            DisclosureGroup("Technical details", isExpanded: $showsDetails) {
                Text(detail)
                    .font(.system(size: UIScale.pt(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, UIScale.pt(8))
            }
            .font(.system(size: UIScale.pt(11.5)))
            .frame(maxWidth: UIScale.pt(420))
        }
        .frame(maxWidth: UIScale.pt(560))
        .padding(UIScale.pt(36))
        .frame(maxWidth: .infinity)
    }
}

private struct DatabaseServiceConnectionCard: View {
    let index: Int
    let palette: DatabaseThemePalette
    let theme: Color

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(alignment: .top, spacing: UIScale.pt(11)) {
                ZStack {
                    RoundedRectangle(cornerRadius: UIScale.pt(9))
                        .fill(theme.opacity(0.11))
                    Image(systemName: "cylinder")
                        .font(.system(size: UIScale.pt(16), weight: .semibold))
                        .foregroundStyle(theme)
                }
                .frame(width: UIScale.pt(38), height: UIScale.pt(38))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(index.isMultiple(of: 2) ? "Analytics warehouse" : "Primary database")
                        .font(.system(size: UIScale.pt(14), weight: .semibold))
                        .lineLimit(2)
                    Text(index.isMultiple(of: 2) ? "PostgreSQL · Production" : "MySQL")
                        .font(.system(size: UIScale.pt(10.5), weight: .medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "ellipsis.circle")
                    .frame(width: UIScale.pt(26), height: UIScale.pt(26))
            }
            HStack(spacing: UIScale.pt(7)) {
                Image(systemName: "cylinder")
                    .font(.system(size: UIScale.pt(9.5), weight: .medium))
                Text(index.isMultiple(of: 2) ? "analytics" : "default_namespace")
                    .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                Text("Connected")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
            }
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, minHeight: UIScale.pt(126), alignment: .topLeading)
        .background(
            palette.panel.opacity(0.74),
            in: RoundedRectangle(cornerRadius: UIScale.pt(13)))
    }
}
