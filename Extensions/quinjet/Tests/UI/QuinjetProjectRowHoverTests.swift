import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import QuinjetUI

@MainActor final class QuinjetMeasuredSize {
    var size = CGSize.zero
}

@MainActor @Suite("QuinjetProjectRowHoverTests", .serialized)
struct QuinjetProjectRowHoverTests {
    static let projects = ["sample-api", "sample-web", "sample-docs"].map { name in
        QuinjetProject(
            name: name, commonDir: "~/Work/\(name)/.git",
            worktrees: [
                QuinjetWorktree(
                    path: "~/Work/\(name)", head: "1234567", branch: "main", current: true,
                    bare: false, detached: false, locked: nil, prunable: nil),
                QuinjetWorktree(
                    path: "~/Work/\(name)-review", head: "7654321", branch: "review",
                    current: false, bare: false, detached: false, locked: nil, prunable: nil),
            ])
    }

    private func snapshot(_ host: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func changedBounds(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> CGRect? {
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min
        for x in 0..<lhs.pixelsWide {
            for y in 0..<lhs.pixelsHigh {
                guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let distance =
                    abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                guard distance > 0.02 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard minX != .max else { return nil }
        let scale = CGFloat(lhs.pixelsWide) / lhs.size.width
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    @Test(arguments: [false, true])
    func hoveredRowLightsItsWholeCellInsideTheCard(dark: Bool) async throws {
        let size = CGSize(width: 720, height: 300)
        let inset = 24.0
        let measured = QuinjetMeasuredSize()
        let host = NSHostingView(
            rootView: QuinjetProjectList(projects: Self.projects) { _, _ in }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { measured.size = proxy.size }
                            .onChange(of: proxy.size) { measured.size = proxy.size }
                    }
                }
                .padding(inset)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(DashSkin.paper(dark))
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.automaticViewActionsEnabled, false)
                .transaction { $0.animation = nil })
        host.frame = CGRect(origin: .zero, size: size)
        let window = PointerSimulation.window(contentRect: host.frame)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        for _ in 0..<6 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(
            !(window.isVisible && NSScreen.screens.contains { $0.frame.intersects(window.frame) }))
        let listHeight = measured.size.height
        let cellHeight = (listHeight - 2) / 3
        let cell = CGRect(
            x: inset, y: inset + cellHeight + 1, width: size.width - inset * 2, height: cellHeight)
        let idle = try snapshot(host)
        PointerSimulation.move(
            to: CGPoint(x: cell.minX + 120, y: cell.midY), in: host, window: window)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let hovered = try snapshot(host)
        let lit = try #require(changedBounds(idle, hovered))
        let plate = EdithRowMetrics.plateFrame(cell: cell, scale: UIScale.current)
        #expect(abs(lit.minX - plate.minX) <= 1, "\(lit) vs \(plate)")
        #expect(abs(lit.maxX - plate.maxX) <= 1, "\(lit) vs \(plate)")
        #expect(lit.minY >= cell.minY - 1.5 && lit.minY <= plate.minY + 1, "\(lit) vs \(plate)")
        #expect(lit.maxY <= cell.maxY + 1.5 && lit.maxY >= plate.maxY - 1, "\(lit) vs \(plate)")
        if let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try #require(hovered.representation(using: .png, properties: [:])).write(
                to: directory.appendingPathComponent(
                    "quinjet-project-row-hovered-\(dark ? "dark" : "light").png"))
        }
    }
}
