import AppKit
import SwiftUI
import Testing
import Vision

@testable import Edith
@testable import EdithKit

@MainActor @Suite(.serialized)
struct ExtensionRowPresentationTests {
    @Test func packageSubtitleOnlyAddsDistinctInformation() {
        for description in [nil, "", "  ", "ripgrep", "RIPGREP"] as [String?] {
            let package = HomebrewPackage(
                kind: .formula, name: "ripgrep", displayName: "ripgrep", description: description)
            #expect(package.subtitle == nil)
        }
        #expect(
            HomebrewPackage(kind: .cask, name: "browser", displayName: "Sample Browser").subtitle
                == "browser")
        #expect(
            HomebrewPackage(
                kind: .formula, name: "rg", displayName: "rg", description: " Search files "
            ).subtitle == "Search files")
    }

    @Test func aCompletedEmptyScanStillOffersAnotherScan() throws {
        let host = try auditHost(
            CleanerCard(dark: true, model: CleanerModel(scanned: true)),
            size: CGSize(width: 900, height: 220))
        let text = try auditText(host)
        #expect(text.contains("Scan again"))
        #expect(text.contains("Nothing to clean"))
    }

    @Test func runningAppWithoutAnIconKeepsTheIconColumnFilled() throws {
        let row = RunningAppRow(
            pid: 9, name: "Sample Player", bundleID: "test.player", icon: nil, cpuPercent: 0,
            memoryMB: 40)
        let host = try auditHost(
            SystemAppRow(app: row, dark: true, canQuit: false, onQuit: {}),
            size: CGSize(width: 650, height: 50))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let background = try #require(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        var iconPixels = 0
        for x in Int(7 * scale)..<Int(27 * scale) {
            for y in Int(15 * scale)..<Int(35 * scale) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if abs(color.redComponent - background.redComponent) > 0.1 { iconPixels += 1 }
            }
        }
        #expect(iconPixels > 10)
    }
}

@MainActor
func auditHost(_ view: some View, size: CGSize) throws -> NSHostingView<AnyView> {
    _ = TestWindowHost.application
    let host = NSHostingView(
        rootView: AnyView(
            view
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.terminalLaunchEnabled, false)
                .environment(\.windowVisible, false)
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil }
                .frame(width: size.width, height: size.height)
                .background(DashSkin.paper(true))))
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    host.layoutSubtreeIfNeeded()
    #expect(TestWindowHost.exposedWindows.isEmpty)
    return host
}

@MainActor
func auditText(_ host: NSHostingView<AnyView>) throws -> String {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let image = try #require(bitmap.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
        separator: "\n")
}
