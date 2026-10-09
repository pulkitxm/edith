import Foundation

public enum StudioDestination: Codable, Hashable, Sendable {
    case nextToOriginal
    case folder(URL)
}

public struct StudioProgress: Sendable, Equatable {
    public var fraction: Double
    public var status: String?
    public var unit: Int
    public var units: Int

    public init(fraction: Double, status: String?, unit: Int, units: Int) {
        self.fraction = fraction
        self.status = status
        self.unit = unit
        self.units = units
    }
}

public struct StudioOutputFile: Codable, Hashable, Sendable, Identifiable {
    public let url: URL
    public let kind: StudioKind
    public let bytes: Int64
    public let source: URL?

    public var id: URL { url }

    public init(url: URL, kind: StudioKind, bytes: Int64, source: URL?) {
        self.url = url
        self.kind = kind
        self.bytes = bytes
        self.source = source
    }
}

public struct StudioFailure: Codable, Hashable, Sendable {
    public let file: String
    public let message: String
}

public struct StudioRunResult: Sendable {
    public let toolID: String
    public let outputs: [StudioOutputFile]
    public let inputBytes: Int64
    public let notes: [String]
    public let failures: [StudioFailure]
    public let folders: [URL]

    public var outputBytes: Int64 { outputs.reduce(0) { $0 + $1.bytes } }

    public var savings: Double? {
        guard inputBytes > 0, !outputs.isEmpty else { return nil }
        return 1 - Double(outputBytes) / Double(inputBytes)
    }
}

final class StudioRunReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String] = []
    private let unit: Int
    private let units: Int
    private let sink: @Sendable (StudioProgress) -> Void
    private var lastFraction = 0.0
    private var lastStatus: String?

    init(unit: Int, units: Int, sink: @escaping @Sendable (StudioProgress) -> Void) {
        self.unit = unit
        self.units = units
        self.sink = sink
    }

    func progress(_ fraction: Double) {
        lock.lock()
        let clamped = min(max(fraction, 0), 1)
        guard abs(clamped - lastFraction) >= 0.004 || clamped >= 1 else {
            lock.unlock()
            return
        }
        lastFraction = clamped
        let status = lastStatus
        lock.unlock()
        publish(clamped, status)
    }

    func status(_ text: String) {
        lock.lock()
        lastStatus = text
        let fraction = lastFraction
        lock.unlock()
        publish(fraction, text)
    }

    func note(_ text: String) {
        lock.lock()
        if !notes.contains(text) { notes.append(text) }
        lock.unlock()
    }

    var collectedNotes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return notes
    }

    private func publish(_ fraction: Double, _ status: String?) {
        let overall = (Double(unit) + fraction) / Double(max(units, 1))
        sink(StudioProgress(fraction: overall, status: status, unit: unit, units: units))
    }
}

public struct StudioRun: Sendable {
    public let tool: StudioTool
    public let inputs: [URL]
    public let settings: StudioSettings
    public let workDirectory: URL
    public let environment: StudioEnvironment
    let reporter: StudioRunReporter

    public var input: URL { inputs[0] }

    public func progress(_ fraction: Double) { reporter.progress(fraction) }

    public func status(_ text: String) { reporter.status(text) }

    public func note(_ text: String) { reporter.note(text) }

    public func checkCancellation() throws {
        if Task.isCancelled { throw StudioError.cancelled }
    }

    public func output(named name: String) -> URL {
        StudioNaming.unique(workDirectory.appendingPathComponent(name))
    }

    public func output(for source: URL, suffix: String?, ext: String) -> URL {
        let stem = source.studioStem
        let base = suffix.map { "\(stem)-\($0)" } ?? stem
        return output(named: base + "." + ext)
    }

