import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EdithHelper

@Suite @MainActor struct CommandBarRenderTests {
    @Test func latestQueryPublishesRankedActions() async {
        let model = CommandBarModel(services: AppServices())
        model.query = "permissions"
        model.query = "extensions"

        for _ in 0..<100 where model.items.first?.id != "action.openExtensions" {
            await Task.yield()
        }

        #expect(model.items.first?.id == "action.openExtensions")
    }

    @Test func paletteRendersRankedActions() async throws {
        let model = CommandBarModel(services: AppServices())
        model.query = "settings"
        for _ in 0..<100 where model.items.first?.id != "action.openGeneralSettings" {
            await Task.yield()
        }

        let view = ZStack {
            Color(nsColor: .windowBackgroundColor)
            CommandBarView(model: model)
        }
        .frame(width: CommandBarController.width, height: CommandBarController.height)
        let image = try #require(render(view))

        #expect(model.items.first?.title == "Open Settings")
        #expect(distinctColours(in: image) > 30)
        dump(image, named: "command-bar-actions")
    }

    @Test func paletteRendersActionsAndCalculationAnswer() throws {
        let services = AppServices()
        let model = CommandBarModel(services: services)
        model.query = "(24 + 6) * 3"

        let view = ZStack {
            Color(nsColor: .windowBackgroundColor)
            CommandBarView(model: model)
        }
        .frame(width: CommandBarController.width, height: CommandBarController.height)
        let image = try #require(render(view))

        #expect(model.items.first?.title == "90")
        #expect(image.pixelsWide >= Int(CommandBarController.width))
        #expect(image.pixelsHigh >= Int(CommandBarController.height))
        #expect(distinctColours(in: image) > 30)
        dump(image, named: "command-bar")
    }

    private func render(_ view: some View) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(
            x: 0, y: 0, width: CommandBarController.width, height: CommandBarController.height)
        hosting.layoutSubtreeIfNeeded()
        guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        return image
    }

    private func distinctColours(in image: NSBitmapImageRep) -> Int {
        var colours: Set<Int> = []
        for x in stride(from: 0, to: image.pixelsWide, by: 5) {
            for y in stride(from: 0, to: image.pixelsHigh, by: 5) {
                guard let colour = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let packed =
                    Int(colour.redComponent * 255) << 16
                    | Int(colour.greenComponent * 255) << 8
                    | Int(colour.blueComponent * 255)
                colours.insert(packed)
            }
        }
        return colours.count
    }

    private func dump(_ image: NSBitmapImageRep, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"],
            let data = image.representation(using: .png, properties: [:])
        else { return }
        try? data.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
