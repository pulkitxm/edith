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
    var initialHeight: Double? = nil
    var navigation: HostSettingsNavigation? = nil
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
        .frame(height: (contentHeight ?? initialHeight).map { CGFloat($0) })
        .pageTask(
            id: Request(
                version: marketplace.installed[extensionID]?.version, active: active,
                location: location,
                section: section, surface: surface, retry: retry, deliveryID: navigation?.delivery.id),
            active: eligible && presenter != nil, cancel: clear
        ) {
            guard let presenter else { return }
            let token = navigation?.delivery.id ?? UUID()
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
                if let navigation {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    guard let remote = loaded as? HostRemoteViewController else {
                        throw HostWorkerError.rejected
                    }
                    while !remote.isViewLoaded || remote.view.window == nil {
                        try Task.checkCancellation()
                        guard presentationID == token, navigation.delivery.pending,
                            remote.failure == nil, !remote.detached, ContinuousClock.now < deadline
                        else { throw HostWorkerError.rejected }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    guard let window = remote.view.window else { throw HostWorkerError.rejected }
                    try navigation.validate(window: window)
                    try await remote.waitUntilConnected(window: window)
                    try navigation.delivery.receive(
                        presentationID: token, extensionID: extensionID,
                        version: marketplace.installed[extensionID]?.version ?? "",
                        validate: { [weak remote] in
                            guard let remote, presentationID == token, controller === loaded,
                                remote.request.presentationID == token,
                                remote.request.extensionID == extensionID,
                                remote.request.location == location, remote.request.section == section,
                                marketplace.installed[extensionID]?.version == navigation.delivery.version,
                                marketplace.sessions.versions[extensionID] == navigation.delivery.version,
                                marketplace.surfaceAvailability.activeIDs.contains(extensionID),
                                !marketplace.pendingRemovalIDs.contains(extensionID),
                                !marketplace.sessions.pendingDisableIDs.contains(extensionID),
                                let owner = presenter as? HostRemoteContentPresenter,
                                owner.owns(remote, presentationID: token)
                            else { throw HostWorkerError.rejected }
                            try navigation.validate(window: window)
                            try remote.validateConnected(window: window)
                        })
                }
            } catch {
                navigation?.delivery.reject(error)
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
        let deliveryID: UUID?
    }
    private func clear() {
        navigation?.delivery.reject()
        presenter?.endPresentation(id: presentationID); controller = nil; error = nil
        contentHeight = nil; approvalRequired = false
    }
}

struct HostEmbeddedController: NSViewControllerRepresentable {
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
