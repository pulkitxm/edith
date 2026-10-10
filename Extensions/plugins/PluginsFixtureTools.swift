import Darwin
import Foundation
#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif

struct PluginsFixtureTools: Sendable {
    let admission: WorkerFixtureAdmission
    let toolbin: URL

    init(admission: WorkerFixtureAdmission) throws {
        guard admission.extensionID == "plugins", admission.role == .app else {
            throw WorkerFixtureError.invalid
        }
        self.admission = admission
        toolbin = admission.home.appendingPathComponent("toolbin", isDirectory: true)
        if mkdir(toolbin.path, 0o700) != 0 && errno != EEXIST { throw WorkerFixtureError.invalid }
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

    func executable(named name: String) -> URL? { nil }

    func agentMarkerExists(
        _ path: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard path.hasPrefix(admission.home.path + "/"),
            path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        else { return false }
        return exists(path)
    }

    @MainActor func makeModel(defaults: UserDefaults) -> SkillsModel {
        let documents = SkillDocumentStore(
            cacheDirectory: admission.dataDirectory.appendingPathComponent("cache")
        ) { _ in
            throw SkillsError.message("Downloads are unavailable in the worker fixture.")
        }
        let installer = SkillInstaller(
            recordInstalled: { _, _ in
                throw SkillsError.message("Installation is unavailable in the worker fixture.")
            }, unavailableReason: "Installation is unavailable in the worker fixture.")
        return SkillsModel(
            defaults: defaults, documents: documents, installer: installer,
            detectAgents: {
                SkillAgentCatalog.detected(home: admission.home, environment: [:], exists: {
                    agentMarkerExists($0)
                })
            },
            discoverInstaller: { executable(named: "npx") != nil })
    }
}
