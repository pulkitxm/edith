import AVFoundation
import AppKit
import CoreVideo
import SwiftUI
import Testing
@testable import Edith

@Suite(.timeLimit(.minutes(1))) struct VideoIndependentAudioTests {
    @Test func splittingInsideBothFadesPreservesTheDecodedEnvelope() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mov")
        let sound = directory.appendingPathComponent("tone.caf")
        try await createVideo(video, duration: 4)
        try createAudio(sound, duration: 4) { Float(sin($0 * 2 * .pi * 440)) * 0.5 }
        var project = VideoProject.create()
        project.addAsset(video, duration: 4, width: 64, height: 64)
        project.addAudio(sound, duration: 4, at: 0)
        let id = try #require(project.audioTracks.first?.id)
        project.setAudioOptions(id, fadeInMs: 2000, fadeOutMs: 2000)
        let before = try await VideoRenderPipeline.make(project: project)
        let original = try await readAudio(before.composition, mix: before.audioMix)
        let first = directory.appendingPathComponent("before.mp4")
        try await before.exportMP4(to: first)
        let split = project.splitAudio(id, at: 1)
        let rightID = try #require(split)
        project.splitAudio(rightID, at: 3)
        let document = directory.appendingPathComponent("split.openscreen")
        try project.save(to: document)
        project = try VideoProject.open(document)
        let after = try await VideoRenderPipeline.make(project: project)
        let changed = try await readAudio(after.composition, mix: after.audioMix)
        let second = directory.appendingPathComponent("after.mp4")
        try await after.exportMP4(to: second)
        let exportedBefore = try await readAudio(first)
        let exportedAfter = try await readAudio(second)
        for start in stride(from: 0.05, through: 3.85, by: 0.1) {
            #expect(
                abs(
                    rms(original, from: start, to: start + 0.09)
                        - rms(changed, from: start, to: start + 0.09)) < 0.002)
            #expect(
                abs(
                    rms(exportedBefore, from: start, to: start + 0.09)
                        - rms(exportedAfter, from: start, to: start + 0.09)) < 0.004)
        }
        #expect(abs(VideoAudioAutomation.track(project.audioTracks[1]).value(at: 0) - 0.5) < 0.001)
    }

    @Test func detachPreservesTransitionFadesAcrossSpeedAndMuteSlices() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mov")
        let sound = directory.appendingPathComponent("tone.caf")
        try await createVideo(video, duration: 4)
        try createAudio(sound, duration: 4) { Float(sin($0 * 2 * .pi * 440)) * 0.5 }
        var project = VideoProject.create()
        project.addAsset(video, duration: 4, width: 64, height: 64)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = sound.path
        project.root["assets"] = assets
        project.split(clipID: project.clips[0].id, at: 2)
        project.addSpeed(startMs: 1400, endMs: 2000, rate: 2)
        project.addSpeed(startMs: 2000, endMs: 2400, rate: 2)
        project.setTransition(before: project.clips[1].id, kind: "fade", duration: 0.8)
        var timeline = project.root["timeline"] as? [String: Any] ?? [:]
        timeline["muteRanges"] = [
            ["clipId": project.clips[0].id, "startSec": 1.5, "endSec": 1.7],
            ["clipId": project.clips[1].id, "startSec": 2.2, "endSec": 2.3],
        ]
        project.root["timeline"] = timeline
        let before = try await VideoRenderPipeline.make(project: project)
        let first = directory.appendingPathComponent("before.mp4")
        try await before.exportMP4(to: first)
        for clip in project.clips { project.detachAudio(clipID: clip.id) }
        #expect(project.audioTracks.count >= 6)
        let after = try await VideoRenderPipeline.make(project: project)
        let second = directory.appendingPathComponent("after.mp4")
        try await after.exportMP4(to: second)
        let original = try await readAudio(first)
        let detached = try await readAudio(second)
        let nativeBefore = try await readAudio(before.composition, mix: before.audioMix)
        let nativeAfter = try await readAudio(after.composition, mix: after.audioMix)
        for start in stride(from: 0.1, through: before.duration - 0.15, by: 0.05) {
            let nativeDifference = abs(
                rms(nativeBefore, from: start, to: start + 0.04)
                    - rms(nativeAfter, from: start, to: start + 0.04))
            #expect(nativeDifference < 0.002, "native window \(start)")
            #expect(
                abs(
                    rms(original, from: start, to: start + 0.04)
                        - rms(detached, from: start, to: start + 0.04)) < 0.005,
                "window \(start): native difference \(nativeDifference), before \(rms(original, from: start, to: start + 0.04)), after \(rms(detached, from: start, to: start + 0.04))"
            )
        }
        let edge = try #require(
            VideoRenderPipeline.audioTransitions(project: project, segments: before.segments).first)
        #expect(rms(detached, from: edge.time - 0.015, to: edge.time + 0.015) < 0.025)
        let outgoing = rms(original, from: edge.time - 0.35, to: edge.time - 0.31)
        #expect(outgoing > 0.27 && outgoing < 0.31)
        #expect(rms(original, from: edge.time + 0.9, to: edge.time + 1.1) > 0.33)
    }

    @Test func loopTrimKeepsUnwrappedOffsetWhenVideoAndAudioLengthsDiffer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mov")
        let sound = directory.appendingPathComponent("short.caf")
        try await createVideo(video, duration: 5)
        try createAudio(sound, duration: 2) {
            Float(sin($0 * 2 * .pi * 440)) * ($0 < 1 ? 0.1 : 0.6)
        }
        var project = VideoProject.create()
        project.addAsset(video, duration: 5, width: 64, height: 64)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = sound.path
        project.root["assets"] = assets
        project.addAsset(video, duration: 3, width: 64, height: 64)
        let detached = project.detachAudio(clipID: project.clips[0].id)
        let id = try #require(detached.first)
        project.setAudioOptions(id, loop: true)
        project.retimeAudio(id, start: 0, end: 8, trimStart: false)
        let before = try await VideoRenderPipeline.make(project: project)
        let original = try await readAudio(before.composition, mix: before.audioMix)
        project.retimeAudio(id, start: 6, end: 8, trimStart: true)
        #expect(project.audioTracks[0].offsetMs == 6000)
        let after = try await VideoRenderPipeline.make(project: project)
        let samples = try await readAudio(after.composition, mix: after.audioMix)
        for start in [6.2, 7.2] {
            #expect(
                abs(
                    rms(original, from: start, to: start + 0.5)
                        - rms(samples, from: start, to: start + 0.5)) < 0.001)
        }
    }

    @Test func loopRendersTheLastSingleSampleAtFortyEightKilohertz() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mov")
        let sound = directory.appendingPathComponent("one-sample-short.caf")
        try await createVideo(video, duration: 1)
        let sourceDuration = 47999.0 / 48000
        try createAudio(sound, duration: sourceDuration) { _ in 0.25 }
        var project = VideoProject.create()
        project.addAsset(video, duration: 1, width: 64, height: 64)
        project.addAudio(sound, duration: sourceDuration, at: 0)
        let id = try #require(project.audioTracks.first?.id)
        project.setAudioOptions(id, loop: true)
        project.retimeAudio(id, start: 0, end: 1, trimStart: false)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let track = try #require(pipeline.composition.tracks(withMediaType: .audio).first)
        let last = try #require(track.segments.last)
        #expect(
            CMTimeCompare(last.timeMapping.target.duration, CMTime(value: 1, timescale: 48000)) == 0
        )
        let samples = try await readAudio(pipeline.composition, mix: pipeline.audioMix)
        #expect(samples.count == 48000)
        let finalSample = try #require(samples.indices.contains(47999) ? samples[47999] : nil)
        #expect(finalSample > 0.2)
    }

    @Test func detachmentSnapshotsSourceSpeedCutsGainAndMuteRanges() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/synthetic/source.mov"), duration: 8, width: 64, height: 64)
        let clipID = project.clips[0].id
        project.trim(clipID: clipID, start: 1, end: 7)
        project.addSpeed(startMs: 1000, endMs: 3000, rate: 2)
        project.addTrim(clipID: clipID, start: 4, end: 5)
        var clips = project.clips
        clips[0].raw["audioGainDb"] = -9.0
        project.setClips(clips)
        var timeline = project.root["timeline"] as? [String: Any] ?? [:]
        timeline["muteRanges"] = [["clipId": clipID, "startSec": 2.5, "endSec": 3.0]]
        project.root["timeline"] = timeline
        let ids = project.detachAudio(clipID: clipID)
        #expect(ids.count == 5)
        #expect(project.clips[0].raw["audioMuted"] as? Bool == true)
        #expect(project.audioTracks.map(\.offsetMs) == [1000, 2000, 2500, 3000, 5000])
        #expect(project.audioTracks.map(\.rate) == [1, 2, 2, 2, 1])
        #expect(project.audioTracks.map(\.startMs) == [0, 1000, 1250, 1500, 2000])
        #expect(project.audioTracks.map(\.endMs) == [1000, 1250, 1500, 2000, 4000])
        #expect(project.audioTracks.map(\.muted) == [false, false, true, false, false])
        #expect(project.audioTracks.allSatisfy { $0.gainDb == -9 && $0.raw["clipId"] == nil })
        #expect(project.detachAudio(clipID: clipID).isEmpty)
        project.setClips([])
        #expect(project.audioTracks.map(\.id) == ids)
    }

    @Test func detachedTrimMoveAndSplitUseSourceRate() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/synthetic/source.mov"), duration: 8, width: 64, height: 64)
        var clips = project.clips
        clips[0].rate = 2
        project.setClips(clips)
        let id = try #require(project.detachAudio(clipID: clips[0].id).first)
        project.retimeAudio(id, start: 0.5, end: 3.5, trimStart: true)
        #expect(project.audioTracks[0].offsetMs == 1000)
        project.moveAudio(id, to: 1)
        #expect(project.audioTracks[0].offsetMs == 1000)
        #expect(project.audioTracks[0].endMs == 4000)
        project.setAudioOptions(id, fadeInMs: 200, fadeOutMs: 300)
        let splitID = project.splitAudio(id, at: 2)
        let rightID = try #require(splitID)
        let right = try #require(project.audioTracks.first { $0.id == rightID })
        #expect(right.offsetMs == 3000)
        #expect(right.startMs == 2000 && right.endMs == 4000)
        #expect(project.audioTracks[0].fadeInMs == 200 && project.audioTracks[0].fadeOutMs == 0)
        #expect(right.fadeInMs == 0 && right.fadeOutMs == 300)
        project.removeAudioTrack(id)
        #expect(project.audioTracks.map(\.id) == [rightID])
        project.moveAudio(rightID, to: .nan)
        #expect(project.audioTracks[0].startMs == 2000)
    }

    @Test func detachmentPreservesExportedSamplesAndSurvivesVideoRetime() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mov")
        let sound = directory.appendingPathComponent("voice.caf")
        try await createVideo(video, duration: 4)
        try createAudio(sound, duration: 4) {
            Float(sin($0 * 2 * .pi * 440)) * ($0 < 2 ? 0.2 : 0.6)
        }
        var project = VideoProject.create()
        project.addAsset(video, duration: 4, width: 64, height: 64)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = sound.path
        project.root["assets"] = assets
        var clips = project.clips
        clips[0].rate = 2
        project.setClips(clips)
        let before = try await VideoRenderPipeline.make(project: project)
        let first = directory.appendingPathComponent("before.mp4")
        try await before.exportMP4(to: first)
        project.detachAudio(clipID: clips[0].id)
        let after = try await VideoRenderPipeline.make(project: project)
        let second = directory.appendingPathComponent("after.mp4")
        try await after.exportMP4(to: second)
        let original = try await readAudio(first)
        let detached = try await readAudio(second)
        for start in [0.2, 1.2] {
            #expect(
                abs(
                    rms(original, from: start, to: start + 0.5)
                        - rms(detached, from: start, to: start + 0.5)) < 0.01)
        }
        var retimed = project.clips
        retimed[0].rate = 1
        project.setClips(retimed)
        let independent = try await VideoRenderPipeline.make(project: project)
        let third = directory.appendingPathComponent("retimed.mp4")
        try await independent.exportMP4(to: third)
        let samples = try await readAudio(third)
        #expect(rms(samples, from: 1.2, to: 1.8) > 0.38)
        #expect(rms(samples, from: 2.3, to: 3.5) < 0.003)
    }

    @Test func detachmentPreservesAnAudioTrackThatStartsAfterTheVideo() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mov")
        let sound = directory.appendingPathComponent("sound.caf")
        try await createVideo(video, duration: 4)
        try createAudio(sound, duration: 2) { Float(sin($0 * 2 * .pi * 440)) * 0.5 }
        let source = AVURLAsset(url: sound)
        let audio = try #require(try await source.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let track = try #require(
            composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
            of: audio, at: CMTime(seconds: 1, preferredTimescale: 600))
        let delayed = directory.appendingPathComponent("delayed.mov")
        let export = try #require(
            AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        export.outputURL = delayed
        export.outputFileType = .mov
        await export.export()
        #expect(export.status == .completed)
        let delayedTrack = try #require(
            try await AVURLAsset(url: delayed).loadTracks(withMediaType: .audio).first)
        #expect(try await delayedTrack.load(.timeRange).duration.seconds >= 2)
        var project = VideoProject.create()
        project.addAsset(video, duration: 4, width: 64, height: 64)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = delayed.path
        project.root["assets"] = assets
        var clips = project.clips
        clips[0].rate = 2
        project.setClips(clips)
        for detached in [false, true] {
            if detached { project.detachAudio(clipID: clips[0].id) }
            let pipeline = try await VideoRenderPipeline.make(project: project)
            let output = directory.appendingPathComponent("delayed-\(detached).mp4")
            try await pipeline.exportMP4(to: output)
            let samples = try await readAudio(output)
            #expect(rms(samples, from: 0.1, to: 0.4) < 0.003)
            #expect(rms(samples, from: 0.7, to: 1.3) > 0.3)
            #expect(rms(samples, from: 1.7, to: 1.9) < 0.003)
        }
    }

    @Test @MainActor func nativeAudioEditsSupportUndoAndSeparateLanes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("Demo.mov")
        let sound = directory.appendingPathComponent("Music.caf")
        try await createVideo(video, duration: 4)
        try createAudio(sound, duration: 4) { Float(sin($0 * 2 * .pi * 440)) * 0.4 }
        var project = VideoProject.create(title: "Synthetic audio edit")
        project.addAsset(video, duration: 4, width: 64, height: 64)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = sound.path
        project.root["assets"] = assets
        project.addAudio(sound, duration: 4, at: 0)
        let model = VideoEditorModel()
        defer { model.close() }
        model.project = project
        model.selectedClipID = project.clips[0].id
        model.detachAudio(clipID: project.clips[0].id)
        for _ in 0..<200 where model.audioTask != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.audioTask == nil)
        let id = try #require(model.project?.audioTracks.last?.id)
        model.moveAudio(id, to: 0.5)
        #expect(model.project?.audioTracks.last?.startMs == 500)
        model.undo()
        #expect(model.project?.audioTracks.last?.startMs == 0)
        model.redo()
        #expect(model.project?.audioTracks.last?.startMs == 500)
        model.trimAudio(id, start: 1, end: 3.5)
        model.setAudioGain(id, decibels: -6)
        model.setAudioFade(id, milliseconds: 500, fadeIn: true)
        model.setAudioFade(id, milliseconds: 500, fadeIn: false)
        model.selectedClipID = nil
        model.seek(to: 2)
        for _ in 0..<200 where model.pipeline == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.pipeline != nil)
        #expect(model.errorMessage == nil)
        if let path = ProcessInfo.processInfo.environment["EDITH_AUDIO_EVIDENCE_DIR"] {
            _ = NSApplication.shared
            let output = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let view = NSHostingView(
                rootView: HStack(alignment: .top, spacing: 0) {
                    ScrollViewReader { proxy in
                        VideoTimeline(model: model).frame(width: 960, height: 280)
                            .onChange(of: model.selection) { _, _ in
                                proxy.scrollTo(Optional(id), anchor: .center)
                            }
                    }
                    Divider()
                    VideoInspector(model: model).frame(height: 760)
                }.padding().background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1272, height: 792), styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.contentView = view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            model.selection = nil
            try await Task.sleep(for: .milliseconds(100))
            model.selection = .audio(id)
            try await Task.sleep(for: .seconds(2))
            model.seek(to: 2)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("independent-audio.png"))
        }
    }

    @Test func outputAudioDoesNotFollowVideoSpeedTrimOrReorder() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/synthetic/first.mov"), duration: 4, width: 64, height: 64)
        project.addAsset(
            URL(fileURLWithPath: "/synthetic/second.mov"), duration: 4, width: 64, height: 64)
        project.addAudio(URL(fileURLWithPath: "/synthetic/music.caf"), duration: 8, at: 500)
        let original = try JSONSerialization.data(
            withJSONObject: project.audioTracks.map(\.raw), options: .sortedKeys)
        var clips = project.clips
        clips[0].rate = 2
        clips[1].rate = 0.5
        project.setClips(clips)
        project.addTrim(clipID: clips[0].id, start: 1, end: 2)
        project.setClips(Array(project.clips.reversed()))
        project.split(clipID: clips[1].id, at: 2)
        let after = try JSONSerialization.data(
            withJSONObject: project.audioTracks.map(\.raw), options: .sortedKeys)
        #expect(original == after)
        #expect(project.audioTracks.count == 1)
        #expect(project.audioTracks[0].startMs == 500)
    }

    @Test func exportedMusicRemainsContinuousAcrossSpeedChangesAndCuts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("silent.mov")
        let music = directory.appendingPathComponent("music.caf")
        try await createVideo(video, duration: 4)
        try createAudio(music, duration: 4) { time in
            Float(sin(time * 2 * .pi * 440)) * (time < 1 ? 0.12 : time < 2 ? 0.32 : 0.6)
        }
        var project = VideoProject.create()
        project.addAsset(video, duration: 4, width: 64, height: 64)
        project.addAudio(music, duration: 4, at: 0)
        project.split(clipID: project.clips[0].id, at: 2)
        var clips = project.clips
        clips[0].rate = 2
        project.setClips(clips)
        project.addTrim(clipID: clips[1].id, start: 2.5, end: 3)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        #expect(abs(pipeline.duration - 2.5) < 0.001)
        let audio = try #require(pipeline.composition.tracks(withMediaType: .audio).first)
        let mappings = audio.segments.filter { !$0.isEmpty }
        #expect(mappings.count == 1)
        #expect(abs(mappings[0].timeMapping.source.duration.seconds - 2.5) < 0.001)
        let exported = directory.appendingPathComponent("continuous.mp4")
        try await pipeline.exportMP4(to: exported)
        let samples = try await readAudio(exported)
        #expect(abs(rms(samples, from: 0.2, to: 0.8) - 0.12 / sqrt(2)) < 0.025)
        #expect(abs(rms(samples, from: 1.2, to: 1.8) - 0.32 / sqrt(2)) < 0.025)
        #expect(abs(rms(samples, from: 2.1, to: 2.4) - 0.6 / sqrt(2)) < 0.025)
    }

    @Test func exportedSourceGainMuteAndRangesAreAppliedAtOutputTime() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mov")
        let sound = directory.appendingPathComponent("source.caf")
        try await createVideo(video, duration: 4)
        try createAudio(sound, duration: 4) { Float(sin($0 * 2 * .pi * 440)) * 0.5 }
        var project = VideoProject.create()
        project.addAsset(video, duration: 4, width: 64, height: 64)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = sound.path
        project.root["assets"] = assets
        project.split(clipID: project.clips[0].id, at: 3)
        var clips = project.clips
        clips[0].rate = 2
        clips[0].raw["audioGainDb"] = -6.0206
        clips[1].raw["audioMuted"] = true
        project.setClips(clips)
        var timeline = project.root["timeline"] as? [String: Any] ?? [:]
        timeline["muteRanges"] = [
            [
                "clipId": clips[0].id, "assetId": clips[0].assetID, "startSec": 1.0, "endSec": 2.0,
            ]
        ]
        project.root["timeline"] = timeline
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let exported = directory.appendingPathComponent("source-mix.mp4")
        #expect(abs(pipeline.duration - 2.5) < 0.001)
        try await pipeline.exportMP4(to: exported)
        let samples = try await readAudio(exported)
        #expect(abs(rms(samples, from: 0.1, to: 0.4) - 0.25 / sqrt(2)) < 0.03)
        #expect(rms(samples, from: 0.6, to: 0.9) < 0.003)
        #expect(rms(samples, from: 1.1, to: 1.4) > 0.14)
        #expect(rms(samples, from: 1.7, to: 2.3) < 0.003)
        timeline["muteRanges"] = [
            [
                "clipId": clips[0].id, "startSec": 0.0, "endSec": 3.0,
            ]
        ]
        project.root["timeline"] = timeline
        let silent = try await VideoRenderPipeline.make(project: project)
        #expect(silent.composition.tracks(withMediaType: .audio).isEmpty)
        try await silent.exportMP4(to: directory.appendingPathComponent("silent.mp4"))
    }

    @Test func exportedMusicTrimsLoopsAndFadesInOutputSeconds() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mov")
        let sound = directory.appendingPathComponent("short.caf")
        try await createVideo(video, duration: 4)
        try createAudio(sound, duration: 1) { Float(sin($0 * 2 * .pi * 440)) * 0.5 }
        var project = VideoProject.create()
        project.addAsset(video, duration: 4, width: 64, height: 64)
        project.addAudio(sound, duration: 1, at: 0)
        let id = try #require(project.audioTracks.first?.id)
        project.setAudioOptions(id, loop: true, fadeInMs: 500, fadeOutMs: 500)
        project.retimeAudio(id, start: 0.5, end: 3.5, trimStart: true)
        project.setAudioGain(id, decibels: -6.0206)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let exported = directory.appendingPathComponent("looped.mp4")
        try await pipeline.exportMP4(to: exported)
        let samples = try await readAudio(exported)
        #expect(rms(samples, from: 0.1, to: 0.3) < 0.003)
        let normal = rms(samples, from: 1.2, to: 2.8)
        #expect(abs(normal - 0.25 / sqrt(2)) < 0.025)
        #expect(rms(samples, from: 0.55, to: 0.65) < normal * 0.4)
        #expect(rms(samples, from: 3.35, to: 3.45) < normal * 0.4)
        #expect(rms(samples, from: 3.7, to: 3.9) < 0.003)
        project.setAudioOptions(id, muted: true)
        let muted = try await VideoRenderPipeline.make(project: project)
        #expect(muted.composition.tracks(withMediaType: .audio).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audio-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createAudio(_ url: URL, duration: Double, sample: (Double) -> Float) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let count = AVAudioFrameCount(duration * 48000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let values = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(count) { values[index] = sample(Double(index) / 48000) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func createVideo(_ url: URL, duration: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<Int(duration * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 100, CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(
                adaptor.append(
                    pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private func readAudio(_ url: URL) async throws -> [Float] {
        try await readAudio(AVURLAsset(url: url), mix: nil)
    }

    private func readAudio(_ asset: AVAsset, mix: AVAudioMix?) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(!tracks.isEmpty)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ])
        output.audioMix = mix
        reader.add(output)
        #expect(reader.startReading())
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            #expect(status == kCMBlockBufferNoErr)
            let start = max(
                0, Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 48000).rounded()))
            if result.count < start {
                result.append(contentsOf: repeatElement(0, count: start - result.count))
            }
            result.append(contentsOf: values)
        }
        #expect(reader.status == .completed)
        return result
    }

    private func rms(_ samples: [Float], from: Double, to: Double) -> Double {
        let start = min(samples.count, Int(from * 48000))
        let end = min(samples.count, Int(to * 48000))
        guard end > start else { return 0 }
        return sqrt(samples[start..<end].reduce(0.0) { $0 + Double($1 * $1) } / Double(end - start))
    }
}
