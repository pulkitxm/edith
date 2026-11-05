import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostOnboardingPermissionsView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        let items = model.permissionItems
        let batch = model.relaunchBatch
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            PageSectionHeader(
                "Allow what your tools need",
                subtitle:
                    "macOS asks you to approve each permission. Allow them one at a time, or leave optional ones for the first time a tool needs them."
            )
            ForEach(items) { item in card(item) }
            if !batch.isEmpty { relaunchBanner(batch) }
            HostOnboardingFooter(
                back: { model.back() },
                skip: PageAction("Skip, ask me later", identifier: "onboarding.skip-step") {
                    model.skipStep()
                },
                primary: PageAction(
                    "Install \(model.selected.count) \(model.selected.count == 1 ? "tool" : "tools")",
                    symbolName: "arrow.down.circle", identifier: "onboarding.install"
                ) { model.installSelection() },
                primaryEnabled: model.canInstall, busy: model.busy)
        }
    }

    private func card(_ item: HostOnboardingPermission) -> some View {
        let current = model.currentPermission == item.permission
        let deferred = model.deferredPermissions.contains(item.permission)
        return HStack(alignment: .top, spacing: UIScale.pt(12)) {
            Image(systemName: item.permission.symbolName)
                .font(.system(size: UIScale.pt(16), weight: .medium))
                .foregroundStyle(item.isGranted ? Color.green : DashSkin.accent(dark))
                .frame(width: UIScale.pt(34), height: UIScale.pt(34))
                .background(
                    (item.isGranted ? Color.green : DashSkin.accent(dark)).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(10), style: .continuous))
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                HStack(spacing: UIScale.pt(8)) {
                    Text(item.permission.displayName).font(.edithText(.headline))
                    status(item, deferred: deferred)
                }
                Text(item.permission.plainWords).font(.edithText(.callout))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(usage(item)).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if item.needsRelaunch, !item.isGranted {
                    Text("macOS applies this after Edith restarts.")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                actions(item, current: current, deferred: deferred)
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(10))
                .strokeBorder(current ? DashSkin.accent(dark).opacity(0.6) : Color.clear)
        )
        .accessibilityElement(children: .contain)
    }

    private func usage(_ item: HostOnboardingPermission) -> String {
        var parts: [String] = []
        if !item.requiredBy.isEmpty {
            parts.append("Needed by " + item.requiredBy.map(\.title).joined(separator: ", "))
        }
        if !item.optionalFor.isEmpty {
            parts.append("Optional for " + item.optionalFor.map(\.title).joined(separator: ", "))
        }
        return parts.joined(separator: ". ") + "."
    }

    @ViewBuilder private func status(_ item: HostOnboardingPermission, deferred: Bool)
        -> some View
    {
        if item.isGranted {
            badge("Granted", .green)
        } else if model.permissions.awaitingRelaunch.contains(item.permission) {
            badge("Restart to finish", .orange)
        } else if item.asksOnFirstUse {
            badge("Asked on first use", .secondary)
        } else if deferred {
            badge("Later", .secondary)
        } else {
            badge(item.isRequired ? "Required" : "Optional", item.isRequired ? .orange : .secondary)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).lineLimit(1).fixedSize().font(.edithText(.caption2)).fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, UIScale.pt(7)).padding(.vertical, UIScale.pt(2))
            .background(color.opacity(0.14), in: Capsule())
    }

    @ViewBuilder private func actions(
        _ item: HostOnboardingPermission, current: Bool, deferred: Bool
    ) -> some View {
        if !item.isGranted, !item.asksOnFirstUse {
            HStack(spacing: UIScale.pt(8)) {
                Button("Allow \(item.permission.displayName)") {
                    Task { await model.requestPermission(item.permission) }
                }
                .buttonStyle(.edith(current ? .primary : .secondary))
                .disabled(model.permissions.requesting != nil || model.busy)
                .accessibilityIdentifier("onboarding.allow.\(item.permission.rawValue)")
                if item.permission.settingsURL != nil {
                    Button("Open System Settings") { model.openSettings(item.permission) }
                        .buttonStyle(.edith(.borderless))
                }
                if item.canDefer {
                    Button(deferred ? "Ask now" : "Ask me later") {
                        model.deferPermission(item.permission, !deferred)
                    }
                    .buttonStyle(.edith(.borderless))
                }
            }
        }
    }

    private func relaunchBanner(_ batch: [HostPermission]) -> some View {
        HStack(alignment: .center, spacing: UIScale.pt(12)) {
            Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: UIScale.pt(22)))
                .foregroundStyle(DashSkin.accent(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text("Relaunch Edith to finish \(batch.map(\.displayName).joined(separator: ", "))")
                    .font(.edithText(.headline)).fixedSize(horizontal: false, vertical: true)
                Text(
                    "Turn each one on in System Settings first, then relaunch once. Edith comes back to this step with your choices saved."
                ).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Relaunch Edith") { model.relaunch() }.buttonStyle(.edith(.primary))
                .accessibilityIdentifier("onboarding.relaunch")
        }
        .padding(UIScale.pt(12))
        .background(
            DashSkin.accent(dark).opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }
}
