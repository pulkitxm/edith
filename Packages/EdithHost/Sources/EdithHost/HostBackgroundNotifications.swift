import AppKit
import EdithHostCore
import Observation
import SwiftUI

@MainActor @Observable final class HostBackgroundNotifications {
    private(set) var controller: NSViewController?
    private(set) var failure: String?
    private let presenter: any HostExtensionContentPresenting
    private let states: @MainActor () async throws -> [HostCLIProviderState]
    private var presentationID: UUID?
    private var owner: HostBackgroundOwnerPin?

    init(
        presenter: any HostExtensionContentPresenting,
        states: @escaping @MainActor () async throws -> [HostCLIProviderState]
    ) {
        self.presenter = presenter
        self.states = states
    }

    func refresh() async {
        cancel()
        let token = UUID()
        presentationID = token
        do {
            let before = try await states()
            try Task.checkCancellation()
            guard let state = before.first(where: { $0.id == "herdr" }) else {
                throw HostCLIError.unavailable
            }
            let pin = try HostBackgroundOwnerPin(state: state)
            guard presentationID == token else { return }
            let loaded = try await presenter.controller(
                for: .init(
                    extensionID: "herdr", location: "settings", section: "backgroundAgent",
                    presentationID: token))
            let after = try await states()
            try Task.checkCancellation()
            guard presentationID == token, pin.accepts(after) else {
                presenter.endPresentation(id: token)
                return
            }
            owner = pin
            controller = loaded
        } catch {
            presenter.endPresentation(id: token)
            guard !Task.isCancelled, presentationID == token else { return }
            controller = nil
            failure =
                "Coding agent notification settings could not open. Check the Herdr extension."
        }
    }

    func current(version: String?, runtimeVersion: String?, pid: Int32?, active: Bool) -> Bool {
        guard let owner, controller != nil else { return false }
        return active && owner.process.isAlive && version == owner.state.version
            && runtimeVersion == owner.state.version && pid == owner.state.processIdentifier
    }

    func cancel() {
        if let presentationID { presenter.endPresentation(id: presentationID) }
        presentationID = nil
        owner = nil
        controller = nil
        failure = nil
    }
}

struct HostBackgroundNotificationSection: View {
    let marketplace: HostMarketplace
    @State private var model: HostBackgroundNotifications
    @Environment(\.compactLayout) private var compact
    @Environment(\.windowVisible) private var visible

    init(marketplace: HostMarketplace, presenter: any HostExtensionContentPresenting) {
        self.marketplace = marketplace
        let gateway = HostCLIGateway(marketplace: marketplace)
        _model = State(
            initialValue: HostBackgroundNotifications(
                presenter: presenter,
                states: {
                    guard marketplace.sessions.activeIDs.contains("herdr"),
                        let selected = marketplace.installed["herdr"]?.version,
                        marketplace.sessions.versions["herdr"] == selected
                    else { return [] }
                    return try await HostCLIProviderRegistry.states {
                        try await gateway.execute($0)
                    }
                }))
    }

    private var active: Bool {
        marketplace.installed["herdr"] != nil
            && marketplace.sessions.activeIDs.contains("herdr")
            && marketplace.installed["herdr"]?.version == marketplace.sessions.versions["herdr"]
            && !marketplace.pendingRemovalIDs.contains("herdr")
            && !marketplace.sessions.pendingDisableIDs.contains("herdr")
    }

    private var identity: String {
        "\(marketplace.installed["herdr"]?.version ?? ""):"
            + "\(marketplace.sessions.versions["herdr"] ?? ""):"
            + "\(marketplace.sessions.processIdentifiers["herdr"] ?? 0):\(active)"
    }

    var body: some View {
        Group {
            if model.current(
                version: marketplace.installed["herdr"]?.version,
                runtimeVersion: marketplace.sessions.versions["herdr"],
                pid: marketplace.sessions.processIdentifiers["herdr"], active: active),
                let controller = model.controller
            {
                HostEmbeddedController(controller: controller, compact: compact, visible: visible)
            } else if active, let failure = model.failure {
                Section("Coding agent notifications") {
                    Text(failure).settingsCaption()
                    Button("Try again") { Task { await model.refresh() } }
                }
            }
        }
        .pageTask(id: identity, active: active, cancel: model.cancel) { await model.refresh() }
        .onDisappear(perform: model.cancel)
    }
}
