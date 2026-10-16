import EdithStudio
import Foundation

struct StudioUIJobState: Codable, Sendable {
    struct Output: Codable, Sendable {
        let toolID: String
        let outputs: [StudioOutputFile]
        let inputBytes: Int64
        let notes: [String]
        let failures: [StudioFailure]
        let folders: [URL]

        init(_ result: StudioRunResult) {
            toolID = result.toolID
            outputs = result.outputs
            inputBytes = result.inputBytes
            notes = result.notes
            failures = result.failures
            folders = result.folders
        }

        var value: StudioRunResult {
            StudioRunResult(
                toolID: toolID, outputs: outputs, inputBytes: inputBytes,
                notes: notes, failures: failures, folders: folders)
        }
    }

    let id: UUID
    let phase: String
    let failure: String?
    let progress: Double
    let unit: Int
    let units: Int
    let status: String?
    let result: Output?

    @MainActor init(_ job: StudioJob) {
        id = job.id
        switch job.phase {
        case .editing: phase = "editing"; failure = nil
        case .running: phase = "running"; failure = nil
        case .finished: phase = "finished"; failure = nil
        case let .failed(message): phase = "failed"; failure = message
        }
        progress = job.progress
        unit = job.unit
        units = job.units
        status = job.status
        result = job.result.map(Output.init)
    }
}
