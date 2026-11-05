import EdithExtensionUI
import EdithHostCore
import SwiftUI

enum HostExtensionDetailLayout {
    static let padding = 24.0
    static let sectionSpacing = 24.0
    static let heroIcon = 60.0
    static let previewHeight = 176.0
    static let previewSize = CGSize(width: 200, height: 88)
    static let previewScale = 1.5
}

struct HostExtensionHero<Action: View>: View {
    let entry: HostExtension
    let tagline: String
    let categoryTitle: String?
    @ViewBuilder let action: () -> Action
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: UIScale.pt(16)) {
            identity.frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
    }

    private var identity: some View {
        let dark = scheme == .dark
        return HStack(alignment: .center, spacing: UIScale.pt(16)) {
            PageGuideBadge(
                extensionID: entry.id, icon: entry.icon,
                size: HostExtensionDetailLayout.heroIcon, tone: .monochrome
            )
            .flushLeading()
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(entry.title).font(.edithText(.title2)).fontWeight(.bold)
                    .foregroundStyle(DashSkin.ink(dark)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(tagline).font(.edithText(.body)).foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let categoryTitle {
                    Text(categoryTitle).font(.edithText(.caption)).foregroundStyle(
                        DashSkin.inkFaint(dark))
                }
            }
        }
    }
}

struct HostExtensionArtwork: View {
    let entry: HostExtension
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let accent = DashSkin.accent(dark)
        let banner = RoundedRectangle(
            cornerRadius: UIScale.pt(PageMetrics.cardCornerRadius), style: .continuous)
        let window = RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
        let scale = HostExtensionDetailLayout.previewScale
        HostExtensionPreview(entry: entry, dark: dark)
            .frame(
                width: UIScale.pt(HostExtensionDetailLayout.previewSize.width),
                height: UIScale.pt(HostExtensionDetailLayout.previewSize.height)
            )
            .scaleEffect(scale)
            .frame(
                width: UIScale.pt(HostExtensionDetailLayout.previewSize.width * scale),
                height: UIScale.pt(HostExtensionDetailLayout.previewSize.height * scale)
            )
            .background(DashSkin.paper2(dark), in: window)
            .overlay { window.strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(0.75)) }
            .clipShape(window)
            .shadow(
                color: .black.opacity(dark ? 0.3 : 0.08), radius: UIScale.pt(12), y: UIScale.pt(4)
            )
            .frame(maxWidth: .infinity)
            .frame(height: UIScale.pt(HostExtensionDetailLayout.previewHeight))
            .background {
                banner.fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(dark ? 0.2 : 0.14), accent.opacity(dark ? 0.06 : 0.04),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { banner.strokeBorder(accent.opacity(0.14), lineWidth: UIScale.pt(0.75)) }
            .accessibilityHidden(true)
    }
}

struct HostExtensionPlacementList: View {
    let placements: [HostExtensionPlacement]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            PageSectionHeader("Where you will find it")
            VStack(spacing: 0) {
                ForEach(Array(placements.enumerated()), id: \.element.id) { index, placement in
                    if index > 0 { Divider() }
                    HStack(alignment: .top, spacing: UIScale.pt(12)) {
                        EdithIconView(placement.icon)
                            .font(.system(size: UIScale.pt(14), weight: .medium))
                            .foregroundStyle(DashSkin.accent(dark))
                            .frame(width: UIScale.pt(24))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(placement.title).font(.edithText(.callout)).fontWeight(.semibold)
                            Text(placement.detail).font(.edithText(.caption))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, UIScale.pt(PageMetrics.cardPadding))
                    .padding(.vertical, UIScale.pt(12))
                    .accessibilityElement(children: .combine)
                }
            }
            .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
        }
    }
}

struct HostExtensionPermissionList: View {
    let required: [HostPermission]
    let optional: [HostPermission]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            PageSectionHeader(
                "Permissions",
                subtitle: required.isEmpty && optional.isEmpty
                    ? nil : "macOS asks the first time. You can change them any time in Settings.")
            if required.isEmpty && optional.isEmpty {
                Label("No special permissions needed.", edith: .shield)
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array((required + optional).enumerated()), id: \.element) {
                        index, permission in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            HStack(spacing: UIScale.pt(8)) {
                                Text(permission.displayName).font(.edithText(.callout))
                                    .fontWeight(.semibold)
                                Text(required.contains(permission) ? "Needed" : "Optional")
                                    .font(.edithText(.caption))
                                    .foregroundStyle(
                                        required.contains(permission)
                                            ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
                            }
                            Text(permission.reason).font(.edithText(.caption))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, UIScale.pt(PageMetrics.cardPadding))
                        .padding(.vertical, UIScale.pt(12))
                        .accessibilityElement(children: .combine)
                    }
                }
                .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
            }
        }
    }
}

struct HostExtensionExamples: View {
    let examples: [String]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            PageSectionHeader(
                "From the terminal or an agent",
                subtitle:
                    "Every action here also works from the ed command and from agents through ed mcp."
            )
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                ForEach(examples, id: \.self) { example in
                    Text(example).font(.edithText(.callout, design: .monospaced))
                        .foregroundStyle(DashSkin.ink(scheme == .dark))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, UIScale.pt(PageMetrics.cardPadding))
            .padding(.vertical, UIScale.pt(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
        }
    }
}

extension HostExtensionGuide {
    var pageSteps: [PageGuideStep] {
        steps.map { PageGuideStep(icon: $0.icon, title: $0.title, detail: $0.detail) }
    }
}
