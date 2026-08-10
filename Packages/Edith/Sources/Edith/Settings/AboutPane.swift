import AppKit
import EdithKit
import SwiftUI

struct AboutPane: View {
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"

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
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("About")
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
            }
            VStack(spacing: UIScale.pt(6)) {
                Text("Edith")
                    .font(.system(size: UIScale.pt(28), weight: .bold))
                Text(version)
                    .font(.system(size: UIScale.pt(12)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text("Every little Mac utility you'd otherwise pay for, under one roof.")
                .font(.system(size: UIScale.pt(14), weight: .medium))
                .multilineTextAlignment(.center)
            Text(story)
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: UIScale.pt(460))
            Button {
                NSWorkspace.shared.open(URL(string: "https://pulkit.page")!)
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Image(systemName: "link")
                        .font(.system(size: UIScale.pt(11), weight: .semibold))
                    Text("pulkit.page")
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, UIScale.pt(16))
                .padding(.vertical, UIScale.pt(8))
                .background(theme, in: Capsule())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.top, UIScale.pt(2))
            Text("Made with ♥ by Pulkit")
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, UIScale.pt(32))
    }
}
