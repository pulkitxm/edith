import EdithKit
import ExtensionMarketplace
import Foundation
import Observation

@MainActor
@Observable
final class MarketplaceModel {
    private(set) var catalog: ExtensionCatalog?
    private(set) var downloadingID: String?
    private(set) var progress = 0.0
    private(set) var refreshing = false
    private(set) var offline = false
    private(set) var error: String?
    private(set) var installed: [ExtensionPackage] = []
    private(set) var restartRequired = false
    private(set) var pendingRemovals: Set<String> = []
    private let client = MarketplaceServices.catalogClient
    private let installer = MarketplaceServices.installer

    init() {
        reloadInstalled()
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await client.refresh()
            catalog = result.catalog
            offline = result.offline
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        reloadInstalled()
    }

    func package(for id: String) -> ExtensionPackage? {
        try? catalog?.installationPlan(
            for: id, hostABI: MarketplaceConfiguration.hostABI, architecture: "arm64",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        ).last
    }

    func installedPackage(for id: String) -> ExtensionPackage? {
        installed.filter {
            $0.id == id && $0.hostABI == MarketplaceConfiguration.hostABI
                && $0.architecture == "arm64"
        }.max {
            $0.version.compare($1.version, options: .numeric) == .orderedAscending
        }
    }

    func updateAvailable(for id: String) -> Bool {
        guard let package = package(for: id), let installed = installedPackage(for: id) else {
            return false
        }
        return package != installed
    }

    func download(id: String) async -> Bool {
        guard downloadingID == nil else { return false }
        downloadingID = id
        progress = 0
        defer { downloadingID = nil }
        if catalog == nil { await refresh() }
        do {
            guard let catalog else { throw MarketplaceError.downloadFailed }
            let plan = try catalog.installationPlan(
                for: id, hostABI: MarketplaceConfiguration.hostABI, architecture: "arm64",
                systemVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            let previousPackage = installedPackage(for: id)
            _ = try await installer.install(plan, repository: MarketplaceConfiguration.repository) {
                value in
                Task { @MainActor [weak self] in
                    guard self?.downloadingID == id else { return }
                    self?.progress = value
                }
            }
            if let previousPackage, previousPackage != plan.last { restartRequired = true }
            reloadInstalled()
            error = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            self.error = error.localizedDescription
            reloadInstalled()
            return false
        }
    }

    func remove(id: String) {
        do {
            let removed = try MarketplaceServices.store.requestRemoval(id: id)
            if !removed { restartRequired = true }
            reloadInstalled()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearError() { error = nil }

    private func reloadInstalled() {
        do {
            installed = try MarketplaceServices.store.installedPackages()
            pendingRemovals = try MarketplaceServices.store.pendingRemovals()
            if !pendingRemovals.isEmpty { restartRequired = true }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
