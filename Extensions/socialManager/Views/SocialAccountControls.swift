import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

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
        SocialPictureActions(name: account.name, hasPicture: account.avatarFilename != nil) { url in
            do { try model.importAvatar(account, from: url) } catch {
                model.message = error.localizedDescription
            }
        } remove: {
            model.removeAvatar(account)
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
            Menu("Merge Into") {
                ForEach(model.tabs.filter { $0.id != tab.id }) { other in
                    Button(model.title(other)) {
                        model.merge(tab.id.uuidString, into: other.id.uuidString)
                    }
                }
            }.disabled(model.tabs.count < 2)
            Button("Separate into tabs") {
                model.select(tab); model.separate()
            }
        }
        if tab.layout.paneCount == 1 {
            Button("Open in new window") { SocialWorkspaceWindow.open(tab.focused, from: model) }
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
