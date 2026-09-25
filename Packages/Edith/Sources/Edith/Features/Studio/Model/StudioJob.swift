import EdithKit
import EdithStudio
import Foundation
import Observation

@MainActor
@Observable
final class StudioJob: Identifiable {
    enum Phase: Equatable {
        case editing
        case running
        case finished
        case failed(String)
    }

    let id = UUID()
    let tool: StudioTool
    var inputs: [URL]
    var settings: StudioSettings
    var phase: Phase = .editing
    var progress = 0.0
    var status: String?
    var result: StudioRunResult?
    var startedAt: Date?
    let preview = StudioPreviewModel()
    private var task: Task<Void, Never>?

    init(tool: StudioTool, inputs: [URL], settings: StudioSettings? = nil) {
        self.tool = tool
        self.inputs = StudioJobInputs.accepted(inputs, by: tool)
        self.settings = settings ?? tool.defaultSettings
    }

    var isRunning: Bool { phase == .running }

    var validationMessage: String? {
        do {
            try StudioRunner.validate(tool: tool, inputs: inputs, settings: settings)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func binding(_ key: String) -> StudioValue {
        settings[key] ?? tool.defaultSettings[key] ?? .text("")
    }

    func set(_ key: String, _ value: StudioValue) {
        settings[key] = value
    }

    func add(_ urls: [URL]) {
        inputs = StudioJobInputs.merged(inputs, adding: urls, for: tool)
        if phase != .running { phase = .editing }
    }

    func remove(_ url: URL) {
        inputs.removeAll { $0 == url }
    }

    func move(_ url: URL, by offset: Int) {
        guard let index = inputs.firstIndex(of: url) else { return }
        let target = min(max(index + offset, 0), inputs.count - 1)
        guard target != index else { return }
        inputs.remove(at: index)
        inputs.insert(url, at: target)
    }

    func run(
        destination: StudioDestination, environment: StudioEnvironment,
        onFinish: @escaping @MainActor (StudioJob) -> Void
    ) {
        guard task == nil else { return }
        task?.cancel()
        let tool = self.tool
        let inputs = self.inputs
        let settings = self.settings
        phase = .running
        progress = 0
        status = nil
        result = nil
        startedAt = Date()
        task = Task { [weak self] in
            let outcome: Result<StudioRunResult, Error>
            do {
                let value = try await StudioRunner.run(
                    tool: tool, inputs: inputs, settings: settings, destination: destination,
                    environment: environment
                ) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.phase == .running else { return }
                        self.progress = progress.fraction
                        if let status = progress.status { self.status = status }
                    }
                }
                outcome = .success(value)
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            switch outcome {
            case let .success(value):
                self.result = value
                self.progress = 1
                self.phase = .finished
                onFinish(self)
            case let .failure(error):
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .running { phase = .failed(StudioError.cancelled.localizedDescription) }
    }

    func reset() {
        guard !isRunning else { return }
        phase = .editing
        result = nil
        progress = 0
        status = nil
    }
}

enum StudioJobInputs {
    static func accepted(_ urls: [URL], by tool: StudioTool) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in urls where tool.accepts(url) && seen.insert(url).inserted {
            result.append(url)
        }
        if let maximum = tool.arity.maximum, result.count > maximum {
            return Array(result.prefix(maximum))
        }
        return result
    }

    static func merged(_ current: [URL], adding urls: [URL], for tool: StudioTool) -> [URL] {
        accepted(current + urls, by: tool)
    }

    static func rejected(_ urls: [URL], by tool: StudioTool) -> [URL] {
        urls.filter { !tool.accepts($0) }
    }
}
