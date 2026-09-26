import AppKit
import EdithKit
import SwiftUI

struct NotchBrowserSetupView: View {
    var store: NotchBrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notch Browser")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Browse with a Chrome profile's sessions, right from the notch.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                if store.profile != nil {
                    Button("Cancel") { store.cancelChoosingProfile() }
                        .buttonStyle(.edith(.borderless))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            checks
            profilesSection
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var checks: some View {
        VStack(spacing: 8) {
            checkRow(
                ok: store.readiness != .notInstalled,
                title: store.readiness == .notInstalled
                    ? "Google Chrome is not installed" : "Google Chrome is installed",
                detail: store.readiness == .notInstalled
                    ? "Install Chrome and sign in to a profile, then check again." : nil,
                actionTitle: store.readiness == .notInstalled ? "Download Chrome" : nil,
                action: store.downloadChrome)
            if case .unreadable(let reason) = store.readiness {
                checkRow(
                    ok: false, warning: true, title: "Edith cannot read Chrome's data",
                    detail:
                        "\(reason) Allow access if macOS asks, or add Edith under Full Disk Access.",
                    actionTitle: "Open Privacy Settings", action: store.openPrivacySettings)
            } else if store.readiness != .notInstalled {
                checkRow(
                    ok: store.readiness == .ready || store.readiness == .noProfiles,
                    warning: true,
                    title: defaultTitle,
                    detail: defaultDetail,
                    actionTitle: isDefault ? nil : "Make Chrome Default",
                    action: store.makeChromeDefault)
            }
        }
    }

    private var isDefault: Bool {
        if case .notDefault = store.readiness { return false }
        return true
    }

    private var defaultTitle: String {
        guard case .notDefault(let current) = store.readiness else {
            return "Chrome is your default browser"
        }
        return "\(current ?? "Another app") is your default browser"
    }

    private var defaultDetail: String? {
        guard !isDefault else { return nil }
        return "Links you open elsewhere will not land in the profile you attach here."
    }

    private func checkRow(
        ok: Bool, warning: Bool = false, title: String, detail: String?, actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(
                systemName: ok
                    ? "checkmark.circle.fill"
                    : warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"
            )
            .font(.system(size: 14))
            .foregroundStyle(
                ok ? Color.green : warning ? Color.orange : Color(red: 0.93, green: 0.36, blue: 0.3)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.edith(.borderless))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Color.white.opacity(0.92), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var profilesSection: some View {
        if store.readiness == .noProfiles {
            Text("Chrome has no profiles yet. Open Chrome once, then check again.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
        } else if store.readiness.allowsAttaching {
            VStack(alignment: .leading, spacing: 8) {
                Text("Attach a Chrome profile")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.profiles) { profile in
                            profileCard(profile)
                        }
                    }
                }
                .disabled(store.syncState.isBusy)
            }
        }
    }

    private func profileCard(_ profile: ChromeProfile) -> some View {
        let attached = store.profile == profile
        return Button {
            store.attach(profile)
        } label: {
            VStack(spacing: 8) {
                ChromeProfileAvatar(profile: profile, size: 54)
                VStack(spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(profile.email ?? profile.directory)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(width: 136, height: 124)
            .background(
                .white.opacity(attached ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(attached ? 0.5 : 0), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.edith(.borderless))
        .help("Attach \(profile.name)")
    }

    @ViewBuilder private var footer: some View {
        switch store.syncState {
        case .unlocking:
            status(
                "Waiting for Keychain access to Chrome Safe Storage. Choose Always Allow to skip this next time."
            )
        case .importing(let message):
            status(message)
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Check again") { store.refreshEnvironment() }
                    .buttonStyle(.edith(.borderless))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .idle:
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.white.opacity(0.45))
                Text(
                    "Cookies and site storage are copied from Chrome on this Mac. Nothing leaves it."
                )
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                Button("Check again") { store.refreshEnvironment() }
                    .buttonStyle(.edith(.borderless))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func status(_ message: String) -> some View {
        HStack(spacing: 8) {
            SkeletonReplica(message) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
            }
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

struct ChromeProfileAvatar: View {
    let profile: ChromeProfile
    let size: CGFloat

    var body: some View {
        Group {
            if let image = ChromeProfileAvatar.image(for: profile) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    tint
                    Text(profile.initials)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }

    private var tint: Color { Self.tint(for: profile) }

    static func tint(for profile: ChromeProfile) -> Color {
        guard let argb = profile.colorARGB else { return Color(red: 0.26, green: 0.52, blue: 0.96) }
        return Color(
            red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255)
    }

    @MainActor private static var cache: [URL: NSImage] = [:]
    @MainActor private static var badges: [String: NSImage] = [:]

    @MainActor static func badge(for profile: ChromeProfile, diameter: CGFloat) -> NSImage {
        let key = "\(profile.id)|\(profile.pictureURL?.path ?? "")|\(diameter)"
        if let cached = badges[key] { return cached }
        let picture = image(for: profile)
        let fill = NSColor(tint(for: profile))
        let initials = profile.initials
        let badge = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) {
            rect in
            NSBezierPath(ovalIn: rect).addClip()
            if let picture {
                let side = min(picture.size.width, picture.size.height)
                let source = NSRect(
                    x: (picture.size.width - side) / 2, y: (picture.size.height - side) / 2,
                    width: side, height: side)
                picture.draw(in: rect, from: source, operation: .copy, fraction: 1)
            } else {
                fill.setFill()
                rect.fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: diameter * 0.4, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                let text = NSAttributedString(string: initials, attributes: attributes)
                let size = text.size()
                text.draw(
                    at: NSPoint(
                        x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            }
            return true
        }
        badges[key] = badge
        return badge
    }

    @MainActor static func image(for profile: ChromeProfile) -> NSImage? {
        guard let url = profile.pictureURL else { return nil }
        if let cached = cache[url] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[url] = image
        return image
    }
}
