import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite @MainActor struct FocusRenderTests {
    @Test func indefiniteFocusSessionRunsAndRestores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FocusStorage(root: root)
        let profile = FocusProfile(name: "Deep work", defaultDurationMinutes: 50)
        try storage.save(FocusDocument(profiles: [profile], showsStatusItem: false))
        let automations = AutomationRuntime(storage: AutomationStorage(root: root))
        defer { automations.shutdown() }
        let runtime = FocusRuntime(automations: automations, storage: storage)
        runtime.start(profile, untilStopped: true, origin: .menuPanel)
        for _ in 0..<100 where runtime.activeSession == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let session = try #require(runtime.activeSession)
        #expect(session.endsAt == nil)
        #expect(try storage.session()?.id == session.id)
        let view = ZStack {
            Color(nsColor: .windowBackgroundColor)
            FocusView(runtime: runtime).padding(20)
        }.frame(width: 520, height: 290)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 290)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 520)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("focus-session.png"))
        }
        runtime.stop()
        for _ in 0..<100 where runtime.activeSession != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(runtime.activeSession == nil)
        #expect(try storage.session() == nil)
        #expect(try storage.history().last?.outcome == .completed)
        await runtime.prepareForTermination()
    }
}
