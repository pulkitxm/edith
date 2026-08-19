import AppKit
import EdithKit
import SwiftUI

struct AboutPane: View {
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @State private var contributors: [Contributor] = []
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    private var theme: Color { themeColor(themeName) }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        return "Version \(short)"
    }

    private let story = """
        Hi, I'm Pulkit, the builder of Edith. I used to pay for a whole shelf of \
        separate Mac apps: one to watch usage, one for the menu bar, one for music, \
        and on it went. It never sat right with me. So I set out to build a single \
        app that brings all of those little features under one roof. That's Edith.
        """

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: UIScale.pt(0)) {
                    Spacer(minLength: 44)
                    content
                    Spacer(minLength: 44)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(DashSkin.paper(dark).paperGrain(dark: dark, opacity: 0.03))
    }

    private var content: some View {
        VStack(spacing: UIScale.pt(18)) {
            if let icon = Brand.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: UIScale.pt(88), height: UIScale.pt(88))
                    .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(20), style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: UIScale.pt(12), y: 6)
                    .pendantGlow(dark: dark, anchor: .center, intensity: 1.3)
            }
            VStack(spacing: UIScale.pt(6)) {
                Text("Edith")
                    .font(DashSkin.serif(13.5, weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(version)
                    .font(DashSkin.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Text("Every little Mac utility you'd otherwise pay for, under one roof.")
                .font(.system(size: UIScale.pt(14), weight: .medium))
                .foregroundStyle(DashSkin.ink(dark))
                .multilineTextAlignment(.center)
            Text(story)
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: UIScale.pt(460))
            Button {
                NSWorkspace.shared.open(Self.repository)
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    githubMark
                    Text("pulkitxm/edith")
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                }
                .foregroundStyle(theme)
                .padding(.horizontal, UIScale.pt(16))
                .padding(.vertical, UIScale.pt(8))
                .background(theme.opacity(0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(theme.opacity(0.38), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Open the repository on GitHub")
            .padding(.top, UIScale.pt(2))
            contributorWall
            Text("Made with ♥ by Pulkit")
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, UIScale.pt(32))
        .task {
            guard automaticActionsEnabled else { return }
            contributors = Contributors.cached()
            contributors = await Contributors.load()
        }
    }

    private static let repository = URL(string: "https://github.com/pulkitxm/edith")!

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
            VStack(spacing: UIScale.pt(10)) {
                eyebrow("Contributors")
                LazyVGrid(columns: avatarColumns, spacing: UIScale.pt(10)) {
                    ForEach(contributors) { person in
                        Button {
                            NSWorkspace.shared.open(person.profileURL)
                        } label: {
                            avatar(for: person)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help(person.login)
                    }
                }
                .frame(maxWidth: UIScale.pt(340))
            }
            .padding(.top, UIScale.pt(6))
        }
    }

    private func avatar(for person: Contributor) -> some View {
        AsyncImage(url: person.avatarURL) { image in
            image.resizable().interpolation(.high)
        } placeholder: {
            Circle().fill(DashSkin.line(dark))
        }
        .frame(width: UIScale.pt(44), height: UIScale.pt(44))
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(DashSkin.line(dark), lineWidth: 1))
    }
}
