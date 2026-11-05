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
                    .font(.edithText(.title3).weight(.semibold))
                Text(detail)
                    .font(.edithText(.callout))
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
                        EdithIconView(.refresh)
                            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                        EdithIconView(.filter)
                            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                        Label("Add connection", edith: .plus)
                            .frame(minHeight: UIScale.pt(28))
                    }
                    EdithTextField(
                        placeholder: "Search saved connections",
                        text: .constant(""),
                        icon: .search,
                        compact: true,
                        clearable: true
                    )
                }
                .pageGutter(compact)
                .padding(.vertical, UIScale.pt(16))
                PageHeaderDivider()
                ScrollView {
                    DatabaseConnectionListSurface {
                        ForEach(0..<6, id: \.self) { index in
                            if index > 0 { DatabaseConnectionRowDivider() }
                            DatabaseConnectionRowSkeleton(index: index, accent: theme)
                        }
                    }
                    .pageGutter(compact)
                    .padding(.vertical, UIScale.pt(PageMetrics.pinnedContentTop))
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
        GeometryReader { proxy in
            ScrollView {
                recoveryContent
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var recoveryContent: some View {
        VStack(spacing: UIScale.pt(8)) {
            PageEmptyState(
                icon: .wrench,
                title: "Database needs a quick repair",
                message:
                    "Edith's local database tools did not start. Repairing refreshes them and reopens your saved connections. Your connections and data are not touched.",
                primary: PageAction(
                    "Repair and continue", icon: .sync,
                    identifier: "database.repair", perform: repair)
            )
            .frame(minHeight: UIScale.pt(280))
            DisclosureGroup("Technical details", isExpanded: $showsDetails) {
                Text(detail)
                    .font(.system(size: UIScale.pt(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, UIScale.pt(8))
            }
            .font(.edithText(.subheadline))
            .frame(maxWidth: UIScale.pt(420))
        }
        .frame(maxWidth: UIScale.pt(720))
        .padding(UIScale.pt(24))
        .frame(maxWidth: .infinity)
    }
}
