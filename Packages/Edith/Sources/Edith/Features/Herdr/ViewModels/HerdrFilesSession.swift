import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class HerdrFilesSession {
    private(set) var finder: FinderModel?
    private(set) var errorMessage: String?

    private let machineSession: @MainActor (UUID) -> MachineSession
    private var startDirectory: String?

    init(
        machineSession: @escaping @MainActor (UUID) -> MachineSession = {
            MachinesModel.shared.session(for: $0)
        }
    ) {
        self.machineSession = machineSession
    }

    func prepare(directory: String, isLocal: Bool, machine: Machine?) {
        guard let machineID = isLocal ? Machine.localID : machine?.id else {
            stop()
            finder = nil
            startDirectory = nil
            errorMessage = HerdrQuinjetError.machineUnavailable.localizedDescription
            return
        }
        errorMessage = nil
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = trimmed.isEmpty ? nil : trimmed
        guard let finder, finder.session.id == machineID else {
            finder?.stopLoading()
            finder = FinderModel(session: machineSession(machineID), path: start)
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
}
