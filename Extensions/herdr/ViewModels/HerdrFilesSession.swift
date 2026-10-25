import EdithExtensionFiles
import EdithExtensionSupport
import Foundation
import Observation

struct HerdrFilesWindowLocation: Codable, Equatable {
    let machine: Machine
    let path: String

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let result = String(decoding: try encoder.encode(self), as: UTF8.self)
        _ = try Self.decode(result)
        return result
    }

    static func decode(_ value: String) throws -> Self {
        guard value.utf8.count <= 8192 else { throw ExtensionPeerError.invalidRequest }
        let result = try JSONDecoder().decode(Self.self, from: Data(value.utf8))
        guard !result.path.isEmpty, result.path.utf8.count <= 4096,
            !result.path.utf8.contains(0), !result.machine.name.isEmpty,
            result.machine.name.utf8.count <= 512,
            MachineRegistry.validTarget(result.machine.sshTarget)
        else { throw ExtensionPeerError.invalidRequest }
        return result
    }
}

@MainActor
@Observable
final class HerdrFilesSession {
    private(set) var finder: FinderModel?
    private(set) var errorMessage: String?

    private let machineSession: @MainActor (Machine) -> any FinderSession
    private let openWindow: (@MainActor (Machine, String) -> Void)?
    private var startDirectory: String?

    init(
        machineSession: @escaping @MainActor (Machine) -> any FinderSession,
        openWindow: (@MainActor (Machine, String) -> Void)? = nil
    ) {
        self.machineSession = machineSession
        self.openWindow = openWindow
    }

    func prepare(directory: String, isLocal: Bool, machine: Machine?) {
        guard let machine = isLocal ? Machine.local : machine else {
            stop()
            finder = nil
            startDirectory = nil
            errorMessage = HerdrQuinjetError.machineUnavailable.localizedDescription
            return
        }
        errorMessage = nil
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = trimmed.isEmpty ? nil : trimmed
        guard let finder, finder.session.id == machine.id else {
            discard()
            let session = machineSession(machine)
            let model = FinderModel(session: session, path: start)
            if let openWindow {
                model.openInNewWindow = { openWindow(machine, $0) }
            }
            (session as? DirectFinderSession)?.opener = { [weak model] in model?.open($0) }
            finder = model
            startDirectory = start
            return
        }
        guard let start, start != startDirectory else { return }
        startDirectory = start
        finder.navigate(to: start)
    }

    func locate(
        _ target: String, directory: String, isLocal: Bool, machine: Machine?
    ) async -> RemoteFileEntry? {
        prepare(directory: directory, isLocal: isLocal, machine: machine)
        return await finder?.locate(target, under: directory)
    }

    func reveal(_ entry: RemoteFileEntry) async {
        await finder?.reveal(entry: entry)
    }

    func stop() {
        finder?.stopLoading()
    }

    func discard() {
        finder?.stopLoading()
        finder?.releaseRemote()
    }
}
