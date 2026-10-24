import EdithExtensionSupport
import Foundation
import Observation

@MainActor
@Observable
final class HerdrFilesSession {
    private(set) var browser: HerdrFilesBrowser?
    private(set) var errorMessage: String?

    private let source: @MainActor (Machine) -> HerdrFilesSource
    private var startDirectory: String?

    init(source: @escaping @MainActor (Machine) -> HerdrFilesSource) {
        self.source = source
    }

    func prepare(directory: String, isLocal: Bool, machine: Machine?) {
        guard let machine = isLocal ? Machine.local : machine else {
            stop()
            browser = nil
            startDirectory = nil
            errorMessage = HerdrQuinjetError.machineUnavailable.localizedDescription
            return
        }
        errorMessage = nil
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = trimmed.isEmpty ? nil : trimmed
        guard let browser, browser.machine.id == machine.id else {
            browser?.stopLoading()
            browser = HerdrFilesBrowser(machine: machine, path: start, source: source(machine))
            startDirectory = start
            return
        }
        guard let start, start != startDirectory else { return }
        startDirectory = start
        browser.navigate(to: start)
    }

    func locate(
        _ target: String, directory: String, isLocal: Bool, machine: Machine?
    ) async -> RemoteFileEntry? {
        prepare(directory: directory, isLocal: isLocal, machine: machine)
        return await browser?.locate(target, under: directory)
    }

    func reveal(_ entry: RemoteFileEntry) async {
        await browser?.reveal(entry: entry)
    }

    func stop() {
        browser?.stopLoading()
    }
}
