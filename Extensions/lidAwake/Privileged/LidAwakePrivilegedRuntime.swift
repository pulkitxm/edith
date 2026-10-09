import Darwin
import Foundation

@MainActor @objc(EdithLidAwakePrivilegedRuntime)
final class LidAwakePrivilegedRuntime: NSObject {
    private var controller: LidAwakePrivilegedController?
    private var fixtureState = false
    private var journal: URL {
        Bundle(for: LidAwakePrivilegedRuntime.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("lidAwake-state.json")
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        Task { [self] in
            do {
                guard let command = request["command"] as? String,
                    let payload = request["payload"] as? Data, payload.count <= 16
                else { throw CocoaError(.coderReadCorrupt) }
                if command == "status" {
                    guard payload.isEmpty || payload == Data("{}".utf8) else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    let state =
                        getuid() == 0 ? try await LidAwakeSystemStateReader.read() : fixtureState
                    completion(try JSONEncoder().encode(["sleepDisabled": state]) as NSData, nil)
                    return
                }
                guard command == "setSleepDisabled" else { throw CocoaError(.coderReadCorrupt) }
                let disabled = try JSONDecoder().decode(Bool.self, from: payload)
                let controller = try makeController()
                try await controller.setSleepDisabled(disabled)
                completion(Data("{}".utf8) as NSData, nil)
            } catch { completion(nil, error.localizedDescription as NSString) }
        }
    }

    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping (NSError?) -> Void) {
        Task { [self] in
            do { try await makeController().restore(); completion(nil) } catch {
                completion(error as NSError)
            }
        }
    }

    private func makeController() throws -> LidAwakePrivilegedController {
        if let controller { return controller }
        if getuid() != 0 {
            guard ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let created = LidAwakePrivilegedController(
                read: { false },
                apply: { [weak self] value in self?.fixtureState = value })
            controller = created; return created
        }
        let original = try Self.readJournal(journal)
        let journal = self.journal
        let created = LidAwakePrivilegedController(
            original: original, read: { try await LidAwakeSystemStateReader.read() },
            apply: { value in
                let task = Task.detached {
                    try LidAwakeCommandProcess.run(
                        executableURL: URL(fileURLWithPath: LidAwakeCommand.toolPath),
                        arguments: LidAwakeCommand.arguments(active: value), timeout: 15,
                        cancelled: { Task.isCancelled })
                }
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                guard !result.timedOut, !result.cancelled, result.terminationStatus == 0 else {
                    throw NSError(
                        domain: "LidAwakePrivilege", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Sleep settings could not be restored. Check administrator approval, then try again."
                        ])
                }
            }, save: { try Self.writeJournal($0, to: journal) })
        controller = created; return created
    }

    private nonisolated static func readJournal(_ url: URL) throws -> Bool? {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == 0,
            attributes.st_mode & 0o077 == 0, attributes.st_size <= 16
        else { throw CocoaError(.fileReadNoPermission) }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 17), data.count <= 16 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try JSONDecoder().decode(Bool.self, from: data)
    }

    private nonisolated static func writeJournal(_ value: Bool?, to url: URL) throws {
        if let value {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: [.atomic])
            guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

@_cdecl("edith_extension_create")
public func createLidAwakePrivilegedExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(LidAwakePrivilegedRuntime()).toOpaque())
        })
}
