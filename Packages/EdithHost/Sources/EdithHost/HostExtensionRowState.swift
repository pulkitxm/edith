import EdithHostCore
import Foundation

struct HostExtensionRowState: Equatable {
    enum Tone: Equatable {
        case neutral, positive, attention, failure
    }

    enum Action: Equatable {
        case open, download, update, retry, retryDisable, remove

        var title: String {
            switch self {
            case .open: "Open"
            case .download: "Download"
            case .update: "Update"
            case .retry: "Retry"
            case .retryDisable: "Retry disable"
            case .remove: "Remove"
            }
        }
    }

    let status: String
    let tone: Tone
    let action: Action?
    let on: Bool
    let canToggle: Bool
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
        progress = operation.map(\.fraction) ?? (marketplace.isBusy(id) ? 0 : nil)
        canToggle = progress == nil && !removing && (installed != nil || available != nil)
        if removing {
            (status, tone, action) = ("Removal pending", .attention, .remove)
        } else if let operation {
            (status, tone, action) = (operation.summary, .neutral, nil)
        } else if marketplace.sessions.pendingDisableIDs.contains(id) {
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
                (status, tone, action) = (
                    "On · \(installed.version)", .positive,
                    HostNavigationCatalog.route(extensionID: id) == nil ? nil : .open
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
                failure ?? "Not installed", failure == nil ? .neutral : .failure, .download
            )
        } else {
            (status, tone, action) = ("Not available", .neutral, nil)
        }
    }
}
