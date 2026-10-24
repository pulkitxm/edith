import EdithStudio
import Darwin
import Foundation
#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif

struct StudioFixtureTools: Sendable {
    let admission: WorkerFixtureAdmission
    let toolbin: URL
    let engineAdmission: WorkerFixtureEngineAdmission?
    let nativeExporter: VideoExporter?

    init(admission: WorkerFixtureAdmission) throws {
        try self.init(admission: admission, engineAdmission: nil, nativeExporter: nil)
    }

    private init(
        admission: WorkerFixtureAdmission, engineAdmission: WorkerFixtureEngineAdmission?,
        nativeExporter: VideoExporter?
    ) throws {
        guard admission.extensionID == "studio", admission.role == .app else {
            throw WorkerFixtureError.invalid
        }
        self.admission = admission
        self.engineAdmission = engineAdmission; self.nativeExporter = nativeExporter
        toolbin = admission.home.appendingPathComponent("toolbin", isDirectory: true)
        if engineAdmission == nil, mkdir(toolbin.path, 0o700) != 0 && errno != EEXIST {
            throw WorkerFixtureError.invalid
        }
        guard toolbin.path == toolbin.resolvingSymlinksInPath().path else {
            throw WorkerFixtureError.invalid
        }
        let descriptor = open(toolbin.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WorkerFixtureError.invalid }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
            metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o7777 == 0o700,
            let directory = fdopendir(descriptor)
        else { Darwin.close(descriptor); throw WorkerFixtureError.invalid }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw WorkerFixtureError.invalid }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name == "." || name == ".." else { throw WorkerFixtureError.invalid }
        }
    }

    @MainActor func renderNativeExport(
        payload: Data, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VideoDeliveryReport {
        guard let engineAdmission, let nativeExporter,
            payload.count <= StudioCommands.maximumRequestBytes,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys) == [
                "id", "format", "output", "settings", "quality", "fps", "width", "loop",
            ],
            let id = object["id"] as? String, UUID(uuidString: id) != nil,
            object["format"] as? String == "video",
            object["quality"] as? String == VideoExportQuality.source.rawValue,
            object["fps"] as? Int == 15, object["width"] as? Int == 0,
            object["loop"] as? Bool == true,
            let path = object["output"] as? String,
            let rawSettings = object["settings"] as? [String: Any]
        else { throw WorkerFixtureError.invalid }
        try engineAdmission.requireCurrent()
        let output = try engineAdmission.outputURL(named: "exported-video")
        guard path == output.path else { throw WorkerFixtureError.invalid }
        let settings = try JSONDecoder().decode(
            VideoDeliverySettings.self, from: JSONSerialization.data(withJSONObject: rawSettings))
        guard settings == VideoDeliverySettings() else { throw WorkerFixtureError.invalid }
        let source = try engineAdmission.inputURL(named: "studio-source-video")
        _ = try engineAdmission.readInput(named: "studio-source-video")
        let bytes = try engineAdmission.readInput(named: "studio-project")
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            root["schemaVersion"] as? Int == 7
        else { throw WorkerFixtureError.invalid }
        let project = VideoProject(root: root)
        try project.validateVideoSettings()
        guard project.assets.count == 1, let asset = project.assets.first,
            asset.url == source, !asset.isStill, asset.cameraTrack == nil,
            asset.raw["edithSourceImagePath"] == nil, asset.raw["edithAudioPath"] == nil,
            project.audioTracks.isEmpty, project.annotations.isEmpty,
            project.backgroundColor.hasPrefix("#"), !project.backgroundColor.contains("/"),
            project.clips.count == 120,
            project.clips.enumerated().allSatisfy({ index, clip in
                clip.assetID == asset.id && clip.start == 0 && clip.end == 1
                    && clip.timelineStart == Double(index) && clip.rate == 1
            }),
            project.videoSettings.width == 320, project.videoSettings.height == 180,
            project.videoSettings.frameRateNumerator == 30,
            project.videoSettings.frameRateDenominator == 1,
            !FileManager.default.fileExists(atPath: source.path + ".cursor.json")
        else { throw WorkerFixtureError.invalid }
        let pipeline = try await VideoRenderPipeline.make(project: project)
        try engineAdmission.requireCurrent()
        let started = ContinuousClock.now
        guard
            try nativeExporter.startNativeExport(
                admission: engineAdmission,
                work: {
                    lease, action, stage, updates in
                    let report = try await pipeline.export(
                        to: stage, settings: settings,
                        nativeOutput: .init(resolve: { try lease.stageURL(action) }),
                        progress: { value in
                            updates(value); progress(value)
                        })
                    guard report.frameCount == 3600, abs(report.duration - 120) < 0.01,
                        report.frameRateNumerator == 30, report.frameRateDenominator == 1,
                        started.duration(to: .now) <= .seconds(30)
                    else { throw WorkerFixtureError.invalid }
                    nativeExporter.setReport(report, for: output)
                })
        else { throw WorkerFixtureError.invalid }
        let cancel = nativeExporter.pendingWorkCancellation()
        await withTaskCancellationHandler {
            await nativeExporter.waitForPendingWork()
        } onCancel: {
            cancel()
        }
        try Task.checkCancellation()
        try engineAdmission.requireCurrent()
        guard nativeExporter.job?.phase == .finished, let report = nativeExporter.job?.report,
            started.duration(to: .now) <= .seconds(30)
        else {
            throw WorkerFixtureError.invalid
        }
        return report
    }

    @MainActor func stopNativeExportAndWait() async {
        engineAdmission?.closeAdmission()
        await nativeExporter?.suspendCommandsAndWait()
        await engineAdmission?.waitForNamespaceCallbacks()
    }

    func executable(named name: String) -> URL? { nil }

    func detect() -> StudioEnvironment {
        var environment = StudioEnvironment.detect(
            path: toolbin.path,
            resolve: { executable(named: $0) }, allowsSearchFallback: false,
            modelAvailable: { false }, translationAvailable: false)
        environment.temporaryRoot = admission.dataDirectory.appendingPathComponent("tool-staging")
        return environment
    }

    @MainActor func makeModel(defaults: UserDefaults) -> StudioModel {
        StudioModel(
            defaults: defaults, loadsState: false, startsLibrary: false,
            detectEnvironment: { detect() },
            installEngine: { _, _ in
                "Installation is unavailable in the worker fixture."
            })
    }
}
