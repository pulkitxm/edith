import CryptoKit
import EdithExtensionSupport
import Foundation

actor CodeStatsCommands {
    private let workflow: CodeStatsWorkflow
    private let store: CodeStatsStore
    private let defaults: UserDefaults
    private let home: URL
    private var result: Data?
    private var resultID: UUID?
    private var expiry: Task<Void, Never>?
    private var stopped = false

    init(
        workflow: CodeStatsWorkflow, store: CodeStatsStore,
        defaults: UserDefaults = SharedDefaults.store,
        home: URL = CodeStatsExecutionEnvironment.home
    ) {
        self.workflow = workflow; self.store = store; self.defaults = defaults; self.home = home
    }

    func shutdown() { stopped = true; clearResult() }

    func execute(_ command: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped, payload.count <= 131_072,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        let data: Data
        switch command {
        case CodeStatsCommand.status, CodeStatsCommand.authors, CodeStatsCommand.profile,
            CodeStatsCommand.cancel:
            try empty(object)
            data = try await workflow.perform(operation: command, payload: Data())
        case CodeStatsCommand.start:
            try empty(object)
            data = try await workflow.perform(operation: command, payload: Data())
        case CodeStatsCommand.report, CodeStatsCommand.audit:
            let query = try query(object)
            if command == CodeStatsCommand.report {
                data = try await workflow.perform(
                    operation: command, payload: JSONEncoder().encode(query))
            } else {
                data = try await workflow.perform(
                    operation: command, payload: JSONEncoder().encode(query.filter))
            }
        case CodeStatsCommand.facts:
            try empty(object)
            data = try await workflow.perform(operation: command, payload: Data())
        case "codeStats.folder":
            guard Set(object.keys) == ["path", "confirm"], object["confirm"] as? Bool == true,
                let path = object["path"] as? String, !path.isEmpty, path.utf8.count <= 4_096,
                !path.utf8.contains(0)
            else { throw ExtensionPeerError.invalidRequest }
            let resolved = CodeStatsPaths.standardizedURL(path, homeDirectory: home)
            if CodeStatsExecutionEnvironment.fixtureHome != nil,
                resolved != home && !resolved.path.hasPrefix(home.path + "/")
            {
                throw ExtensionPeerError.invalidRequest
            }
            let selection = try CodeStatsPreferences.selectFolder(
                path, defaults: defaults, homeDirectory: home)
            await workflow.settingsChanged()
            data = try JSONEncoder().encode(selection)
        case "codeStats.schedule":
            guard Set(object.keys).isSubset(of: ["kind", "hour", "weekday"]),
                let kind = object["kind"] as? String,
                let value = CodeStatsScheduleKind(rawValue: kind)
            else { throw ExtensionPeerError.invalidRequest }
            let hour = try integer(
                object["hour"], default: CodeStatsPreferences.defaultHour, range: 0...23)
            let weekday = try integer(
                object["weekday"], default: CodeStatsPreferences.defaultWeekday, range: 1...7)
            let schedule: CodeStatsSchedule =
                value == .manual
                ? .manual
                : value == .daily ? .daily(hour: hour) : .weekly(weekday: weekday, hour: hour)
            CodeStatsPreferences.setSchedule(schedule, in: defaults)
            await workflow.settingsChanged()
            data = try JSONEncoder().encode(schedule)
        case "codeStats.identity.list":
            try empty(object);
            data = try JSONEncoder().encode(CodeStatsPreferences.identity(in: defaults))
        case "codeStats.identity.add", "codeStats.identity.remove":
            guard Set(object.keys) == ["value"], let text = object["value"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                text.utf8.count <= 256, !text.utf8.contains(0),
                CodeStatsPreferences.identity(in: defaults).labels.count < 100
                    || command.hasSuffix("remove")
            else { throw ExtensionPeerError.invalidRequest }
            if command.hasSuffix("add") {
                _ = CodeStatsPreferences.addIdentity(text, in: defaults)
            } else {
                _ = CodeStatsPreferences.removeIdentity(text, in: defaults)
            }
            await workflow.settingsChanged()
            data = try JSONEncoder().encode(CodeStatsPreferences.identity(in: defaults))
        case "codeStats.export":
            guard let text = object["card"] as? String,
                let card = CodeStatsExportCard(rawValue: text)
            else { throw ExtensionPeerError.invalidRequest }
            var selection = object; selection.removeValue(forKey: "card")
            let query = try query(selection)
            let reportData = try await workflow.perform(
                operation: CodeStatsCommand.report, payload: JSONEncoder().encode(query))
            guard let report = try JSONDecoder().decode(CodeStatsReport?.self, from: reportData)
            else { throw ExtensionPeerError.unavailable }
            let snapshot = CodeStatsExportSnapshot(report: report)
            let image = try await MainActor.run {
                try CodeStatsExportRenderer.pngData(snapshot: snapshot, card: card)
            }
            try Task.checkCancellation()
            guard image.count <= 4_194_304 else { throw ExtensionPeerError.invalidRequest }
            data = try JSONEncoder().encode(
                SharedImage(filename: card.filenameStem + ".png", data: image))
        case "codeStats.result.chunk":
            guard Set(object.keys) == ["resultID", "offset"],
                let text = object["resultID"] as? String,
                UUID(uuidString: text) == resultID, let result
            else { throw ExtensionPeerError.invalidRequest }
            let offset = try integer(
                object["offset"], default: -1, range: 0...max(0, result.count - 1))
            let end = min(result.count, offset + 262_144)
            let chunk = try JSONEncoder().encode(
                Chunk(
                    offset: offset, data: result.subdata(in: offset..<end),
                    finished: end == result.count))
            if end == result.count { clearResult() }
            return chunk
        default: throw ExtensionPeerError.invalidRequest
        }
        return try publish(data)
    }

    private func publish(_ data: Data) throws -> Data {
        try Task.checkCancellation()
        guard !stopped, data.count <= CodeStatsOwnedIO.maximumFileBytes else {
            throw ExtensionPeerError.invalidRequest
        }
        if data.count <= 4_194_304 { return data }
        clearResult(); result = data; resultID = UUID()
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            await self?.clearResult()
        }
        return try JSONEncoder().encode(
            Receipt(
                resultID: resultID!, byteCount: data.count,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }

    private func query(_ object: [String: Any]) throws -> CodeStatsReportQuery {
        let text = object["range"] as? String ?? "90d"
        guard Set(object.keys).isSubset(of: ["range", "filter"]),
            object["range"] == nil || object["range"] is String,
            text.utf8.count <= 32,
            let range = CodeStatsRange(argument: text)
        else { throw ExtensionPeerError.invalidRequest }
        switch range {
        case .days(let count):
            guard (1...36_525).contains(count) else { throw ExtensionPeerError.invalidRequest }
        case .between(let start, let end):
            guard SurfaceCalendarDay.parse(start) != nil, SurfaceCalendarDay.parse(end) != nil,
                let first = CodeStatsDay(start), let last = CodeStatsDay(end),
                first.distance(to: last) <= 36_525
            else { throw ExtensionPeerError.invalidRequest }
        case .all, .year: break
        }
        var filter = CodeStatsFilter.default
        if let value = object["filter"] {
            guard let dictionary = value as? [String: Any],
                Set(dictionary.keys).isSubset(of: [
                    "repositories", "owners", "languages", "categories", "includeBulk",
                    "includeFormatting", "includeAgentAssisted", "includeCoAuthored",
                    "excludedRepositories",
                ])
            else { throw ExtensionPeerError.invalidRequest }
            filter = try JSONDecoder().decode(
                CodeStatsFilter.self, from: JSONSerialization.data(withJSONObject: dictionary))
        }
        let sets = [
            filter.repositories, filter.excludedRepositories, filter.owners, filter.languages,
        ]
        guard
            sets.allSatisfy({
                $0.count <= 100
                    && $0.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains(0) }
            })
        else { throw ExtensionPeerError.invalidRequest }
        return CodeStatsReportQuery(range, filter: filter)
    }

    private func integer(_ value: Any?, default fallback: Int, range: ClosedRange<Int>) throws
        -> Int
    {
        guard let value else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
            number.doubleValue >= Double(range.lowerBound),
            number.doubleValue <= Double(range.upperBound)
        else { throw ExtensionPeerError.invalidRequest }
        return number.intValue
    }

    private func empty(_ object: [String: Any]) throws {
        guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
    }
    private func clearResult() { expiry?.cancel(); expiry = nil; result = nil; resultID = nil }
    struct SharedImage: Codable { let filename: String; let data: Data }
    struct Receipt: Codable { let resultID: UUID; let byteCount: Int; let sha256: String }
    struct Chunk: Codable { let offset: Int; let data: Data; let finished: Bool }
}
