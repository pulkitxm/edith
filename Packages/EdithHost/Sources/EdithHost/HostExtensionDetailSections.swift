import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostExtensionHero<Action: View>: View {
    let entry: HostExtension
    let tagline: String
    let categoryTitle: String?
    let active: Bool
    @ViewBuilder let action: () -> Action
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            HStack(alignment: .center, spacing: UIScale.pt(16)) {
                HostExtensionIcon(symbolName: entry.symbolName, active: active, size: compact ? 56 : 72)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(entry.title).font(.edithText(.title)).fontWeight(.bold)
                        .accessibilityAddTraits(.isHeader)
                    Text(tagline).font(.edithText(.title3)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let categoryTitle {
                        Text(categoryTitle).font(.edithText(.caption))
                            .foregroundStyle(DashSkin.accent(dark))
                            .padding(.horizontal, UIScale.pt(8)).padding(.vertical, UIScale.pt(2))
                            .background(DashSkin.accent(dark).opacity(0.12), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
            action()
        }
    }
}

struct HostExtensionPlacementList: View {
    let placements: [HostExtensionPlacement]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            PageSectionHeader("Where you will find it")
            VStack(spacing: 0) {
                ForEach(Array(placements.enumerated()), id: \.element.id) { index, placement in
                    if index > 0 { Divider() }
                    HStack(alignment: .top, spacing: UIScale.pt(12)) {
                        Image(systemName: placement.symbolName)
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
                    .padding(UIScale.pt(12))
                    .accessibilityElement(children: .combine)
                }
            }
            .edithSurface(cornerRadius: 12)
        }
    }
}

struct HostExtensionPermissionList: View {
    let required: [HostPermission]
    let optional: [HostPermission]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            PageSectionHeader(
                "Permissions",
                subtitle: required.isEmpty && optional.isEmpty
                    ? nil : "macOS asks the first time. You can change them any time in Settings.")
            if required.isEmpty && optional.isEmpty {
                Label("No special permissions needed.", systemImage: "checkmark.shield")
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
                        .padding(UIScale.pt(12))
                        .accessibilityElement(children: .combine)
                    }
                }
                .edithSurface(cornerRadius: 12)
            }
        }
    }
}

struct HostExtensionExamples: View {
    let examples: [String]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            PageSectionHeader(
                "From the terminal or an agent",
                subtitle: "Every action here is also available through the ed CLI and ed mcp.")
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                ForEach(examples, id: \.self) { example in
                    Text(example).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(UIScale.pt(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                DashSkin.paper(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        }
    }
}

extension HostExtensionGuide {
    var pageSteps: [PageGuideStep] {
        steps.map { PageGuideStep(symbolName: $0.symbolName, title: $0.title, detail: $0.detail) }
    }
}
