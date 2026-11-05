import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import HomebrewExtension

enum HomebrewRenderFixture {
    static let info = """
        {"formulae":[\
        {"name":"ripgrep","desc":"Search tool like grep and The Silver Searcher","versions":{"stable":"14.1.1"},"installed":[{"version":"14.1.0"}]},\
        {"name":"node","desc":"Platform built on V8 to build network applications","versions":{"stable":"23.1.0"},"installed":[{"version":"23.1.0"}]},\
        {"name":"git","desc":"Distributed revision control system","versions":{"stable":"2.47.0"},"installed":[{"version":"2.46.2"}]},\
        {"name":"ffmpeg","desc":"Play, record, convert, and stream audio and video","versions":{"stable":"7.1"},"installed":[{"version":"7.1"}]},\
        {"name":"jq","desc":"Lightweight and flexible command-line JSON processor","versions":{"stable":"1.7.1"},"installed":[{"version":"1.7.1"}]}\
        ],"casks":[]}
        """
    static let outdated = """
        {"formulae":[\
        {"name":"ripgrep","installed_versions":["14.1.0"],"current_version":"14.1.1"},\
        {"name":"git","installed_versions":["2.46.2"],"current_version":"2.47.0"}\
        ],"casks":[]}
        """

    static func client(
        available: Bool = true, hold: Bool = false, empty: Bool = false
    ) -> HomebrewClient {
        HomebrewClient(executableURL: URL(fileURLWithPath: "/synthetic/brew")) { request, _ in
            switch request.arguments.first {
            case "--version":
                return CLICommandResult(
                    terminationStatus: available ? 0 : 1, output: "Homebrew 5.0.0\n")
            case "outdated":
                return CLICommandResult(
                    terminationStatus: 0,
                    output: empty ? "{\"formulae\":[],\"casks\":[]}" : outdated)
            case "info":
                if hold { try await Task.sleep(for: .seconds(30)) }
                return CLICommandResult(
                    terminationStatus: 0,
                    output: empty ? "{\"formulae\":[],\"casks\":[]}" : info)
            default:
                return CLICommandResult(terminationStatus: 0, output: "\n")
            }
        }
    }
}

@MainActor
@Suite(.serialized)
struct HomebrewPageRenderTests {
    static func store() -> HomebrewListingStore {
        HomebrewListingStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "synthetic.homebrew.render.\(UUID().uuidString).json"))
    }

    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    static func capture(_ name: String, model: HomebrewPageModel) async throws {
        for variant in RenderCapture.layoutVariants {
            _ = try await RenderCapture.render(name, variant: variant) {
                HomebrewMaintenanceView(model: model)
            }
        }
    }

    @Test func installedPackagesShowUpdatesAndActions() async throws {
        let model = HomebrewPageModel(client: HomebrewRenderFixture.client(), store: Self.store())
        model.activate(kind: .formula)
        await Self.waitUntil { model.loaded && !model.isBusy }
        #expect(model.packages.count == 5)
        #expect(model.updateCount == 2)
        try await Self.capture("homebrew-installed", model: model)
        model.cancelDiscovery()
    }

    @Test func loadingShowsASkeleton() async throws {
        let model = HomebrewPageModel(
            client: HomebrewRenderFixture.client(hold: true), store: Self.store())
        model.activate(kind: .formula)
        await Self.waitUntil { model.status != nil }
        #expect(!model.loaded)
        try await Self.capture("homebrew-loading", model: model)
        model.cancelDiscovery()
    }

    @Test func missingHomebrewExplainsHowToGetIt() async throws {
        let model = HomebrewPageModel(
            client: HomebrewRenderFixture.client(available: false), store: Self.store())
        model.activate(kind: .formula)
        await Self.waitUntil { model.status != nil && !model.isBusy }
        #expect(model.status?.available == false)
        try await Self.capture("homebrew-missing", model: model)
        model.cancelDiscovery()
    }

    @Test func discoverPromptsForASearch() async throws {
        let model = HomebrewPageModel(
            client: HomebrewRenderFixture.client(empty: true), store: Self.store())
        model.activate(kind: .formula)
        await Self.waitUntil { model.loaded && !model.isBusy }
        model.mode = .search
        model.packages = []
        model.loading.setContent()
        try await Self.capture("homebrew-discover", model: model)
        model.cancelDiscovery()
    }
}

extension RenderCapture {
    fileprivate static let layoutVariants =
        variants + [Variant(name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light)]
}
