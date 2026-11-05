import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostOnboardingPermissionsView: View {
    @Bindable var model: HostWorkflowOnboardingModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    private var dark: Bool { scheme == .dark }

    var body: some View {
        let items = model.permissionItems
        let batch = model.relaunchBatch
        let asks = items.filter { !$0.isGranted && !$0.asksOnFirstUse }
        let granted = items.filter(\.isGranted)
        let firstUse = items.filter { !$0.isGranted && $0.asksOnFirstUse }
        let outstanding = asks.contains { !model.deferredPermissions.contains($0.permission) }
        VStack(alignment: .leading, spacing: UIScale.pt(20)) {
            HostOnboardingStepHeader(
                "Allow what your tools need",
                subtitle:
                    "macOS asks you to approve each permission once. Allow them now so your tools work the first time you open them."
            )
            if !batch.isEmpty { relaunchBanner(batch) }
            if asks.isEmpty {
                allSet
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    ForEach(asks) { item in card(item, batchPending: !batch.isEmpty) }
                }
            }
            if !granted.isEmpty || !firstUse.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    if !granted.isEmpty {
                        summaryRow(
                            "Already allowed", items: granted, icon: .success,
                            tint: DashSkin.ok, note: nil)
                    }
                    if !firstUse.isEmpty {
                        summaryRow(
                            "Asked when first used", items: firstUse, icon: .clock,
                            tint: .secondary,
                            note: "macOS shows its own prompt the first time a tool needs these.")
                    }
                }
            }
            HostOnboardingFooter(
                back: { model.back() },
                primary: PageAction(
                    "Install \(model.selected.count) \(model.selected.count == 1 ? "tool" : "tools")",
                    icon: .arrowDown, identifier: "onboarding.install"
                ) { model.installSelection() },
                primaryRole: batch.isEmpty && model.currentPermission == nil
                    ? .primary : .secondary,
                primaryEnabled: model.canInstall, busy: model.busy
            ) {
                if outstanding {
                    Text("You can allow the rest later in Settings.")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var allSet: some View {
        HStack(spacing: UIScale.pt(12)) {
            PageGuideBadge(icon: .stepAccess, size: 32, tint: DashSkin.ok)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("Nothing left to allow").font(.edithText(.headline))
                Text("Your tools have everything they need. Install them to finish setup.")
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(16))
        .hostOnboardingTile()
    }

    private func card(_ item: HostOnboardingPermission, batchPending: Bool) -> some View {
        let current = model.currentPermission == item.permission
        let deferred = model.deferredPermissions.contains(item.permission)
        let awaiting = model.permissions.awaitingRelaunch.contains(item.permission)
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(12)))
            : AnyLayout(HStackLayout(alignment: .center, spacing: UIScale.pt(16)))
        return layout {
            HStack(alignment: .center, spacing: UIScale.pt(12)) {
                PageGuideBadge(icon: item.permission.icon, size: 32)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    HStack(spacing: UIScale.pt(8)) {
                        Text(item.permission.displayName).font(.edithText(.headline))
                        status(item, deferred: deferred, awaiting: awaiting)
                    }
                    Text(item.permission.plainWords).font(.edithText(.callout))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(usage(item)).font(.edithText(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actions(
                item, current: current && !batchPending, deferred: deferred, awaiting: awaiting
            )
            .padding(.leading, compact ? UIScale.pt(44) : 0)
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(deferred ? 0.7 : 1)
        .hostOnboardingTile(highlighted: current && !batchPending)
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
        if item.needsRelaunch { parts.append("Takes effect after Edith relaunches") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func status(
        _ item: HostOnboardingPermission, deferred: Bool, awaiting: Bool
    ) -> some View {
        if awaiting {
            HostOnboardingBadge("Relaunch to finish", DashSkin.warn)
        } else if deferred {
            HostOnboardingBadge("Later", .secondary)
        } else if item.isRequired {
            HostOnboardingBadge("Required", DashSkin.accentDeep(dark))
        } else {
            HostOnboardingBadge("Optional", .secondary)
        }
    }

    @ViewBuilder private func actions(
        _ item: HostOnboardingPermission, current: Bool, deferred: Bool, awaiting: Bool
    ) -> some View {
        HStack(spacing: UIScale.pt(16)) {
            if item.canDefer {
                Button(deferred ? "Ask now" : "Ask me later") {
                    model.deferPermission(item.permission, !deferred)
                }
                .buttonStyle(.edith(.borderless))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding.defer.\(item.permission.rawValue)")
            }
            if awaiting {
                Button("Open System Settings") { model.openSettings(item.permission) }
                    .buttonStyle(.edith(.secondary))
                    .accessibilityIdentifier("onboarding.settings.\(item.permission.rawValue)")
            } else if !deferred {
                Button("Allow \(item.permission.displayName)") {
                    Task { await model.requestPermission(item.permission) }
                }
                .buttonStyle(.edith(current ? .primary : .secondary))
                .keyboardShortcut(current ? .defaultAction : nil)
                .disabled(model.permissions.requesting != nil || model.busy)
                .accessibilityIdentifier("onboarding.allow.\(item.permission.rawValue)")
            }
        }
        .fixedSize()
    }

    private func summaryRow(
        _ title: String, items: [HostOnboardingPermission], icon: EdithIcon, tint: Color,
        note: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            PageCapsLabel(title)
            WrapHStack(spacing: UIScale.pt(8), lineSpacing: UIScale.pt(8)) {
                ForEach(items) { item in
                    HStack(spacing: UIScale.pt(6)) {
                        EdithIconView(icon).foregroundStyle(tint)
                        Text(item.permission.displayName)
                    }
                    .font(.edithText(.caption)).fontWeight(.medium)
                    .padding(.horizontal, UIScale.pt(12))
                    .frame(minHeight: UIScale.pt(24))
                    .background(DashSkin.paper(dark), in: Capsule())
                    .overlay(Capsule().strokeBorder(DashSkin.line(dark)))
                    .fixedSize()
                    .help(usage(item))
                }
            }
            if let note {
                Text(note).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func relaunchBanner(_ batch: [HostPermission]) -> some View {
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(12)))
            : AnyLayout(HStackLayout(alignment: .center, spacing: UIScale.pt(16)))
        return layout {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                PageGuideBadge(icon: .refresh, size: 32)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(
                        "Relaunch once to finish \(batch.map(\.displayName).joined(separator: " and "))"
                    )
                    .font(.edithText(.headline)).fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Turn the switch on in System Settings first. Edith reopens on this step with your choices saved."
                    )
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Relaunch Edith") { model.relaunch() }
                .buttonStyle(.edith(.primary))
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                .padding(.leading, compact ? UIScale.pt(48) : 0)
                .accessibilityIdentifier("onboarding.relaunch")
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .hostOnboardingTile(highlighted: true)
    }
}
