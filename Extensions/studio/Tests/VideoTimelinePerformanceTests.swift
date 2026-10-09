import EdithExtensionUI
import EdithExtensionSupport
import Observation
import SwiftUI
import Testing
import os
@testable import StudioExtension

@Suite @MainActor struct VideoTimelinePerformanceTests {
    @Test func playbackTicksDoNotInvalidateClipLanesButSelectionStillDoes() {
        let model = VideoEditorModel()
        defer { model.close() }
        var project = VideoProject.create()
        for index in 0..<200 {
            project.addAsset(
                URL(fileURLWithPath: "/synthetic/shot-\(index).mov"), duration: 2,
                width: 64, height: 64)
        }
        model.project = project
        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = VideoTimeline(model: model).body
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        for frame in 0..<600 { model.playhead = Double(frame) / 60 }
        #expect(!invalidated.withLock { $0 })
        model.selection = .clip(project.clips[0].id)
        #expect(invalidated.withLock { $0 })
    }
}
