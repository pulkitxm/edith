import AVFoundation
import Foundation
import Testing
@testable import Edith

@Suite @MainActor struct VideoBeatPanelTests {
    @Test func markerEditsAutosaveAndUndoWithoutReanchoring() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "marker-edit-\(UUID().uuidString).openscreen")
        defer { try? FileManager.default.removeItem(at: url) }
        var project = VideoProject.create()
        try project.save(to: url)
        let model = VideoEditorModel()
        defer { model.close() }
        model.project = project
        try VideoBeatPanelState.edit(model) { try $0.addMarker(atFrame: 45, label: "Verse") }
        let marker = try #require(model.project?.markers.first)
        #expect(try VideoProject.open(url).markers == [marker])
        try VideoBeatPanelState.edit(model) {
            try $0.updateMarker(marker.id, frame: 90, label: "Chorus")
        }
        #expect(try VideoProject.open(url).markers.first?.seconds == 3)
        model.undo()
        #expect(try VideoProject.open(url).markers == [marker])
        model.redo()
        #expect(try VideoProject.open(url).markers.first?.label == "Chorus")
        try VideoBeatPanelState.edit(model) { try $0.removeMarker(marker.id) }
        #expect(try VideoProject.open(url).markers.isEmpty)
        model.undo()
        #expect(try VideoProject.open(url).markers.first?.frame == 90)
    }

    @Test func rejectedPanelEditDoesNotCreateAnUndoStep() throws {
        let model = VideoEditorModel()
        defer { model.close() }
        model.project = .create()
        #expect(throws: VideoMarkerError.self) {
            try VideoBeatPanelState.edit(model) { try $0.addMarker(atFrame: -1) }
        }
        #expect(!model.canUndo)
        #expect(model.project?.markers.isEmpty == true)
    }

    @Test func mappingAndSnappingUseOutputSecondsAtFractionalFrameRate() throws {
        let rate = try VideoBeatPanelState.frameRate(CMTime(value: 1001, timescale: 30000))
        #expect(rate.numerator == 30000 && rate.denominator == 1001)
        #expect(throws: VideoMarkerError.self) { try VideoBeatPanelState.frameRate(.invalid) }
        var stream = try VideoBeatAnalysis.Stream(sampleRate: 1000, channels: 1)
        var samples = [Float](repeating: 0, count: 8000)
        samples[4500] = 1
        samples[5500] = 1
        try stream.append(samples)
        let mapping = VideoBeatMapping(sourceStart: 4, sourceEnd: 6, outputStart: 10, rate: 2)
        #expect(mapping.outputTime(for: 5) == 10.5)
        let markers = try mapping.markers(from: stream.finish(), frameRate: rate)
        #expect(markers.map(\.frame) == [307, 322])
        var project = VideoProject.create()
        try project.setMarkers(markers)
        let snapped = project.snapToMarker(frame: 305, thresholdFrames: 2, frameRate: rate)
        #expect(snapped == 307)
        #expect(abs(rate.seconds(at: snapped) - 10.2435666667) < 0.00001)
        let invalid = VideoBeatMapping(sourceStart: 6, sourceEnd: 4, outputStart: 0, rate: 1)
        #expect(throws: VideoBeatAnalysis.AnalysisError.self) {
            try invalid.markers(from: stream.finish(), frameRate: rate)
        }
    }

    @Test func newAnalysisAndCancellationDiscardStaleResults() async throws {
        let first = try fixture(duration: 4)
        let second = try fixture(duration: 1)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let state = VideoBeatPanelState()
        state.analyze(first, settings: .init())
        state.analyze(second, settings: .init())
        try await waitForAnalysis(state)
        #expect(state.error == nil)
        #expect(state.result?.duration == 1)
        state.analyze(first, settings: .init())
        state.clear()
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.result == nil)
        #expect(state.error == nil)
        #expect(!state.isAnalyzing)
    }

    private func waitForAnalysis(_ state: VideoBeatPanelState) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while state.isAnalyzing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!state.isAnalyzing)
    }

    private func fixture(duration: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "panel-fixture-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 8000)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { samples[index] = index % 4000 == 2000 ? 0.8 : 0 }
        try file.write(from: buffer)
        return url
    }
}
