import AppKit
import EdithKit
import SwiftUI

@MainActor
final class SocialWorkspaceWindow: NSObject, NSWindowDelegate {
    private static var windows: [SocialWorkspaceWindow] = []
    private let window: NSWindow
    private weak var model: SocialManagerModel?
    private let key: String

    private init(window: NSWindow, model: SocialManagerModel, key: String) {
        self.window = window
        self.model = model
        self.key = key
        super.init()
        window.delegate = self
    }

    static func open(_ key: String, from model: SocialManagerModel) {
        if let existing = windows.first(where: { $0.model === model && $0.key == key }) {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let account = model.account(key), model.ensureBrowser(account),
            let session = model.sessions[account.id]
        else { return }
        model.removePane(key)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = model.accountTitle(account)
        window.minSize = NSSize(width: 420, height: 360)
        window.contentView = NSHostingView(
            rootView: DetachedSocialBrowser(model: model, account: account, session: session))
        let controller = SocialWorkspaceWindow(window: window, model: model, key: key)
        windows.append(controller)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    static func reattach(_ key: String, to model: SocialManagerModel) {
        guard let controller = windows.first(where: { $0.model === model && $0.key == key }) else {
            return
        }
        controller.window.delegate = nil
        controller.window.contentView = nil
        controller.window.close()
        windows.removeAll { $0 === controller }
    }

    static func closeAll(for model: SocialManagerModel) {
        for controller in windows.filter({ $0.model === model }) {
            reattach(controller.key, to: model)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window.contentView = nil
        Self.windows.removeAll { $0 === self }
        if let model, let account = model.account(key) { model.open(account) }
    }
}

private struct DetachedSocialBrowser: View {
    let model: SocialManagerModel
    let account: SocialAccount
    let session: SocialBrowserSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.accountTitle(account)).font(.edithText(.headline))
                Spacer()
                Button("Return to workspace") { model.open(account) }
            }.padding(UIScale.pt(12))
            if session.pages.count > 1 {
                EdithSegmentedPicker(
                    "Website tabs",
                    selection: Binding(
                        get: { session.selectedPageID }, set: { session.selectedPageID = $0 }),
                    options: session.pages.map { Optional($0.id) },
                    label: { id in session.pages.first { $0.id == id }?.title ?? "Website" })
            }
            if let page = session.selectedPage {
                SocialBrowserContent(
                    model: model, account: account, page: page, website: session.website)
            }
        }
    }
}
