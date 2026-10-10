import CoreFoundation
import CryptoKit
import EdithExtensionSupport
import Foundation

@MainActor final class SEOAuditCommands {
    private let service: SEOAuditService
    private var result: Data?
    private var resultID: UUID?
    private var expiry: Task<Void, Never>?
    private var stopped = false

    init(service: SEOAuditService) { self.service = service }
    func shutdown() { stopped = true; clearResult() }

    func execute(_ command: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped, payload.count <= 131_072,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        let data: Data
        switch command {
        case "seoAudit.list":
            try keys(object, required: [], optional: [])
            data = try encode(await service.list())
        case "seoAudit.create":
            try keys(object, required: ["url"], optional: ["name"])
            let url = try string(object, "url", maximum: 4_096)
            let name = object["name"] == nil ? nil : try string(object, "name", maximum: 256)
            data = try encode(await service.create(url: url, name: name))
        case "seoAudit.rename":
            try keys(object, required: ["projectID", "name"], optional: [])
            data = try encode(
                await service.rename(
                    id(object, "projectID"), name: string(object, "name", maximum: 256)))
        case "seoAudit.delete":
            try keys(object, required: ["projectID", "confirm"], optional: [])
            guard try boolean(object, "confirm") else { throw ExtensionPeerError.invalidRequest }
            try await service.delete(id(object, "projectID")); data = try encode(["ok": true])
        case "seoAudit.project", "seoAudit.draft", "seoAudit.stop":
            try keys(object, required: ["projectID"], optional: [])
            let projectID = try id(object, "projectID")
            if command == "seoAudit.project" {
                data = try encode(await service.project(projectID))
            } else if command == "seoAudit.draft" {
                data = try encode(await service.draft(projectID))
            } else {
                data = try encode(await service.stop(projectID))
            }
        case "seoAudit.choose":
            try keys(object, required: ["projectID", "mode"], optional: ["urls"])
            let mode = try string(object, "mode", maximum: 8)
            let urls = try urls(object["urls"])
            let edit: SEOAuditPageEdit
            switch mode {
            case "all":
                guard urls.isEmpty else { throw ExtensionPeerError.invalidRequest }; edit = .all
            case "none":
                guard urls.isEmpty else { throw ExtensionPeerError.invalidRequest }; edit = .none
            case "only": edit = .only(urls)
            case "add": edit = .add(urls)
            case "remove": edit = .remove(urls)
            default: throw ExtensionPeerError.invalidRequest
            }
            data = try encode(await service.choose(id(object, "projectID"), edit: edit))
        case "seoAudit.lighthouse.setting":
            try keys(object, required: ["projectID", "enabled"], optional: [])
            data = try encode(
                await service.setLighthouse(
                    id(object, "projectID"), enabled: boolean(object, "enabled")))
        case "seoAudit.discover":
            try keys(object, required: ["projectID"], optional: ["wait"])
            let wait = try boolean(object, "wait", fallback: false)
            let job = try await service.discover(id(object, "projectID"))
            data = try await response(
                job, runID: nil, wait: wait)
        case "seoAudit.start":
            try keys(object, required: ["projectID"], optional: ["lighthouse", "wait"])
            let lighthouse = object["lighthouse"] == nil ? nil : try boolean(object, "lighthouse")
            let wait = try boolean(object, "wait", fallback: false)
            let launch = try await service.start(id(object, "projectID"), lighthouse: lighthouse)
            data = try await response(
                launch.job, runID: launch.request.runID,
                wait: wait)
        case "seoAudit.lighthouse":
            try keys(object, required: ["projectID", "runID", "url"], optional: ["wait"])
            guard let url = SEOAuditURLInput.normalize(try string(object, "url", maximum: 4_096))
            else { throw ExtensionPeerError.invalidRequest }
            let wait = try boolean(object, "wait", fallback: false)
            let launch = try await service.lighthouse(
                id(object, "projectID"), runID: id(object, "runID"), url: url)
            data = try await response(
                launch.job, runID: launch.request.runID,
                wait: wait)
        case "seoAudit.run":
            try keys(
                object, required: ["projectID"], optional: ["runID", "offset", "query", "severity"])
            let runID = object["runID"] == nil ? nil : try id(object, "runID")
            var run = try await service.run(
                id(object, "projectID"), runID: runID,
                offset: integer(object["offset"], fallback: 0, range: 0...10_000))
            let query =
                object["query"] == nil
                ? "" : try string(object, "query", maximum: 1_024, empty: true)
            var severity: SEOAuditSeverity?
            if object["severity"] != nil {
                guard
                    let value = SEOAuditSeverity(
                        rawValue: try string(object, "severity", maximum: 16))
                else { throw ExtensionPeerError.invalidRequest }
                severity = value
            }
            run.pages = SEOAuditSelection.matching(run.pages, query: query, severity: severity)
            data = try encode(run)
        case "seoAudit.result.chunk":
            try keys(object, required: ["resultID", "offset"], optional: [])
            guard try id(object, "resultID") == resultID, let result else {
                throw ExtensionPeerError.invalidRequest
            }
            let offset = try integer(
                object["offset"], fallback: -1, range: 0...max(0, result.count - 1))
            let end = min(result.count, offset + 262_144)
            let chunk = try encode(
                Chunk(
                    offset: offset, data: result.subdata(in: offset..<end),
                    finished: end == result.count))
            if end == result.count { clearResult() }
            return chunk
        default: throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
        guard !stopped, data.count <= SEOAuditOwnedIO.maximumFileBytes else {
            throw ExtensionPeerError.invalidRequest
        }
        if data.count <= 4_194_304 { return data }
        clearResult(); result = data; resultID = UUID()
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.clearResult()
        }
        return try encode(
            Receipt(
                resultID: resultID!, byteCount: data.count,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }

    private func response(_ job: SEOAuditJob, runID: UUID?, wait: Bool) async throws -> Data {
        if wait {
            switch try await job.value(cancellingOnCancel: true) {
            case .project(let project): return try encode(project)
            case .draft(let draft): return try encode(draft)
            }
        }
        return try encode(
            JobReceipt(taskID: job.id, projectID: job.projectID, runID: runID, kind: job.kind))
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    private func keys(_ object: [String: Any], required: Set<String>, optional: Set<String>) throws
    {
        guard required.isSubset(of: Set(object.keys)),
            Set(object.keys).isSubset(of: required.union(optional))
        else { throw ExtensionPeerError.invalidRequest }
    }
    private func id(_ object: [String: Any], _ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(object, key, maximum: 36)) else {
            throw ExtensionPeerError.invalidRequest
        }; return value
    }
    private func string(_ object: [String: Any], _ key: String, maximum: Int, empty: Bool = false)
        throws -> String
    {
        guard let value = object[key] as? String,
            (empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
            value.utf8.count <= maximum, !value.utf8.contains(0)
        else { throw ExtensionPeerError.invalidRequest }; return value
    }
    private func boolean(_ object: [String: Any], _ key: String, fallback: Bool? = nil) throws
        -> Bool
    {
        guard let value = object[key] else {
            if let fallback { return fallback }; throw ExtensionPeerError.invalidRequest
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ExtensionPeerError.invalidRequest
        }; return number.boolValue
    }
    private func integer(_ value: Any?, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
            number.doubleValue >= Double(range.lowerBound),
            number.doubleValue <= Double(range.upperBound)
        else { throw ExtensionPeerError.invalidRequest }; return number.intValue
    }
    private func urls(_ value: Any?) throws -> [String] {
        guard let value else { return [] }
        guard let values = value as? [String], values.count <= SEOAuditWorkflow.maximumPages,
            Set(values).count == values.count,
            values.allSatisfy({
                $0.utf8.count <= 4_096 && SEOAuditURLInput.normalize($0)?.absoluteString == $0
            })
        else { throw ExtensionPeerError.invalidRequest }; return values
    }
    private func clearResult() { expiry?.cancel(); expiry = nil; result = nil; resultID = nil }
    struct JobReceipt: Codable {
        let taskID: UUID; let projectID: UUID; let runID: UUID?; let kind: SEOAuditJobKind
    }
    struct Receipt: Codable { let resultID: UUID; let byteCount: Int; let sha256: String }
    struct Chunk: Codable { let offset: Int; let data: Data; let finished: Bool }
}
