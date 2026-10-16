import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

struct NotchQuickActionRequest: Codable, Sendable {
    let identity: NotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let tile: SurfaceTile
    var providerID: String? = nil
    var actionID: String? = nil
    var session: NotchLidAwakeSession? = nil
}

struct NotchQuickActionState: Codable, Sendable {
    let snapshots: [String: SurfaceSnapshot]
    let errors: [String: String]
}

enum NotchLidAwakeSession: String, CaseIterable, Codable, Identifiable, Sendable {
    case indefinite, fifteenMinutes, thirtyMinutes, oneHour, twoHours, untilLidReopens
    var id: String { rawValue }
    var title: String {
        switch self {
        case .indefinite: "Indefinitely"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .untilLidReopens: "Until lid reopens"
        }
    }
}

extension NotchPanelEngine {
    func quickActions(_ request: NotchQuickActionRequest) async throws -> Data {
        try validateChromeIdentity(
            request.identity, displayID: request.displayID, presentationID: request.presentationID)
        guard let controller, request.tile.widget == .actions,
            controller.visibleSurfaceLayout.visible.contains(request.tile)
        else { throw ExtensionPeerError.invalidRequest }
        let allowed = [
            "system": ["cleanKeys", "stopCleaning"], "keepAwake": ["enable", "disable"],
            "lidAwake": ["on", "off"], "presenter": ["start", "stop"], "colorPicker": ["pick"],
        ]
        if let providerID = request.providerID, let actionID = request.actionID {
            guard controller.activeIDs.contains(providerID),
                allowed[providerID]?.contains(actionID) == true,
                request.tile.showActions
            else { throw ExtensionPeerError.invalidRequest }
            let tile =
                providerID == "colorPicker" ? SurfaceTile(.ability("colorPicker")) : request.tile
            guard !controller.privacy.hides(tile.widget) else {
                throw ExtensionPeerError.unavailable
            }
            if providerID == "colorPicker" { controller.collapseNow() }
            do {
                if providerID == "lidAwake", actionID == "on", let session = request.session {
                    struct Input: Encodable { let session: NotchLidAwakeSession }
                    let version = controller.context.activeVersions[providerID]
                    let channel = controller.context.sharedState
                    let endpoint = try ExtensionPeerEndpoint(
                        namespace: channel.namespace, owner: providerID,
                        directory: channel.root.appendingPathComponent("Commands"))
                    _ = try await endpoint.invoke(
                        "lidAwake.on", payload: JSONEncoder().encode(Input(session: session)),
                        timeout: 30)
                    try Task.checkCancellation()
                    guard controller.isRunning,
                        controller.context.activeVersions[providerID] == version
                    else { throw CancellationError() }
                } else {
                    let snapshot = try await controller.requests.snapshot(
                        providerID: providerID, target: .notch, tile: tile)
                    _ = try await controller.requests.perform(
                        providerID: providerID, target: .notch, tile: tile, snapshot: snapshot,
                        actionID: actionID)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                controller.collapseNow()
                controller.presentFailure(Self.quickActionFailureAlert(providerID, error))
                return try await quickActionState(request, controller: controller, allowed: allowed)
            }
            if providerID != "colorPicker", providerID != "lidAwake" { controller.collapseNow() }
        } else if request.providerID != nil || request.actionID != nil || request.session != nil {
            throw ExtensionPeerError.invalidRequest
        }
        return try await quickActionState(request, controller: controller, allowed: allowed)
    }

    static func quickActionFailureAlert(_ providerID: String, _ error: Error) -> NotchAlert {
        let title: String
        switch providerID {
        case "lidAwake": title = "Lid Awake failed"
        case "music": title = "Music action failed"
        default: title = "Quick action failed"
        }
        return NotchAlert(
            id: providerID == "lidAwake" ? "lid-awake.action" : providerID + ".action",
            icon: "exclamationmark.circle.fill", tint: "#e0664f", title: title,
            subtitle: error.localizedDescription, priority: .high,
            autoHide: providerID == "lidAwake" ? 5 : 3)
    }

    private func quickActionState(
        _ request: NotchQuickActionRequest, controller: NotchShelfController,
        allowed: [String: [String]]
    ) async throws -> Data {
        var snapshots: [String: SurfaceSnapshot] = [:]
        var errors: [String: String] = [:]
        for provider in allowed.keys.sorted() where controller.activeIDs.contains(provider) {
            let tile =
                provider == "colorPicker" ? SurfaceTile(.ability("colorPicker")) : request.tile
            do {
                snapshots[provider] = try await controller.requests.snapshot(
                    providerID: provider, target: .notch, tile: tile)
            } catch is CancellationError { throw CancellationError() } catch {
                errors[provider] = String(error.localizedDescription.prefix(256))
            }
        }
        try validateChromeIdentity(
            request.identity, displayID: request.displayID, presentationID: request.presentationID)
        return try JSONEncoder().encode(NotchQuickActionState(snapshots: snapshots, errors: errors))
    }
}

@MainActor enum NotchQuickActionCache {
    static var last = NotchQuickActionState(snapshots: [:], errors: [:])
}

struct NotchQuickActionsView: View {
    let client: NotchChromeClient
    let tile: SurfaceTile
    @State private var state = NotchQuickActionCache.last
    @State private var optimistic: [String: Bool] = [:]
    @State private var pendingLidAwakeSession: NotchLidAwakeSession?
    @State private var task: Task<Void, Never>?
    @Environment(\.surfacePresentation) private var presentation
    private func isActive(_ provider: String, stop: String) -> Bool {
        optimistic[provider]
            ?? (state.snapshots[provider]?.actions.contains { $0.id == stop } == true)
    }
    private var activeAwake: Bool { isActive("keepAwake", stop: "disable") }
    private var activeLid: Bool { isActive("lidAwake", stop: "off") }
    private var activePresenter: Bool { isActive("presenter", stop: "stop") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if tile.showTitle {
                Label(tile.displayTitle, systemImage: "bolt").font(
                    .edithText(.caption).weight(.semibold))
            }
            SurfaceControlLayout(minimumWidth: 110, cellHeight: tile.dense ? 62 : 82) {
                if client.activeIDs.contains("system") {
                    actionTile("keyboard", "Clean keys", active: false) {
                        perform("system", "cleanKeys")
                    }
                }
                if client.activeIDs.contains("keepAwake") {
                    actionTile(
                        activeAwake ? "moon.zzz.fill" : "moon.zzz", "Keep awake",
                        active: activeAwake
                    ) { perform("keepAwake", activeAwake ? "disable" : "enable") }
                }
                if client.activeIDs.contains("lidAwake") {
                    actionTile("laptopcomputer", "Lid awake", active: activeLid) {
                        if activeLid {
                            perform("lidAwake", "off")
                        } else {
                            pendingLidAwakeSession = .indefinite
                        }
                    }.contextMenu {
                        ForEach(NotchLidAwakeSession.allCases) { session in
                            Button(session.title) { pendingLidAwakeSession = session }
                        }
                        if activeLid {
                            Divider(); Button("Turn off") { perform("lidAwake", "off") }
                        }
                    }
                }
                if client.activeIDs.contains("presenter") {
                    actionTile("person.wave.2", "Presenter", active: activePresenter) {
                        perform("presenter", activePresenter ? "stop" : "start")
                    }
                }
                if client.activeIDs.contains("colorPicker") {
                    actionTile("eyedropper", "Pick color", active: false) {
                        perform("colorPicker", "pick")
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(presentation?.padding ?? 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                .white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: presentation?.cornerRadius ?? 12)
            )
            .alert(
                "Keep running with the lid closed?",
                isPresented: Binding(
                    get: { pendingLidAwakeSession != nil },
                    set: { if !$0 { pendingLidAwakeSession = nil } })
            ) {
                Button("Turn On") {
                    guard let session = pendingLidAwakeSession else { return }
                    pendingLidAwakeSession = nil
                    perform("lidAwake", "on", session: session)
                }
                Button("Cancel", role: .cancel) { pendingLidAwakeSession = nil }
            } message: {
                Text("The Mac will keep drawing power and shedding heat. Do not put it in a bag.")
            }
            .pageTask(id: client.snapshot?.revision, active: client.isExpanded) {
                if let fresh = try? await client.quickActions(tile: tile) {
                    state = fresh
                    NotchQuickActionCache.last = fresh
                    optimistic = [:]
                }
            }.onDisappear {
                task?.cancel(); task = nil
            }
    }

    private func actionTile(
        _ icon: String, _ title: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if tile.shows("icons") {
                    Image(systemName: icon).font(.system(size: 17, weight: .medium))
                }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if tile.showDetails, !tile.dense, tile.shows("descriptions") {
                    Text(detail(title)).font(.edithText(.caption2))
                        .foregroundStyle(active ? .black.opacity(0.65) : .secondary)
                        .lineLimit(2).multilineTextAlignment(.center)
                }
            }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(active ? Color.black : Color.white.opacity(0.85))
                .background(
                    active ? tile.highlightColor : Color.white.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.edith(.borderless)).disabled(!tile.showActions)
    }
    private func detail(_ title: String) -> String {
        switch title {
        case "Clean keys": "Lock the keyboard"
        case "Keep awake": "Prevent sleep"
        case "Lid awake": "Run with the lid closed"
        case "Presenter": "Blur sensitive content"
        default: "Pick a screen color"
        }
    }
    private func perform(
        _ providerID: String, _ actionID: String, session: NotchLidAwakeSession? = nil
    ) {
        switch (providerID, actionID) {
        case ("keepAwake", "enable"), ("presenter", "start"), ("lidAwake", "on"):
            optimistic[providerID] = true
        case ("keepAwake", "disable"), ("presenter", "stop"), ("lidAwake", "off"):
            optimistic[providerID] = false
        default: break
        }
        let previous = task
        task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            if let fresh = try? await client.quickActions(
                tile: tile, providerID: providerID, actionID: actionID, session: session)
            {
                state = fresh
                NotchQuickActionCache.last = fresh
            }
            optimistic[providerID] = nil
        }
    }
}
