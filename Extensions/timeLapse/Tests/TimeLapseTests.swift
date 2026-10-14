import Darwin
import Foundation
import Testing

@testable import TimeLapseExtension

@Suite struct TimeLapseTests {
    @Test(arguments: [Int32(30), 60])
    func standardIsDefaultAndPreservesNormalSpeed(frameRate: Int32) throws {
        var settings = TimeLapseSettings()
        settings.frameRate = frameRate
        try settings.validate()
        #expect(settings.mode == .standard)
        #expect(settings.speed == 1)
        #expect(settings.captureInterval == 1 / Double(frameRate))
        #expect(settings.outputFPS == frameRate)
        #expect(settings.segmentFrameLimit == Int(frameRate) * 300)
        #expect(settings.estimatedBytes(hours: 1) == Double(frameRate / 30) * 5_400_000_000)
        settings.mode = .timeLapse
        #expect(settings.speed == 150)
        settings.mode = .standard
        #expect(settings.speed == 1)
        let decoded = try JSONDecoder().decode(
            TimeLapseSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func libraryRejectsLinkedSessionsAndExternalMetadata() throws {
        let root = try timeLapseFixtureRoot()
        let outside = try timeLapseFixtureRoot()
        defer {
            try? FileManager.default.removeItem(at: root);
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let session = TimeLapseSession(settings: TimeLapseSettings(), width: 64, height: 64)
        try JSONEncoder().encode(session).write(to: outside.appendingPathComponent("session.json"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: local.appendingPathComponent("session.json"),
            withDestinationURL: outside.appendingPathComponent("session.json"))
        #expect(try TimeLapseRecording.load(in: root).isEmpty)
        try FileManager.default.removeItem(at: local.appendingPathComponent("session.json"))
        try JSONEncoder().encode(session).write(to: local.appendingPathComponent("session.json"))
        let loaded: [TimeLapseRecording]
        do {
            loaded = try TimeLapseRecording.load(in: root)
        } catch {
            try timeLapseLibraryDiagnostic(root, loaded: nil, error: error)
            throw error
        }
        try timeLapseLibraryDiagnostic(root, loaded: loaded, error: nil)
        #expect(loaded.map(\.id) == [session.id])
    }

    @Test func invalidStandardFrameRatesAreRejected() {
        for rate: Int32 in [0, 1, 24, 120] {
            var settings = TimeLapseSettings()
            settings.frameRate = rate
            #expect(throws: TimeLapseError.self) { try settings.validate() }
        }
    }

    @Test(arguments: [30.0, 60, 150, 300, 900, 1800])
    func selectedSpeedControlsCaptureTimingAndStorage(speed: Double) throws {
        var settings = TimeLapseSettings()
        settings.mode = .timeLapse
        settings.speed = speed
        try settings.validate()
        #expect(settings.interval == speed / 30)
        #expect(settings.speed == speed)
        #expect(settings.estimatedBytes(hours: 1) * speed == 5_400_000_000)
        #expect(TimeLapseSettings.speeds.contains(speed))
    }

    @Test func fiveHoursIsTwoMinutesOfPlayback() {
        var settings = TimeLapseSettings()
        settings.mode = .timeLapse
        #expect(settings.speed == 150)
        #expect(settings.estimatedBytes(hours: 5) == 180_000_000)
    }

    @Test func audioCostUsesWallTime() {
        var settings = TimeLapseSettings()
        settings.mode = .timeLapse
        settings.systemAudio = true
        settings.microphoneID = "synthetic-microphone"
        #expect(settings.estimatedBytes(hours: 5) == 756_000_000)
        settings.interval = 60
        #expect(settings.audioBitRate == 256_000)
    }

    @Test func segmentRecoveryWindowIsAtMostFiveMinutes() {
        for interval in TimeLapseSettings.intervals {
            var settings = TimeLapseSettings()
            settings.mode = .timeLapse
            settings.interval = interval
            #expect(Double(settings.segmentFrameLimit) * interval <= 300)
            #expect(settings.segmentFrameLimit > 0)
        }
    }

    @Test func invalidAndNonFiniteIntervalsAreRejected() {
        for interval in [0.0, -1, .nan, .infinity, 3] {
            var settings = TimeLapseSettings()
            settings.mode = .timeLapse
            settings.interval = interval
            #expect(throws: TimeLapseError.self) { try settings.validate() }
        }
    }

    @Test func dimensionsPreserveAspectWithoutUpscaling() {
        var settings = TimeLapseSettings()
        settings.mode = .timeLapse
        #expect(settings.dimensions(width: 7680, height: 4320).width == 3840)
        #expect(settings.dimensions(width: 7680, height: 4320).height == 2160)
        #expect(settings.dimensions(width: 101, height: 51).width == 100)
        #expect(settings.dimensions(width: .infinity, height: 0).width == 2)
    }

    @Test func clockSkipsMissedIntervalsAfterSleepAndBackpressure() {
        var clock = TimeLapseClock(interval: 5)
        #expect(clock.isDue(at: 10))
        clock.accepted(at: 10)
        #expect(!clock.isDue(at: 14))
        #expect(clock.isDue(at: 15))
        #expect(clock.frames == 1)
        clock.accepted(at: 3600)
        #expect(clock.frames == 2)
        #expect(!clock.isDue(at: 3601))
        #expect(!clock.isDue(at: .nan))
        #expect(clock.playbackSeconds == 2.0 / 30)
    }

    @Test func sessionRoundTripsAndRejectsUnsafePaths() throws {
        var session = TimeLapseSession(settings: TimeLapseSettings(), width: 1920, height: 1080)
        session.segments = [
            .init(
                file: "video-0000.mov", kind: "video", frames: 300,
                startedAt: Date(), duration: 10)
        ]
        try session.validate()
        #expect(session.playbackSeconds == 10)
        let decoded = try JSONDecoder().decode(
            TimeLapseSession.self,
            from: JSONEncoder().encode(session))
        #expect(decoded.id == session.id)
        for file in ["../private.mov", "/private.mov", "x/y.mov", ".hidden", "x\\y.mov", ""] {
            session.segments = [
                .init(
                    file: file, kind: "video", frames: 1,
                    startedAt: Date(), duration: 1.0 / 30)
            ]
            #expect(throws: TimeLapseError.self) { try session.validate() }
        }
    }

    @Test func duplicateSegmentsAndInvalidDurationsAreRejected() {
        var session = TimeLapseSession(settings: TimeLapseSettings(), width: 1920, height: 1080)
        let segment = TimeLapseSession.Segment(
            file: "video.mov", kind: "video", frames: 300,
            startedAt: Date(), duration: 10)
        session.segments = [segment, segment]
        #expect(throws: TimeLapseError.self) { try session.validate() }
        session.segments = [
            .init(
                file: "video.mov", kind: "video", frames: 0,
                startedAt: Date(), duration: .nan)
        ]
        #expect(throws: TimeLapseError.self) { try session.validate() }
    }
}

private func timeLapseFixtureRoot() throws -> URL {
    let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
    let physical = try #require(realpath(temporary, nil))
    defer { free(physical) }
    var attributes = stat()
    try #require(
        lstat(physical, &attributes) == 0 && attributes.st_uid == getuid()
            && attributes.st_mode & S_IFMT == S_IFDIR && attributes.st_mode & 0o777 == 0o700)
    let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        .appendingPathComponent("time-lapse-model-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
}

private func timeLapseLibraryDiagnostic(
    _ root: URL, loaded: [TimeLapseRecording]?, error: (any Error)?
) throws {
    let physical = root.resolvingSymlinksInPath()
    let directories = try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles])
    var children: [[String: Any]] = []
    for directory in directories.sorted(by: { $0.path < $1.path }).prefix(2) {
        let metadata = directory.appendingPathComponent("session.json")
        let parent = directory.resolvingSymlinksInPath().deletingLastPathComponent()
        var row: [String: Any] = [
            "name": directory.lastPathComponent,
            "parentEqualsRoot": parent == physical,
            "parentURL": parent.absoluteString,
            "parentIsDirectory": parent.hasDirectoryPath,
        ]
        do {
            let directoryValues = try directory.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
            row["directory"] = directoryValues.isDirectory
            row["directoryLink"] = directoryValues.isSymbolicLink
            let metadataValues = try metadata.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            row["metadataRegular"] = metadataValues.isRegularFile
            row["metadataLink"] = metadataValues.isSymbolicLink
            row["metadataBytes"] = metadataValues.fileSize
            let data = try Data(contentsOf: metadata)
            let decoded = try JSONDecoder().decode(TimeLapseSession.self, from: data)
            row["decodedID"] = decoded.id.uuidString
            try decoded.validate()
            row["validSession"] = true
        } catch {
            let failure = error as NSError
            row["failureDomain"] = failure.domain
            row["failureCode"] = failure.code
        }
        children.append(row)
    }
    var result: [String: Any] = [
        "rootURL": physical.absoluteString,
        "rootIsDirectory": physical.hasDirectoryPath,
        "loadedIDs": loaded?.map { $0.id.uuidString } ?? [], "children": children,
    ]
    if let error {
        let failure = error as NSError
        result["loadFailureDomain"] = failure.domain
        result["loadFailureCode"] = failure.code
    }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print("timeLapseLibraryDiagnostic " + String(decoding: data, as: UTF8.self))
}
