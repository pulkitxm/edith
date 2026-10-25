import EdithExtensionFiles
import EdithExtensionSupport
import Foundation
import Observation

@MainActor
@Observable
final class HerdrFilesSession {
    private(set) var finder: FinderModel?
    private(set) var errorMessage: String?

    private let machineSession: @MainActor (Machine) -> any FinderSession
    private var startDirectory: String?

    init(machineSession: @escaping @MainActor (Machine) -> any FinderSession) {
        self.machineSession = machineSession
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
