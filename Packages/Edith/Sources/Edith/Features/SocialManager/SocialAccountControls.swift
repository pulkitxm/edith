import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct SocialAccountAvatar: View {
    let model: SocialManagerModel
    let account: SocialAccount
    var size: CGFloat = 42
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let image = model.avatars[account.id] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(account.initials).font(.edithText(.caption).weight(.semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DashSkin.accent(scheme == .dark).opacity(0.15))
            }
        }
        .frame(width: UIScale.pt(size), height: UIScale.pt(size)).clipShape(Circle())
        .accessibilityLabel("Picture for \(account.name)")
    }
}

struct SocialEmailMenu: View {
    let model: SocialManagerModel
    let profile: SocialProfile

    var body: some View {
        Menu {
            Button("Open email in tab") { model.openEmail(profile) }
            Button("Open email on the right") { model.openEmail(profile, beside: true) }
            Button("Open email below") { model.openEmail(profile, beside: true, side: .bottom) }
        } label: {
            Label("Email", systemImage: "envelope")
        }
        .help(profile.email ?? "Open this profile's saved Gmail session")
        .disabled(model.busy)
    }
}

struct SocialAccountActions: View {
    let model: SocialManagerModel
    let account: SocialAccount

    var body: some View {
        Button("Open in tab") { model.openInNewTab(account) }
        Button("Open on the right") { model.open(account, beside: true) }
        Button("Open below") { model.open(account, beside: true, side: .bottom) }
        if let profile = model.profile(for: account) {
            SocialEmailMenu(model: model, profile: profile)
        }
        if !model.tabs.isEmpty {
            Menu("Move to tab") {
                ForEach(model.tabs.filter { !$0.layout.contains(account.id.uuidString) }) { tab in
                    Button(model.title(tab)) { model.moveToTab(account, tabID: tab.id) }
                }
            }
        }
        if account.id != account.profileID {
            Menu("Move to profile") {
                ForEach(model.catalog.profiles.filter { $0.id != account.profileID }) { profile in
                    Button(profile.name) { model.moveAccount(account, to: profile) }
                }
            }
        }
        Divider()
        Button("Edit account…") { model.editingAccount = account }
        Button(account.avatarFilename == nil ? "Choose picture…" : "Replace picture…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.message = "Choose a picture for \(account.name)"
            guard let window = NSApp.keyWindow else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do { try model.importAvatar(account, from: url) } catch {
                    model.message = error.localizedDescription
                }
            }
        }
        if account.avatarFilename != nil {
            Button("Remove picture") { model.removeAvatar(account) }
        }
        Divider()
        Button("Clear login session…", role: .destructive) { model.clearingAccount = account }
        Button("Remove account…", role: .destructive) { model.removingAccount = account }
    }
}

struct SocialTabActions: View {
    let model: SocialManagerModel
    let tab: SocialWorkspaceTab

    var body: some View {
        Button("Move tab left") { model.shiftTab(tab.id, by: -1) }
            .disabled(model.tabs.first?.id == tab.id)
        Button("Move tab right") { model.shiftTab(tab.id, by: 1) }
            .disabled(model.tabs.last?.id == tab.id)
        if tab.layout.paneCount > 1 {
            Button("Separate into tabs") {
                model.select(tab); model.separate()
            }
        }
        Divider()
        Button("Close tab") { model.closeTab(tab.id) }
        Button("Close other tabs") { model.closeOtherTabs(tab.id) }
            .disabled(model.tabs.count < 2)
        Button("Close tabs to the right") { model.closeTabsAfter(tab.id) }
            .disabled(model.tabs.last?.id == tab.id)
        Button("Reopen closed tab") { model.reopenClosedTab() }
            .disabled(model.recentlyClosed.isEmpty)
    }
}
