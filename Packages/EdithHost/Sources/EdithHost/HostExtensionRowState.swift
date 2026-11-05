import EdithHostCore
import Foundation

struct HostExtensionRowState: Equatable {
    enum Tone: Equatable {
        case neutral, positive, attention, failure
    }

    enum Stage: Equatable {
        case notInstalled, downloading, verifying, starting, ready, installed, updateAvailable,
            failed, pending, unavailable
    }

    enum Action: Equatable {
        case open, download, update, retry, retryDisable, remove

        var title: String {
            switch self {
            case .open: "Open"
            case .download: "Get"
            case .update: "Update"
            case .retry: "Retry"
            case .retryDisable: "Retry disable"
            case .remove: "Remove"
            }
        }
    }

    let stage: Stage
    let status: String
    let tone: Tone
    let action: Action?
    let on: Bool
    let canToggle: Bool
    let isInstalled: Bool
    let progress: Double?

    @MainActor init(_ entry: HostExtension, marketplace: HostMarketplace) {
        let id = entry.id
        let installed = marketplace.installed[id]
        let available = marketplace.available[id]
        let downloaded = marketplace.installedVersions[id]?.isEmpty == false
        let removing = marketplace.pendingRemovalIDs.contains(id)
        let state = marketplace.sessions.states[id]
        let operation = marketplace.operations[id]
        let failure = marketplace.failures[id] ?? marketplace.sessions.failureReasons[id]
        on = marketplace.surfaceAvailability.activeIDs.contains(id) || state == .starting
        isInstalled = installed != nil
        let starting = operation == nil && state == .starting
        progress =
            operation.map(\.fraction) ?? (starting ? 0.97 : (marketplace.isBusy(id) ? 0 : nil))
        canToggle = progress == nil && !removing && (installed != nil || available != nil)
        let pendingDisable = marketplace.sessions.pendingDisableIDs.contains(id)
        let ready = marketplace.readyIDs.contains(id)
        stage = Self.resolveStage(
            removing: removing, pendingDisable: pendingDisable, operation: operation,
            starting: starting, installed: installed != nil, downloaded: downloaded,
            available: available != nil, updateAvailable: marketplace.updateAvailable(id: id),
            failed: state == .failed || failure != nil, on: on, ready: ready)
        if removing {
            (status, tone, action) = ("Removal pending", .attention, .remove)
        } else if let operation {
            (status, tone, action) = (operation.summary, .neutral, nil)
        } else if starting {
            (status, tone, action) = ("Starting", .neutral, nil)
        } else if pendingDisable {
            (status, tone, action) = (
                "Disable pending · \(installed?.version ?? "Update required")", .attention,
                .retryDisable
            )
        } else if let installed {
            let update = marketplace.updateAvailable(id: id)
            if state == .failed {
                (status, tone, action) = (
                    failure ?? "Could not start · \(installed.version)", .failure, .retry
                )
            } else if let failure {
                (status, tone, action) = (failure, .failure, update ? .update : nil)
            } else if update, let available {
                (status, tone, action) = (
                    "Update available · \(available.version)", .attention, .update
                )
            } else if on {
                let route = HostExtensionActions.openTarget(extensionID: id) != nil
                (status, tone, action) = (
                    ready ? "Ready" : "On · \(installed.version)", .positive,
                    route ? .open : nil
                )
            } else {
                (status, tone, action) = ("Off · \(installed.version)", .neutral, nil)
            }
        } else if downloaded {
            let next: Action = available == nil ? .remove : .update
            (status, tone, action) = (
                failure
                    ?? (available == nil
                        ? "Not available for this version of Edith"
                        : "Update required for this version of Edith"),
                failure == nil ? .attention : .failure, next
            )
        } else if available != nil {
            (status, tone, action) = (
                failure ?? "Not installed", failure == nil ? .neutral : .failure,
                failure == nil ? .download : .retry
            )
        } else {
            (status, tone, action) = ("Not available", .neutral, nil)
        }
    }

    var emphasizesAction: Bool { stage != .installed }

    static func resolveStage(
        removing: Bool, pendingDisable: Bool, operation: HostExtensionOperation?, starting: Bool,
        installed: Bool, downloaded: Bool, available: Bool, updateAvailable: Bool, failed: Bool,
        on: Bool, ready: Bool
    ) -> Stage {
        if removing || pendingDisable { return .pending }
        if let operation {
            switch operation.phase {
            case .verifying: return .verifying
            case .starting: return .starting
            case .working, .queued, .downloading, .installing: return .downloading
            }
        }
        if starting { return .starting }
        if installed {
            if failed { return .failed }
            if updateAvailable { return .updateAvailable }
            return on && ready ? .ready : .installed
        }
        if downloaded { return available ? (failed ? .failed : .updateAvailable) : .unavailable }
        if available { return failed ? .failed : .notInstalled }
        return .unavailable
    }
}
