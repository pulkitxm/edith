import EdithKit
import Foundation
import Observation

enum HomebrewPageMode: String, CaseIterable, Identifiable {
    case installed
    case search

    var id: String { rawValue }
    var title: String { self == .installed ? "Installed" : "Discover" }
}

@MainActor
enum HomebrewCancellation {
    private static var handler: (() -> Bool)?

    static func register(_ handler: @escaping () -> Bool) {
        self.handler = handler
    }

    @discardableResult
    static func cancel() -> Bool {
        handler?() ?? false
    }
}

@MainActor
@Observable
final class HomebrewPageModel {
    var mode = HomebrewPageMode.installed
    var query = ""
    var packages: [HomebrewPackage] = []
    var status: HomebrewStatus?
    let loading = ContentLoad()
    var loaded: Bool { loading.hasContent }
    var isBusy = false
    private(set) var isMutating = false
    var isCancelling = false
    var operationTitle: String?
    var errorMessage: String?
    var resultMessage: String?
    var output = ""

    private let client: HomebrewClient
    private let store: HomebrewListingStore
    private var task: Task<Void, Never>?
    private var cachedPackages: [HomebrewPackageKind: [HomebrewPackage]] = [:]
    private var didRestoreSnapshot = false

    init(
        client: HomebrewClient = HomebrewClient(),
        store: HomebrewListingStore = HomebrewListingStore()
    ) {
        self.client = client
        self.store = store
        HomebrewCancellation.register { [weak self] in self?.cancel() ?? false }
    }

    var updateCount: Int { packages.count(where: \.outdated) }
    var installedCount: Int { packages.count(where: \.installed) }

