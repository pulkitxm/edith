import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostAboutPage: View {
    let identity: HostIdentity
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        AppTheme.standard.rawValue
    @State private var contributors: [HostContributor] = []
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @Environment(\.colorScheme) private var scheme

    private var theme: Color { themeColor(themeName) }

    private var version: String {
        "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
    }

    private let story = """
        Hi, I'm Pulkit, the builder of Edith. I used to pay for a whole shelf of \
        separate Mac apps: one to watch usage, one for the menu bar, one for music, \
        and on it went. It never sat right with me. So I set out to build a single \
        app that brings all of those little features under one roof. That's Edith.
        """

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .padding(.vertical, UIScale.pt(44))
                    .frame(minHeight: geometry.size.height)
            }
        }
        .pageSurface()
        .navigationTitle("About")
    }

    private var content: some View {
        VStack(spacing: UIScale.pt(18)) {
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: UIScale.pt(88), height: UIScale.pt(88))
                    .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(20), style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(spacing: UIScale.pt(6)) {
                Text("Edith")
                    .font(PageMetrics.titleFont(false))
                PageSubtitle(version).monospacedDigit()
            }
            Text("Every little Mac utility you'd otherwise pay for, under one roof.")
                .font(.edithText(.body).weight(.medium))
                .multilineTextAlignment(.center)
            Text(story)
                .font(.edithText(.callout))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: UIScale.pt(460))
            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/pulkitxm/edith")!)
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    githubMark
                    Text("pulkitxm/edith")
                        .font(.edithText(.callout).weight(.semibold))
                }
                .foregroundStyle(theme)
                .padding(.horizontal, UIScale.pt(16))
                .padding(.vertical, UIScale.pt(8))
                .background(theme.opacity(0.16), in: Capsule(style: .circular))
                .overlay(Capsule(style: .circular).strokeBorder(theme.opacity(0.38), lineWidth: 1))
            }
            .buttonStyle(.edithShaped(Capsule(style: .circular)))
            .help("Open the repository on GitHub")
            .padding(.top, UIScale.pt(2))
            contributorWall
            Text("Made with ♥ by Pulkit")
                .font(.edithText(.caption))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, UIScale.pt(32))
        .pageTask {
            let cacheSnapshot = HostContributors.cacheSnapshot(identity: identity)
            contributors = cacheSnapshot.people
            let loaded = await HostContributors.load(
                identity: identity, cacheSnapshot: cacheSnapshot)
            guard !Task.isCancelled else { return }
            contributors = loaded
        }
    }

    @ViewBuilder private var githubMark: some View {
        if let mark = HostBrand.github {
            Image(nsImage: mark)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: UIScale.pt(12), height: UIScale.pt(12))
        } else {
            EdithIconView(.link)
                .font(.edithText(.caption).weight(.semibold))
        }
    }

    private var avatarColumns: [GridItem] {
        [GridItem(.adaptive(minimum: UIScale.pt(52)), spacing: UIScale.pt(10))]
    }

    @ViewBuilder private var contributorWall: some View {
        if !contributors.isEmpty {
            VStack(spacing: UIScale.pt(10)) {
                Text("Contributors")
                    .font(.edithText(.caption).weight(.semibold))
                    .foregroundStyle(.secondary)
                SkeletonGroup {
                    LazyVGrid(columns: avatarColumns, spacing: UIScale.pt(10)) {
                        ForEach(contributors) { person in
                            Button {
                                NSWorkspace.shared.open(person.profileURL)
                            } label: {
                                avatar(for: person)
                            }
                            .buttonStyle(.edith(.borderless))
                            .help(person.login)
                            .accessibilityLabel("Open \(person.login) on GitHub")
                        }
                    }
                    .frame(
                        maxWidth: UIScale.pt(min(340, Double(contributors.count) * 62 - 10)))
                }
            }
            .padding(.top, UIScale.pt(6))
        }
    }

    private func avatar(for person: HostContributor) -> some View {
        AsyncImage(url: person.avatarURL) { phase in
            switch phase {
            case .empty:
                SkeletonBlock(width: 44, height: 44, corner: 22)
            case let .success(image):
                image.resizable().interpolation(.high)
            case .failure:
                Circle()
                    .fill(Color.secondary.opacity(0.18))
                    .overlay {
                        Text(String(person.login.prefix(1)).uppercased())
                            .font(.edithText(.body).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
            @unknown default:
                Circle().fill(Color.secondary.opacity(0.18))
            }
        }
        .frame(width: UIScale.pt(44), height: UIScale.pt(44))
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
