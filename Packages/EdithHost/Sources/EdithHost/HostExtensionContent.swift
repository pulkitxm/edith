import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
@preconcurrency import ExtensionKit
import SwiftUI

typealias HostExtensionContentRequest = EdithHostCore.HostExtensionContentRequest

@MainActor protocol HostExtensionContentPresenting: AnyObject {
    func controller(for request: HostExtensionContentRequest) async throws -> NSViewController
    func endPresentation(id: UUID)
}

struct HostExtensionContent: View {
    let marketplace: HostMarketplace
    let extensionID: String
    let location: String
    var section: String? = nil
    let presenter: (any HostExtensionContentPresenting)?
    let openMarketplace: () -> Void
    var surface: SurfaceSnapshotRequest? = nil
    @State private var controller: NSViewController?
    @State private var presentationID = UUID()
    @State private var error: String?
    @State private var retry = 0
    @State private var browser = false
    @State private var approvalRequired = false
    @State private var contentHeight: Double?
    @Environment(\.compactLayout) private var compact
    @Environment(\.windowVisible) private var visible

    private var active: Bool { marketplace.surfaceAvailability.activeIDs.contains(extensionID) }
    private var eligible: Bool {
        active
            || (location == "settings" && surface == nil
                && marketplace.installed[extensionID] != nil
                && !marketplace.pendingRemovalIDs.contains(extensionID)
                && !marketplace.sessions.pendingDisableIDs.contains(extensionID))
    }
    private var title: String {
        marketplace.entries.first { $0.id == extensionID }?.title ?? extensionID
    }
    var body: some View {
        Group {
            if let controller {
                HostEmbeddedController(controller: controller, compact: compact, visible: visible)
                    .frame(height: contentHeight.map { CGFloat($0) })
            } else if !eligible {
                ContentUnavailableView {
                    Label(title, systemImage: "puzzlepiece.extension")
                } description: {
                    Text(
                        marketplace.downloadedIDs.contains(extensionID)
                            ? "Enable this extension to open its page."
                            : "Download this extension to open its page.")
                } actions: {
                    Button("Extensions", action: openMarketplace).buttonStyle(.edith(.secondary))
                }
            } else if presenter == nil {
                ContentUnavailableView(
                    title, systemImage: "puzzlepiece.extension",
                    description: Text("The extension view is not connected."))
            } else if let error {
                ContentUnavailableView {
                    Label(title, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    if approvalRequired {
                        Button("Extension settings") { browser = true }.buttonStyle(
                            .edith(.secondary))
                    }
                    Button("Try again") { retry += 1 }.buttonStyle(.edith(.secondary))
                }
            } else {
                PageLoading(state: .loading, title: "Opening " + title) { EmptyView() }
            }
        }
        .pageTask(
            id: Request(
                version: marketplace.installed[extensionID]?.version, active: active,
                location: location,
                section: section, surface: surface, retry: retry),
            active: eligible && presenter != nil, cancel: clear
        ) {
            guard let presenter else { return }
            let token = UUID()
            presentationID = token
            do {
                let loaded = try await presenter.controller(
                    for: .init(
                        extensionID: extensionID, location: location, section: section,
                        presentationID: token, surface: surface))
                guard !Task.isCancelled, presentationID == token else {
                    presenter.endPresentation(id: token); return
                }
                if let remote = loaded as? HostRemoteViewController {
                    remote.changed = { [weak remote] in contentHeight = remote?.contentHeight }
                    contentHeight = remote.contentHeight
                }
                controller = loaded
            } catch {
                guard !Task.isCancelled else { return }
                approvalRequired = error is HostRemoteAvailabilityError
                self.error =
                    approvalRequired
                    ? "Approve this extension in macOS extension settings to open its interface."
                    : "The extension page could not open."
            }
        }
        .onDisappear(perform: clear)
        .edithSheet(isPresented: $browser, onDismiss: { retry += 1 }) {
            HostExtensionBrowser().frame(width: 560, height: 340)
        }
    }
    private struct Request: Equatable {
        let version: String?; let active: Bool; let location: String; let section: String?
        let surface: SurfaceSnapshotRequest?; let retry: Int
    }
    private func clear() {
        presenter?.endPresentation(id: presentationID); controller = nil; error = nil
        contentHeight = nil; approvalRequired = false
    }
}

private struct HostEmbeddedController: NSViewControllerRepresentable {
    let controller: NSViewController
    let compact: Bool
    let visible: Bool
    func makeNSViewController(context: Context) -> NSViewController { controller }
    func updateNSViewController(_ controller: NSViewController, context: Context) {
        (controller as? HostRemoteViewController)?.apply(
            compact: compact, visible: visible, width: controller.view.bounds.width)
    }
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsViewController controller: NSViewController,
        context: Context
    ) -> CGSize? {
        guard let remote = controller as? HostRemoteViewController else { return nil }
        remote.apply(
            compact: compact, visible: visible,
            width: proposal.width ?? controller.view.bounds.width)
        guard let height = remote.contentHeight else { return nil }
        return CGSize(width: proposal.width ?? controller.view.bounds.width, height: height)
    }
}

struct HostExtensionBrowser: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> EXAppExtensionBrowserViewController {
        let browser = EXAppExtensionBrowserViewController()
        browser.preferredContentSize = NSSize(width: 560, height: 340)
        return browser
    }
    func updateNSViewController(_ controller: EXAppExtensionBrowserViewController, context: Context)
    {}
}
