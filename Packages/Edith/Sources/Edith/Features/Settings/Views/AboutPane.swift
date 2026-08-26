import AppKit
import EdithKit
import SwiftUI

struct AboutPane: View {
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @State private var contributors: [Contributor] = []
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    private let inspection = AppInspectionCenter()

    private var theme: Color { themeColor(themeName) }

    private var version: String {
        "Version \(inspection.info().version)"
    }

    private let story = """
        Hi, I'm Pulkit, the builder of Edith. I used to pay for a whole shelf of \
        separate Mac apps: one to watch usage, one for the menu bar, one for music, \
        and on it went. It never sat right with me. So I set out to build a single \
        app that brings all of those little features under one roof. That's Edith.
        """

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            PageHeader(
                "About",
                accessory: {
                    Text("Every little Mac utility you would otherwise pay for, under one roof.")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(.secondary)
                })
            ScrollView {
                content
                    .pageContent(compact, width: .readable)
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .navigationTitle("About")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
            SkinCard(title: "Edith", note: version, dark: scheme == .dark) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: UIScale.pt(18)) {
                        appIcon
                        storyBlock
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                        appIcon
                        storyBlock
                    }
                }
            }
            contributorWall
            Text("Made with ♥ by Pulkit")
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task {
            guard automaticActionsEnabled else { return }
            let cacheSnapshot = Contributors.cacheSnapshot()
            contributors = cacheSnapshot.people
            contributors = await Contributors.load(cacheSnapshot: cacheSnapshot)
        }
    }

    @ViewBuilder private var appIcon: some View {
        if let icon = Brand.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: UIScale.pt(88), height: UIScale.pt(88))
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(20), style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: UIScale.pt(10), y: 5)
                .accessibilityHidden(true)
        }
    }

    private var storyBlock: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Text(story)
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                _ = try? inspection.openLink("repository", contributors: contributors)
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    githubMark
                    Text("pulkitxm/edith")
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                }
            }
            .buttonStyle(EdithButtonStyle(.secondary, tint: theme))
            .help("Open the repository on GitHub")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var githubMark: some View {
        if let mark = ProviderLogo.image(named: "github") {
            Image(nsImage: mark)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: UIScale.pt(12), height: UIScale.pt(12))
        } else {
            Image(systemName: "link")
                .font(.system(size: UIScale.pt(11), weight: .semibold))
        }
    }

    private var avatarColumns: [GridItem] {
        [GridItem(.adaptive(minimum: UIScale.pt(52)), spacing: UIScale.pt(10))]
    }

    @ViewBuilder private var contributorWall: some View {
        if !contributors.isEmpty {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                PageSectionHeader(
                    "Contributors", subtitle: "People who have helped shape Edith")
                LazyVGrid(columns: avatarColumns, spacing: UIScale.pt(10)) {
                    ForEach(contributors) { person in
                        Button {
                            _ = try? inspection.openLink(
                                "contributor:\(person.login)", contributors: contributors)
                        } label: {
                            avatar(for: person)
                        }
                        .buttonStyle(.edith(.borderless))
                        .help(person.login)
                        .accessibilityLabel("Open \(person.login) on GitHub")
                    }
                }
                .frame(maxWidth: UIScale.pt(520), alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func avatar(for person: Contributor) -> some View {
        AsyncImage(url: person.avatarURL) { image in
            image.resizable().interpolation(.high)
        } placeholder: {
            Circle().fill(Color.secondary.opacity(0.18))
        }
        .frame(width: UIScale.pt(44), height: UIScale.pt(44))
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
