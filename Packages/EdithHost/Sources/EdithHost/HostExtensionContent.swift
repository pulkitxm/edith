import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

typealias HostExtensionContentRequest = EdithHostCore.HostExtensionContentRequest

@MainActor protocol HostExtensionContentPresenting: AnyObject {
    func controller(for request: HostExtensionContentRequest) async throws -> NSViewController
    func endPresentation(id: UUID)
    func park(key: String, version: String, presentationID: UUID, controller: NSViewController)
    func unpark(key: String, version: String) -> (
        presentationID: UUID, controller: NSViewController
    )?
}

extension HostExtensionContentPresenting {
    func park(key: String, version: String, presentationID: UUID, controller: NSViewController) {
        endPresentation(id: presentationID)
    }
    func unpark(key: String, version: String) -> (
        presentationID: UUID, controller: NSViewController
    )? {
        nil
    }
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
    @State private var contentIdentity = ""
    @State private var presentationID = UUID()
    @State private var error: String?
    @State private var retry = 0
    @State private var contentHeight: Double?
    @State private var animatesHeight = false
    @State private var release: (@MainActor () -> Void)?
    @Environment(\.compactLayout) private var compact
    @Environment(\.windowVisible) private var visible
    @Environment(\.automaticViewActionsEnabled) private var automaticActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var active: Bool { marketplace.surfaceAvailability.activeIDs.contains(extensionID) }
    private var transitioning: Bool {
        marketplace.sessions.states[extensionID] == .starting
            || marketplace.sessions.states[extensionID] == .stopping
    }
    private var failure: String? {
        marketplace.failures[extensionID] ?? marketplace.sessions.failureReasons[extensionID]
    }
    private var eligible: Bool {
        !transitioning
            && (active
                || (location == "settings" && surface == nil
                    && marketplace.installed[extensionID] != nil
                    && !marketplace.pendingRemovalIDs.contains(extensionID)
                    && !marketplace.sessions.pendingDisableIDs.contains(extensionID)))
    }
    private var parkingKey: String? {
        guard navigation == nil else { return nil }
        if location == "main", surface == nil { return extensionID + "\u{0}" + (section ?? "") }
        guard location == "home", let surface,
            let encoded = try? Self.parkingEncoder.encode(surface)
        else { return nil }
        return extensionID + "\u{0}" + (section ?? "") + "\u{0}"
            + String(decoding: encoded, as: UTF8.self)
    }
    private static let parkingEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    private var installedVersion: String {
        (marketplace.installed[extensionID]?.version ?? "") + ":"
            + (marketplace.sessions.generations[extensionID]?.uuidString ?? "settings")
    }
    private var title: String {
        marketplace.entries.first { $0.id == extensionID }?.title ?? extensionID
    }
    private var inSettings: Bool { location == "settings" }
    @ViewBuilder private func loading(_ title: String) -> some View {
        if inSettings {
            PageLoading(state: .loading, title: title, layout: .form) { EmptyView() }
        } else if location == "main", surface == nil {
            PageScaffold {
                PageHeader { Text(self.title).skeletonized() }
            } content: {
                PageLoading(
                    state: .loading, title: title, layout: .list, showsSkeletonControls: false
                ) {
                    EmptyView()
                }
            }
        } else {
            PageLoading(state: .loading, title: title, layout: .list) { EmptyView() }
        }
    }

