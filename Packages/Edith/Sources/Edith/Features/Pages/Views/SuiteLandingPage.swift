import EdithKit
import SwiftUI

struct SuiteLandingPage: View {
    let suite: SuiteDescriptor
    @State private var grantedPermissions: [ExtensionPermission: Bool] = [:]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    private var dark: Bool { scheme == .dark }

    private var abilities: [ExtensionRegistryEntry] {
        SuiteRegistry.abilities(in: suite.id)
    }

    private var groups: [(title: String, abilities: [ExtensionRegistryEntry])] {
        SuiteLandingGroups.groups(for: suite.id, abilities: abilities)
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            PageHeader(
                suite.title,
                accessory: {
                    Text(suite.subtitle)
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(.secondary)
                })
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                            if groups.count > 1 {
                                Text(group.title.uppercased())
                                    .font(DashSkin.mono(10, weight: .semibold))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                            }
                            VStack(spacing: 0) {
                                ForEach(Array(group.abilities.enumerated()), id: \.element.id) {
                                    index, ability in
                                    if index > 0 { Divider().opacity(0.5) }
                                    SuiteAbilityRow(entry: ability, dark: dark)
                                }
                            }
                            .background(
                                DashSkin.paper2(dark),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: UIScale.pt(12))
                                    .strokeBorder(DashSkin.line(dark)))
                        }
                    }
                    SuiteHostNote(suite: suite, abilities: abilities, dark: dark)
                }
                .pageContent(compact)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashSkin.paper(dark))
        .navigationTitle(suite.title)
        .onAppear {
            guard automaticActionsEnabled else { return }
            grantedPermissions = MainPermissionOperations.center.grantedPermissions()
        }
    }
}

enum SuiteLandingGroups {
    static func groups(
        for suite: SuiteID, abilities: [ExtensionRegistryEntry]
    ) -> [(title: String, abilities: [ExtensionRegistryEntry])] {
        guard suite == .desk else { return [("Abilities", abilities)] }
        let pickers = ["clipboard", "emoji", "colorPicker"]
        return [
            ("Pickers", abilities.filter { pickers.contains($0.id) }),
            ("Stage", abilities.filter { !pickers.contains($0.id) }),
        ].filter { !$0.1.isEmpty }
    }
}

private struct SuiteAbilityRow: View {
    let entry: ExtensionRegistryEntry
    let dark: Bool
    @ExtensionEnablementStorage private var enabled: Bool
    @StateObject private var lidAwakeOperations = LidAwakeOperationModel()
    @State private var hovering = false

    init(entry: ExtensionRegistryEntry, dark: Bool) {
        self.entry = entry
        self.dark = dark
        _enabled = ExtensionEnablementStorage(entry: entry)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { newValue in
                if entry.defaultsKey == LidAwakeState.enabledKey, !newValue {
                    lidAwakeOperations.perform(.disableExtension)
                    return
                }
                _ = ExtensionModalCoordinator(entry: entry, mutationCenter: .application)
                    .setEnabled(newValue)
            })
    }

    private var destination: MainDestination? {
        NavigationCatalog.pages
            .first { $0.abilityIDs == [entry.id] && $0.parentID != nil }
            .flatMap { MainDestination(rawValue: $0.id) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: UIScale.pt(11)) {
            AppGlyph(entry, size: UIScale.pt(15), weight: .medium)
                .foregroundStyle(enabled ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(20))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                HStack(spacing: UIScale.pt(6)) {
                    Text(entry.title)
                        .font(.system(size: UIScale.pt(13), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                    Text(entry.host.title.lowercased())
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .padding(.horizontal, UIScale.pt(5))
                        .padding(.vertical, UIScale.pt(1))
                        .background(DashSkin.inkFaint(dark).opacity(0.1), in: Capsule())
                }
                Text(entry.subtitle)
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: UIScale.pt(12))
            if let destination, enabled {
                Button("Open") { SectionWindow.focusOrSelect(destination) }
                    .buttonStyle(.edith(.toolbar))
                    .opacity(hovering ? 1 : 0.55)
            }
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DashSkin.accent(dark))
                .disabled(
                    entry.defaultsKey == LidAwakeState.enabledKey && lidAwakeOperations.applying
                )
                .accessibilityLabel("\(entry.title) enabled")
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(11))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct SuiteHostNote: View {
    let suite: SuiteDescriptor
    let abilities: [ExtensionRegistryEntry]
    let dark: Bool

    private var hosts: String {
        let ordered = AbilityHost.allCases.filter { host in
            abilities.contains { $0.host == host }
        }
        return ordered.map { $0.title.lowercased() }.joined(separator: " · ")
    }

    private var tools: String {
        let used = Set(abilities.flatMap { $0.requiredToolIDs + $0.optionalToolIDs })
        return Set(suite.toolIDs).union(used).sorted().joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text("hosts: \(hosts)")
            if !tools.isEmpty { Text("tools: \(tools)") }
            if suite.requiresFleet { Text("requires: Fleet") }
        }
        .font(DashSkin.mono(10))
        .foregroundStyle(DashSkin.inkFaint(dark))
    }
}
