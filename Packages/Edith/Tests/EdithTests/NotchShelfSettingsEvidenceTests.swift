import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite(.serialized) struct NotchShelfSettingsEvidenceTests {
    private static let evidenceKey = "EDITH_NOTCH_BROWSER_EVIDENCE_DIR"

    @Test(.enabled(if: ProcessInfo.processInfo.environment[evidenceKey] != nil))
    func theShelfSettingsShowTheBrowserToggleAndAttachedProfile() throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        let dataRoot = try #require(environment["EDITH_DATA_ROOT"])
        #expect(dataRoot.hasPrefix(runtime + "/"))
        guard dataRoot.hasPrefix(runtime + "/") else { return }
        #expect(DataRoot.support.path.hasPrefix(runtime + "/"))
        let output = URL(
            fileURLWithPath: try #require(environment[Self.evidenceKey]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = SharedDefaults.store
        defaults.set(true, forKey: AppStorageKeys.Notch.shelfEnabled)
        defaults.set(true, forKey: AppStorageKeys.Notch.browserEnabled)
        defaults.set("duckDuckGo", forKey: AppStorageKeys.Notch.browserSearchEngine)
        defer { defaults.removeObject(forKey: AppStorageKeys.Notch.browserSearchEngine) }
        BrowserSessionFile.standard.save(
            BrowserSession(profile: "Profile 1", profileName: "Mock Work"))
        defer { BrowserSessionFile.standard.remove() }

        let sheet = VStack(spacing: 0) {
            ExtensionSettingsHeader(title: "Notch Shelf", enabled: .constant(true))
            Divider()
            Form { NotchShelfRows() }
                .formStyle(.grouped)
        }
        .frame(width: 560, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        .transaction { $0.animation = nil }
        try render(sheet, size: CGSize(width: 560, height: 760))
            .write(to: output.appendingPathComponent("notch-shelf-settings.png"))
    }

    private func render(_ view: some View, size: CGSize) throws -> Data {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<3 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
