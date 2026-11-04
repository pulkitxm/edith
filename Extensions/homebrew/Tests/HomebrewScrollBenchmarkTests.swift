import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import HomebrewExtension

@Suite(.serialized) @MainActor struct HomebrewScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil

    @Test(.enabled(if: enabled)) func scrollingInstalledPackages() async throws {
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        let timing = try await Self.measure(
            packages: 1500, updatesOnly: false, frames: frames)
        print(
            "homebrew-scroll installed: \(timing) reach=\(Int(timing.offsets.max() ?? 0)) slowAt=\(timing.slowOffsets)"
        )
    }

    @Test func scrollingStaysSmoothWithManyPackages() async throws {
        let timing = try await Self.measure(packages: 400, updatesOnly: false, frames: 60)
        print("homebrew-regression installed: \(timing)")
        #expect(timing.frames.count == 60)
        #expect(timing.worst < 100)
        #expect(timing.median < 12)
    }

    static func measure(packages: Int, updatesOnly: Bool, frames: Int) async throws
        -> ScrollTiming
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-homebrew-scroll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let info = installedJSON(count: packages)
        let outdated = outdatedJSON(count: packages)
        let client = HomebrewClient(executableURL: URL(fileURLWithPath: "/brew")) { request, _ in
            switch request.arguments.first {
            case "--version":
                return CLICommandResult(terminationStatus: 0, output: "Homebrew 5.0.0\n")
            case "outdated":
                return CLICommandResult(terminationStatus: 0, output: outdated)
            case "info":
                return CLICommandResult(terminationStatus: 0, output: info)
            default:
                return CLICommandResult(terminationStatus: 0, output: "")
            }
        }
        let model = HomebrewPageModel(
            client: client,
            store: HomebrewListingStore(fileURL: root.appendingPathComponent("listing.json")))
        let (window, host) = ScrollHarness.host(
            HomebrewMaintenanceView(model: model)
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 1100, height: 760))
        for _ in 0..<200 where model.packages.count < packages || model.isBusy {
            await ScrollHarness.settle(host, for: .milliseconds(50))
        }
        #expect(model.packages.count == packages)
        await ScrollHarness.settle(host, for: .seconds(1))
        let timing = await ScrollHarness.scroll(host, frames: frames)
        await ScrollHarness.settle(host)
        window.orderOut(nil)
        window.contentView = nil
        model.shutdown()
        return timing
    }

    static func installedJSON(count: Int) -> String {
        let formulae = (0..<count).map { index in
            """
            {"name":"sample-package-\(index)","full_name":"sample-package-\(index)","desc":"Synthetic package number \(index) used for scrolling measurements","homepage":"https://example.com/\(index)","versions":{"stable":"\(index % 9).\(index % 13).1"},"installed":[{"version":"\(index % 9).\(index % 13).0"}]}
            """
        }
        return "{\"formulae\":[\(formulae.joined(separator: ","))],\"casks\":[]}"
    }

    static func outdatedJSON(count: Int) -> String {
        let formulae = stride(from: 0, to: count, by: 7).map { index in
            """
            {"name":"sample-package-\(index)","installed_versions":["\(index % 9).\(index % 13).0"],"current_version":"\(index % 9).\(index % 13).1"}
            """
        }
        return "{\"formulae\":[\(formulae.joined(separator: ","))],\"casks\":[]}"
    }
}