    public func scratch(_ name: String) throws -> URL {
        let url = workDirectory.appendingPathComponent(".scratch", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public enum StudioNaming {
    public static func unique(_ url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    public static func safeStem(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "untitled" : String(cleaned.prefix(120))
    }
}

public enum StudioRunner {
    public static func validate(
        tool: StudioTool, inputs: [URL], settings: StudioSettings
    ) throws {
        guard tool.isRunnable else {
            throw StudioError.unavailable("\(tool.title) opens an editor instead of running.")
        }
        if let rejected = inputs.first(where: { !tool.accepts($0) }) {
            throw StudioError.unsupportedInput(rejected.lastPathComponent, tool.title)
        }
        if inputs.count < tool.arity.minimum {
            throw StudioError.needsMoreInputs(tool.arity.minimum)
        }
        if let maximum = tool.arity.maximum, inputs.count > maximum {
            throw StudioError.invalidOption(
                "files", maximum == 0 ? "this tool takes no files" : "use at most \(maximum) files")
        }
        let merged = settings.merged(over: tool.defaultSettings)
        for option in tool.options where option.isRequired && option.isVisible(in: merged) {
            if merged.trimmed(option.key).isEmpty {
                throw StudioError.invalidOption(option.label.lowercased(), "it is required")
            }
        }
    }

    public static func run(
        tool: StudioTool, inputs: [URL], settings: StudioSettings = StudioSettings(),
        destination: StudioDestination, environment: StudioEnvironment,
        fileManager: FileManager = .default,
        progress: @escaping @Sendable (StudioProgress) -> Void = { _ in }
    ) async throws -> StudioRunResult {
        try validate(tool: tool, inputs: inputs, settings: settings)
        if let missing = environment.missing(for: tool).first {
            if case let .engine(engine) = missing { throw StudioError.needsEngine(engine) }
            throw StudioError.unavailable("\(tool.title) needs \(missing.title) on this Mac.")
        }
        guard let perform = tool.perform else { throw StudioError.cancelled }
        let merged = settings.merged(over: tool.defaultSettings)
        let staging = environment.temporaryRoot.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let units: [[URL]] = tool.arity == .each ? inputs.map { [$0] } : [inputs]
        var outputs: [StudioOutputFile] = []
        var failures: [StudioFailure] = []
        var notes: [String] = []
        var folders: [URL] = []
        var firstError: Error?
        for (index, unitInputs) in units.enumerated() {
            if Task.isCancelled { throw StudioError.cancelled }
            let work = staging.appendingPathComponent("unit-\(index)", isDirectory: true)
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            let reporter = StudioRunReporter(unit: index, units: units.count, sink: progress)
            let run = StudioRun(
                tool: tool, inputs: unitInputs, settings: merged, workDirectory: work,
                environment: environment, reporter: reporter)
            do {
                let produced = try await perform(run)
                if Task.isCancelled { throw StudioError.cancelled }
                guard !produced.isEmpty else {
                    throw StudioError.nothingToDo("\(tool.title) produced no files.")
                }
                let placed = try place(
                    produced, from: unitInputs, tool: tool, destination: destination,
                    fileManager: fileManager)
                outputs += placed.files
                if let folder = placed.folder { folders.append(folder) }
                notes += reporter.collectedNotes.filter { !notes.contains($0) }
                reporter.progress(1)
            } catch let error as StudioError where error == .cancelled {
                throw error
            } catch is CancellationError {
                throw StudioError.cancelled
            } catch {
                if firstError == nil { firstError = error }
                let name = unitInputs.first?.lastPathComponent ?? tool.title
                failures.append(StudioFailure(file: name, message: error.localizedDescription))
            }
        }
        if outputs.isEmpty, let firstError { throw firstError }
        let inputBytes = inputs.reduce(Int64(0)) { $0 + fileSize($1, fileManager: fileManager) }
        return StudioRunResult(
            toolID: tool.id, outputs: outputs, inputBytes: inputBytes, notes: notes,
            failures: failures, folders: folders)
    }

    static func place(
        _ produced: [URL], from inputs: [URL], tool: StudioTool, destination: StudioDestination,
        fileManager: FileManager
    ) throws -> (files: [StudioOutputFile], folder: URL?) {
        var directory = try destinationDirectory(
            destination, for: inputs.first, fileManager: fileManager)
        var folder: URL?
        if tool.groupsOutputs, produced.count > 1 {
            let stem = inputs.first?.studioStem ?? StudioNaming.safeStem(tool.title)
            let suffix = tool.title.lowercased().replacingOccurrences(of: " ", with: "-")
            let grouped = StudioNaming.unique(
                directory.appendingPathComponent("\(stem) \(suffix)", isDirectory: true),
                fileManager: fileManager)
            try fileManager.createDirectory(at: grouped, withIntermediateDirectories: true)
            directory = grouped
            folder = grouped
        }
        var files: [StudioOutputFile] = []
        for file in produced {
            let target = StudioNaming.unique(
                directory.appendingPathComponent(file.lastPathComponent), fileManager: fileManager)
            try fileManager.moveItem(at: file, to: target)
            files.append(
                StudioOutputFile(
                    url: target, kind: target.studioKind,
                    bytes: fileSize(target, fileManager: fileManager),
                    source: inputs.count == 1 ? inputs[0] : nil))
        }
        return (files, folder)
    }

    public static func destinationDirectory(
        _ destination: StudioDestination, for input: URL?, fileManager: FileManager = .default
    ) throws -> URL {
        let fallback =
            fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory: URL
        switch destination {
        case let .folder(url):
            directory = url
        case .nextToOriginal:
            directory = input?.deletingLastPathComponent() ?? fallback
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return fallback
        }
        return fileManager.isWritableFile(atPath: directory.path) ? directory : fallback
    }

    public static func fileSize(_ url: URL, fileManager: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }
        let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