    var body: some View {
        Group {
            if let controller {
                HostEmbeddedController(controller: controller, compact: compact, visible: visible)
                    .frame(height: contentHeight.map { CGFloat($0) })
                    .clipped()
                    .animation(
                        animatesHeight && surface == nil
                            ? Motion.animation(Motion.glide, reduceMotion: reduceMotion) : nil,
                        value: contentHeight
                    )
                    .id(ObjectIdentifier(controller))
            } else if transitioning {
                loading("Preparing " + title)
            } else if !eligible {
                ContentUnavailableView {
                    Label(title, edith: .puzzle)
                } description: {
                    Text(
                        failure
                            ?? (marketplace.downloadedIDs.contains(extensionID)
                                ? "Enable this extension to open its page."
                                : "Download this extension to open its page."))
                } actions: {
                    if marketplace.installed[extensionID] != nil,
                        !marketplace.pendingRemovalIDs.contains(extensionID)
                    {
                        Button(failure == nil ? "Enable" : "Try again") {
                            Task { await marketplace.enable(id: extensionID) }
                        }.buttonStyle(.edith(.primary)).disabled(marketplace.isBusy(extensionID))
                    }
                    Button("Extensions", action: openMarketplace).buttonStyle(.edith(.secondary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if presenter == nil {
                ContentUnavailableView {
                    Label(title, edith: .puzzle)
                } description: {
                    Text("The extension view is not connected.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label(title, edith: .warning)
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { retry += 1 }.buttonStyle(.edith(.secondary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loading("Opening " + title)
            }
        }
        .frame(height: (contentHeight ?? initialHeight).map { CGFloat($0) })
        .task(
            id: Request(
                version: installedVersion, active: active,
                transitioning: transitioning,
                location: location,
                section: section, surface: surface, retry: retry,
                deliveryID: navigation?.delivery.id,
                presentable: eligible && presenter != nil && automaticActions)
        ) {
            release?()
            release = nil
            guard eligible, automaticActions, let presenter, !Task.isCancelled else { return }
            release = clear
            contentIdentity = installedVersion
            if let parkingKey,
                let parked = presenter.unpark(key: parkingKey, version: installedVersion)
            {
                presentationID = parked.presentationID
                if let remote = parked.controller as? HostRemoteViewController {
                    observe(remote)
                }
                controller = parked.controller
                return
            }
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
                    observe(remote)
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
                                remote.request.location == location,
                                remote.request.section == section,
                                marketplace.installed[extensionID]?.version
                                    == navigation.delivery.version,
                                marketplace.sessions.versions[extensionID]
                                    == navigation.delivery.version,
                                marketplace.surfaceAvailability.activeIDs.contains(extensionID),
                                !marketplace.pendingRemovalIDs.contains(extensionID),
                                !marketplace.sessions.pendingDisableIDs.contains(extensionID),
                                let owner = presenter as? HostRemoteContentPresenter,
                                owner.owns(remote, presentationID: token)
                            else { throw HostWorkerError.rejected }
                            try navigation.validate(window: window)
                            try owner.validateConnected(remote, window: window)
                        })
                }
            } catch {
                navigation?.delivery.reject(error)
                guard !Task.isCancelled else { return }
                presenter.endPresentation(id: token)
                controller = nil
                self.error =
                    (error as? LocalizedError)?.errorDescription
                    ?? "The extension page could not open. Try again."
            }
        }
        .onDisappear {
            clear()
            release = nil
        }
    }
    private struct Request: Equatable {
        let version: String; let active: Bool; let transitioning: Bool
        let location: String; let section: String?
        let surface: SurfaceSnapshotRequest?; let retry: Int
        let deliveryID: UUID?; let presentable: Bool
    }
    private func observe(_ remote: HostRemoteViewController) {
        animatesHeight = false
        remote.changed = { [weak remote] in
            animatesHeight = contentHeight != nil
            contentHeight = remote?.contentHeight
        }
        remote.retry = { retry += 1 }
        contentHeight = remote.contentHeight
    }

    private func clear() {
        navigation?.delivery.reject()
        if let parkingKey, let controller, error == nil {
            presenter?.park(
                key: parkingKey, version: contentIdentity, presentationID: presentationID,
                controller: controller)
        } else {
            presenter?.endPresentation(id: presentationID)
        }
        controller = nil; error = nil
        contentHeight = nil; animatesHeight = false
    }
}

struct HostEmbeddedController: NSViewControllerRepresentable {
    let controller: NSViewController
    let compact: Bool
    let visible: Bool
    func makeNSViewController(context: Context) -> NSViewController { controller }
    func updateNSViewController(_ controller: NSViewController, context: Context) {
        (controller as? HostRemoteViewController)?.apply(compact: compact, visible: visible)
    }
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsViewController controller: NSViewController,
        context: Context
    ) -> CGSize? {
        guard let remote = controller as? HostRemoteViewController else { return nil }
        let width = proposal.width ?? controller.view.bounds.width
        if remote.state.width == 0, width.isFinite, width > 0 {
            remote.apply(compact: compact, visible: visible, width: width)
        }
        guard let height = remote.contentHeight else { return nil }
        return CGSize(width: width, height: height)
    }
}