    func activate(kind: HomebrewPackageKind) {
        guard !isMutating else { return }
        if mode == .search {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loading.setContent()
            } else {
                search(query, kind: kind)
            }
            return
        }
        begin(title: "Checking Homebrew") { generation in
            let token = await self.store.claim()
            guard self.isCurrent(generation) else { return }
            await self.restoreSnapshot(kind: kind, generation: generation)
            guard self.isCurrent(generation) else { return }
            let status = await self.client.status()
            guard self.isCurrent(generation) else { return }
            self.status = status
            guard status.available else {
                self.packages = []
                self.finish(generation)
                return
            }
            await self.fetchInstalled(kind: kind, generation: generation, token: token)
        }
    }

    func loadInstalled(kind: HomebrewPackageKind) {
        mode = .installed
        if let cached = cachedPackages[kind], !cached.isEmpty {
            packages = cached
            loading.retainContent()
        } else if !cachedPackages.isEmpty {
            packages = []
            loading.reset()
        }
        begin(title: "Reading installed \(kind.pluralTitle.lowercased())") { generation in
            let token = await self.store.claim()
            guard self.isCurrent(generation) else { return }
            await self.restoreSnapshot(kind: kind, generation: generation)
            guard self.isCurrent(generation) else { return }
            await self.fetchInstalled(kind: kind, generation: generation, token: token)
        }
    }

    func search(_ query: String, kind: HomebrewPackageKind) {
        self.query = query
        mode = .search
        begin(title: "Searching \(kind.pluralTitle.lowercased())") { generation in
            do {
                let packages = try await self.client.search(query, kind: kind)
                guard self.isCurrent(generation) else { return }
                self.packages = packages
                self.finish(generation)
            } catch {
                self.fail(error, generation: generation)
            }
        }
    }

    func perform(
        _ action: HomebrewMutation, package: HomebrewPackage,
        query: String, kind: HomebrewPackageKind
    ) {
        begin(title: operationTitle(action, package: package), mutation: true) { generation in
            do {
                let result = try await self.client.mutate(
                    action, kind: package.kind, name: package.name)
                guard self.isCurrent(generation) else { return }
                self.output = result.output
                self.resultMessage = self.resultText(action, package: package)
                if self.mode == .search,
                    !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    let packages = try await self.client.search(query, kind: kind)
                    guard self.isCurrent(generation) else { return }
                    self.packages = packages
                } else {
                    await self.fetchInstalled(
                        kind: kind, generation: generation, token: await self.store.claim())
                    return
                }
                self.finish(generation)
            } catch {
                self.fail(error, generation: generation)
            }
        }
    }

    @discardableResult
    func cancel() -> Bool {
        guard task != nil else { return false }
        isCancelling = true
        operationTitle = "Cancelling Homebrew"
        task?.cancel()
        return true
    }

    func clearNotice() {
        errorMessage = nil
        resultMessage = nil
        output = ""
    }

    func cancelDiscovery() {
        if !isMutating { cancel() }
    }

    private func fetchInstalled(
        kind: HomebrewPackageKind, generation: UInt64, token: UUID
    ) async {
        do {
            let packages = try await client.installed(kind: kind) { inventory in
                await self.publishInventory(inventory, kind: kind, generation: generation)
            }
            guard isCurrent(generation) else { return }
            self.packages = packages
            cachedPackages[kind] = packages
            loading.retainContent()
            if let status {
                let snapshot = HomebrewListingSnapshot(status: status, packages: cachedPackages)
                try? await store.save(snapshot, replacing: token)
            }
            guard isCurrent(generation) else { return }
            finish(generation)
        } catch {
            fail(error, generation: generation)
        }
    }

    private func publishInventory(
        _ inventory: [HomebrewPackage], kind: HomebrewPackageKind, generation: UInt64
    ) {
        guard isCurrent(generation) else { return }
        let visible = HomebrewPackageListing.preservingOutdatedFlags(inventory, from: packages)
        packages = visible
        cachedPackages[kind] = visible
        loading.retainContent()
    }

    private func restoreSnapshot(kind: HomebrewPackageKind, generation: UInt64) async {
        if !didRestoreSnapshot {
            let loadedSnapshot = await store.load()
            guard isCurrent(generation) else { return }
            didRestoreSnapshot = true
            if let loadedSnapshot {
                if status == nil { status = loadedSnapshot.status }
                for (key, value) in loadedSnapshot.packages where cachedPackages[key] == nil {
                    cachedPackages[key] = value
                }
            }
        }
        guard isCurrent(generation), packages.isEmpty, let cached = cachedPackages[kind],
            !cached.isEmpty
        else { return }
        packages = cached
        loading.retainContent()
    }

    private func begin(
        title: String, mutation: Bool = false,
        operation: @escaping @MainActor (UInt64) async -> Void
    ) {
        task?.cancel()
        let generation = loading.begin()
        isBusy = true
        isMutating = mutation
        isCancelling = false
        operationTitle = title
        errorMessage = nil
        resultMessage = nil
        output = ""
        task = Task {
            await operation(generation)
            if loading.owns(generation), Task.isCancelled {
                loading.cancel(generation)
                isBusy = false
                isMutating = false
                isCancelling = false
                operationTitle = nil
                task = nil
                resultMessage = "Homebrew operation cancelled."
            }
        }
    }

    private func finish(_ generation: UInt64) {
        guard isCurrent(generation) else { return }
        loading.complete(generation)
        isBusy = false
        isMutating = false
        isCancelling = false
        operationTitle = nil
        task = nil
    }

    private func fail(_ error: Error, generation: UInt64) {
        guard loading.owns(generation) else { return }
        loading.fail(generation, error: error)
        isBusy = false
        isMutating = false
        isCancelling = false
        operationTitle = nil
        task = nil
        if error is CancellationError {
            resultMessage = "Homebrew operation cancelled."
        } else {
            errorMessage = error.localizedDescription
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        loading.isCurrent(generation)
    }

    private func operationTitle(
        _ action: HomebrewMutation, package: HomebrewPackage
    ) -> String {
        switch action {
        case .install: "Installing \(package.displayName)"
        case .upgrade: "Upgrading \(package.displayName)"
        case .uninstall: "Uninstalling \(package.displayName)"
        }
    }

    private func resultText(
        _ action: HomebrewMutation, package: HomebrewPackage
    ) -> String {
        switch action {
        case .install: "Installed \(package.displayName)."
        case .upgrade: "Upgraded \(package.displayName)."
        case .uninstall: "Uninstalled \(package.displayName)."
        }
    }
}
