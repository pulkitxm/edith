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
@Observable
final class HomebrewPageModel {
    var mode = HomebrewPageMode.installed
    var packages: [HomebrewPackage] = []
    var status: HomebrewStatus?
    var loaded = false
    var isBusy = false
    var isCancelling = false
    var operationTitle: String?
    var errorMessage: String?
    var resultMessage: String?
    var output = ""

    private let client: HomebrewClient
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(client: HomebrewClient = HomebrewClient()) {
        self.client = client
    }

    var updateCount: Int { packages.count(where: \.outdated) }
    var installedCount: Int { packages.count(where: \.installed) }

    func activate(kind: HomebrewPackageKind) {
        begin(title: "Checking Homebrew") { generation in
            let status = await self.client.status()
            guard self.isCurrent(generation) else { return }
            self.status = status
            guard status.available else {
                self.packages = []
                self.finish(generation)
                return
            }
            await self.loadInstalled(kind: kind, generation: generation)
        }
    }

    func loadInstalled(kind: HomebrewPackageKind) {
        mode = .installed
        begin(title: "Reading installed \(kind.pluralTitle.lowercased())") { generation in
            await self.loadInstalled(kind: kind, generation: generation)
        }
    }

    func search(_ query: String, kind: HomebrewPackageKind) {
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
        begin(title: operationTitle(action, package: package)) { generation in
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
                    await self.loadInstalled(kind: kind, generation: generation)
                    return
                }
                self.finish(generation)
            } catch {
                self.fail(error, generation: generation)
            }
        }
    }

    func cancel() {
        guard task != nil else { return }
        isCancelling = true
        operationTitle = "Cancelling Homebrew"
        task?.cancel()
    }

    func clearNotice() {
        errorMessage = nil
        resultMessage = nil
        output = ""
    }

    private func loadInstalled(kind: HomebrewPackageKind, generation: UUID) async {
        do {
            let packages = try await client.installed(kind: kind)
            guard isCurrent(generation) else { return }
            self.packages = packages
            finish(generation)
        } catch {
            fail(error, generation: generation)
        }
    }

    private func begin(
        title: String, operation: @escaping @MainActor (UUID) async -> Void
    ) {
        task?.cancel()
        let generation = UUID()
        self.generation = generation
        isBusy = true
        isCancelling = false
        loaded = false
        operationTitle = title
        errorMessage = nil
        resultMessage = nil
        output = ""
        task = Task { await operation(generation) }
    }

    private func finish(_ generation: UUID) {
        guard isCurrent(generation) else { return }
        loaded = true
        isBusy = false
        isCancelling = false
        operationTitle = nil
        task = nil
    }

    private func fail(_ error: Error, generation: UUID) {
        guard isCurrent(generation) else { return }
        loaded = true
        isBusy = false
        isCancelling = false
        operationTitle = nil
        task = nil
        if error is CancellationError {
            resultMessage = "Homebrew operation cancelled."
        } else {
            errorMessage = error.localizedDescription
        }
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        self.generation == generation
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
