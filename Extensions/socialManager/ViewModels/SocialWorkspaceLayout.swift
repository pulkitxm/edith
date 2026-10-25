import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

extension SocialManagerModel: WorkspaceLayoutControls {
    var layoutAnimation: Animation? {
        guard animatesLayout else { return nil }
        return Motion.animation(
            Motion.glide, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func templates(for count: Int) -> [HerdrLayoutTemplate] {
        HerdrLayoutTemplate.all(for: count, saved: savedArrangements)
    }
    func currentTemplate(of tabID: String) -> HerdrLayoutTemplate? {
        tabs.first { $0.id.uuidString == tabID }.flatMap {
            HerdrLayoutTemplate.matching($0.layout, saved: savedArrangements)
        }
    }

    func arrange(_ tabID: String, as template: HerdrLayoutTemplate) {
        changeTab(tabID) { tab in
            let ids = [tab.focused] + tab.layout.panes.filter { $0 != tab.focused }
            guard let layout = template.layout(ids) else { return }
            tab.layout = layout
            tab.zoomed = nil
        }
    }

    func rotate(_ tabID: String) {
        changeTab(tabID) {
            $0.layout = $0.layout.rotated(); $0.zoomed = nil
        }
    }
    func mirror(_ tabID: String, _ axis: SplitAxis) {
        changeTab(tabID) {
            $0.layout = $0.layout.mirrored(axis); $0.zoomed = nil
        }
    }
    func equalize(_ tabID: String) {
        changeTab(tabID) {
            $0.layout = $0.layout.equalized(); $0.zoomed = nil
        }
    }
    func separate(_ tabID: String) {
        guard let tab = tabs.first(where: { $0.id.uuidString == tabID }) else { return }
        let accounts = tab.layout.panes.compactMap(account)
        let replacements = accounts.map { SocialWorkspaceTab(account: $0) }
        modifyTabs {
            guard let index = $0.firstIndex(where: { $0.id == tab.id }) else { return }
            $0.replaceSubrange(index...index, with: replacements)
        }
        if let focused = replacements.first(where: { $0.focused == tab.focused }) {
            select(focused)
        }
    }

    @discardableResult
    func saveArrangement(of tabID: String, named name: String) -> HerdrSavedArrangement? {
        guard let tab = tabs.first(where: { $0.id.uuidString == tabID }), tab.layout.paneCount > 1
        else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = HerdrSavedArrangement(
            name: name.isEmpty ? "Layout \(savedArrangements.count + 1)" : name, layout: tab.layout)
        modifyArrangements {
            $0.removeAll { $0.shape.geometryMatches(saved.shape, tolerance: 0.001) }
            $0.insert(saved, at: 0)
        }
        return saved
    }

    func deleteArrangement(_ id: UUID) { modifyArrangements { $0.removeAll { $0.id == id } } }

    func merge(_ source: String, into target: String) {
        drop(.tab(source), on: .intoTab(target))
    }

    func gatherAll(into target: String) {
        let sources = tabs.map { $0.id.uuidString }.filter { $0 != target }
        for source in sources { merge(source, into: target) }
    }

    private func changeTab(_ id: String, _ change: (inout SocialWorkspaceTab) -> Void) {
        modifyTabs {
            guard let index = $0.firstIndex(where: { $0.id.uuidString == id }) else { return }
            change(&$0[index])
        }
    }
}

struct SocialWorkspaceLayout: View {
    let model: SocialManagerModel
    let tab: SocialWorkspaceTab
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        WorkspaceLayoutPopover(store: model, tab: tab.interactionTab, itemName: "account") {
            WorkspaceLayoutSection(
                title: tab.layout.paneCount > 1 ? "Add to This Tab" : "Open Side by Side"
            ) {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    ForEach(model.tabs.filter { $0.id != tab.id }) { other in
                        Button {
                            withAnimation(model.layoutAnimation) {
                                model.merge(other.id.uuidString, into: tab.id.uuidString)
                            }
                        } label: {
                            HStack(spacing: UIScale.pt(6)) {
                                WorkspacePaneMarks(
                                    panes: other.layout.panes.compactMap(model.paneIdentity),
                                    dark: scheme == .dark)
                                Text(model.title(other)).font(.edithText(.subheadline)).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "plus.rectangle.on.rectangle").font(
                                    .edithText(.caption))
                            }
                            .padding(.horizontal, UIScale.pt(8)).padding(.vertical, UIScale.pt(6))
                            .widgetBar(
                                cornerRadius: 7, fill: DashSkin.paper2(scheme == .dark),
                                stroke: DashSkin.line(scheme == .dark))
                        }.buttonStyle(.edith(.borderless))
                            .help("Bring this tab in beside the current accounts")
                    }
                    HStack(spacing: UIScale.pt(8)) {
                        if model.tabs.count > 1 {
                            Button("Gather All Tabs") {
                                withAnimation(model.layoutAnimation) {
                                    model.gatherAll(into: tab.id.uuidString)
                                }
                            }.buttonStyle(.edith(.secondary))
                        }
                        Menu("Add Account") {
                            ForEach(model.catalog.profiles) { profile in
                                Menu(profile.name) {
                                    ForEach(
                                        model.accounts(in: profile).filter {
                                            !tab.layout.contains($0.id.uuidString)
                                        }
                                    ) { account in
                                        Button(
                                            "\(model.platform(for: account)?.name ?? "Website"): \(account.name)"
                                        ) {
                                            model.select(tab)
                                            withAnimation(model.layoutAnimation) {
                                                model.open(account, beside: true)
                                            }
                                        }
                                    }
                                    Button("Open email beside accounts") {
                                        model.select(tab); model.openEmail(profile, beside: true)
                                    }
                                }
                            }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
        }
    }
}
