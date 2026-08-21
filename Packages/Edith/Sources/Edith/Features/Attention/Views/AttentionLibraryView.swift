import EdithKit
import SwiftUI

struct AttentionLibraryView: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compactLayout
    @State private var pendingCategoryID = "work-coding"

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(16)) {
            controls
            if compactLayout {
                identityList
                identityDetail
            } else {
                HStack(alignment: .top, spacing: UIScale.pt(16)) {
                    identityList.frame(maxWidth: .infinity)
                    identityDetail.frame(width: UIScale.pt(340))
                }
            }
            categoryPanel
        }
        .sheet(isPresented: $store.showRulePreview) {
            rulePreview
        }
        .onAppear {
            if store.selectedIdentityID == nil {
                store.selectedIdentityID = store.filteredIdentities.first?.id
            }
        }
    }

    private var controls: some View {
        HStack(spacing: UIScale.pt(9)) {
            TextField("Search applications, services, and domains", text: $store.librarySearch)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: UIScale.pt(360))
            Picker("Kind", selection: $store.libraryKind) {
                ForEach(["All"] + AttentionCategoryKind.allCases.map(\.title), id: \.self) {
                    Text($0)
                }
            }
            .labelsHidden()
            .frame(width: UIScale.pt(145))
            Spacer()
            AttentionBadge(
                text:
                    "\(store.identities.filter { $0.categoryID == "uncategorized" }.count) UNCATEGORIZED",
                color: DashSkin.warn)
        }
    }

    private var identityList: some View {
        AttentionPanel(
            title: "Services", subtitle: "Native applications and websites share one identity"
        ) {
            VStack(spacing: 0) {
                ForEach(store.filteredIdentities) { identity in
                    identityRow(identity)
                    if identity.id != store.filteredIdentities.last?.id {
                        Divider().overlay(DashSkin.line(dark).opacity(0.55))
                    }
                }
            }
        }
    }

    private func identityRow(_ identity: AttentionIdentity) -> some View {
        let selected = store.selectedIdentityID == identity.id
        let category = store.category(for: identity.categoryID)
        return Button {
            store.selectedIdentityID = identity.id
            pendingCategoryID = identity.categoryID
        } label: {
            HStack(spacing: UIScale.pt(10)) {
                Image(systemName: identity.symbol)
                    .foregroundStyle(AttentionPalette.category(identity.categoryID, dark: dark))
                    .frame(width: UIScale.pt(30), height: UIScale.pt(30))
                    .background(
                        AttentionPalette.category(identity.categoryID, dark: dark).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text(identity.name)
                            .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                        if !identity.nativeApplications.isEmpty && !identity.domains.isEmpty {
                            AttentionBadge(text: "UNIFIED", color: DashSkin.sage)
                        }
                    }
                    Text(category?.path ?? "Uncategorized")
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: UIScale.pt(3)) {
                    Text(AttentionTime.duration(identity.totalSeconds, compact: true))
                        .font(DashSkin.mono(10, weight: .semibold))
                    Text(identity.ruleSource)
                        .font(.system(size: UIScale.pt(8.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            .foregroundStyle(DashSkin.ink(dark))
            .padding(UIScale.pt(8))
            .background(
                selected ? DashSkin.accent(dark).opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(9))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var identityDetail: some View {
        if let identity = store.selectedIdentity {
            AttentionPanel(title: identity.name, subtitle: "Unified service identity") {
                VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                    HStack(spacing: UIScale.pt(10)) {
                        Image(systemName: identity.symbol)
                            .font(.system(size: UIScale.pt(21)))
                            .foregroundStyle(
                                AttentionPalette.category(identity.categoryID, dark: dark)
                            )
                            .frame(width: UIScale.pt(46), height: UIScale.pt(46))
                            .background(
                                AttentionPalette.category(identity.categoryID, dark: dark).opacity(
                                    0.1),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            Text(AttentionTime.duration(identity.totalSeconds, compact: true))
                                .font(DashSkin.serif(22))
                            Text("across the mock month")
                                .font(.system(size: UIScale.pt(9.5)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                    Divider().overlay(DashSkin.line(dark))
                    surfaceSection("Native applications", values: identity.nativeApplications)
                    surfaceSection("Web domains", values: identity.domains)
                    Picker("Category", selection: $pendingCategoryID) {
                        ForEach(store.categories) { category in Text(category.path).tag(category.id)
                        }
                    }
                    Button("Preview historical change") { store.showRulePreview = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .pointerCursor()
                }
            }
        }
    }

    private func surfaceSection(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            Text(title.uppercased())
                .font(.system(size: UIScale.pt(8.5), weight: .bold))
                .tracking(0.7)
                .foregroundStyle(DashSkin.inkFaint(dark))
            if values.isEmpty {
                Text("None")
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            } else {
                ForEach(values, id: \.self) { value in
                    HStack(spacing: UIScale.pt(6)) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(DashSkin.sage)
                        Text(value).font(DashSkin.mono(9.5))
                    }
                }
            }
        }
    }

    private var categoryPanel: some View {
        AttentionPanel(
            title: "Category system", subtitle: "Every label is editable and profile-aware"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: UIScale.pt(160)), spacing: UIScale.pt(10))],
                spacing: UIScale.pt(10)
            ) {
                ForEach(store.categories) { category in
                    HStack(spacing: UIScale.pt(9)) {
                        Image(systemName: category.symbol)
                            .foregroundStyle(AttentionPalette.kind(category.kind, dark: dark))
                            .frame(width: UIScale.pt(26), height: UIScale.pt(26))
                            .background(
                                AttentionPalette.kind(category.kind, dark: dark).opacity(0.1),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(category.path).font(
                                .system(size: UIScale.pt(10.5), weight: .medium))
                            Text(category.kind.title)
                                .font(.system(size: UIScale.pt(8.5)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                        Spacer()
                    }
                    .padding(UIScale.pt(9))
                    .background(
                        DashSkin.grid(dark).opacity(0.38),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
                }
            }
        }
    }

    @ViewBuilder
    private var rulePreview: some View {
        if let identity = store.selectedIdentity {
            VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                Text("Preview category rule").font(DashSkin.serif(24))
                Text(
                    "Assign \(identity.name) to \(store.category(for: pendingCategoryID)?.path ?? "Uncategorized")"
                )
                .font(.system(size: UIScale.pt(12), weight: .medium))
                HStack(spacing: UIScale.pt(12)) {
                    previewMetric(
                        "Segments", "\(store.segments.filter { $0.service == identity.name }.count)"
                    )
                    previewMetric(
                        "Historical time",
                        AttentionTime.duration(identity.totalSeconds, compact: true))
                    previewMetric("Conflicts", "0")
                }
                Text(
                    "The raw application, URL, profile, and timing observations remain unchanged. This action creates a reversible rule transaction."
                )
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { store.showRulePreview = false }
                    Button("Apply rule") {
                        store.assignCategory(pendingCategoryID, to: identity.id)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(UIScale.pt(24))
            .frame(width: UIScale.pt(520))
        }
    }

    private func previewMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title).font(.system(size: UIScale.pt(9))).foregroundStyle(.secondary)
            Text(value).font(DashSkin.serif(18))
        }
        .padding(UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
    }
}
