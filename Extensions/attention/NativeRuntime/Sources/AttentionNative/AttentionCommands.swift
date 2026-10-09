@_implementationOnly import EdithExtensionSupport
import Foundation

struct AttentionFocusRequest: Codable, Sendable {
    var name: String
    var duration: TimeInterval
}

struct AttentionAgentBatch: Codable, Sendable {
    var hosts: [AttentionAgentHost]
}

enum AttentionCommands {
    static func execute(_ command: String, payload: Data, service: AttentionBackgroundService)
        async throws -> Data
    {
        guard payload.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        try Task.checkCancellation()
        switch command {
        case AttentionDeliveryClient.operation:
            guard payload.count <= 16_384 else { throw ExtensionPeerError.invalidRequest }
            let request = try AttentionPayload.decode(AttentionDeliveryRequest.self, from: payload)
            try await service.deliver(request)
            return try AttentionPayload.encode(["sequence": request.sequence])
        case AttentionDeliveryClient.statusOperation:
            try empty(payload)
            return try await AttentionPayload.encode(service.deliveryHealth())
        case AttentionOperation.record:
            let batch = try AttentionPayload.decode(AttentionBatch.self, from: payload)
            let admitted = try AttentionAdmission.batch(
                batch, settings: service.dataRepository.loadSettings())
            try await service.record(admitted)
            return try AttentionPayload.encode(["recorded": admitted.events.count])
        case AttentionOperation.range:
            let request = try AttentionPayload.decode(AttentionRangeRequest.self, from: payload)
            try interval(from: request.from, to: request.to)
            return try await AttentionPayload.encode(service.range(request))
        case AttentionOperation.summary:
            let request = try AttentionPayload.decode(AttentionSummaryRequest.self, from: payload)
            try interval(from: request.from, to: request.to, allTime: request.allTime)
            if let settings = request.settings { try AttentionAdmission.settings(settings) }
            return try await AttentionPayload.encode(service.summary(request))
        case AttentionOperation.hasEvents:
            try empty(payload)
            return try await AttentionPayload.encode(service.hasEvents())
        case AttentionOperation.importLegacy:
            try empty(payload)
            return try await AttentionPayload.encode(service.importSpool())
        case AttentionOperation.context:
            guard payload.count <= 8_192 else { throw ExtensionPeerError.invalidRequest }
            let context = try AttentionPayload.decode(AttentionAppContext.self, from: payload)
            guard context.bundleID.utf8.count <= 256, context.tags.count <= 32,
                context.tags.allSatisfy({ $0.key.utf8.count <= 80 && $0.value.utf8.count <= 500 })
            else { throw ExtensionPeerError.invalidRequest }
            service.updateContext(context)
            return Data()
        case "attention.agents.record":
            let batch = try AttentionPayload.decode(AttentionAgentBatch.self, from: payload)
            guard batch.hosts.count <= 64, batch.hosts.reduce(0, { $0 + $1.agents.count }) <= 512,
                batch.hosts.flatMap(\.agents).allSatisfy({
                    !$0.id.isEmpty && $0.id.utf8.count <= 256 && $0.kind.utf8.count <= 128
                        && $0.machineName.utf8.count <= 256 && $0.cwd.utf8.count <= 4096
                        && $0.title.utf8.count <= 1024
                })
            else { throw ExtensionPeerError.invalidRequest }
            try await service.recordAgents(batch.hosts)
            return Data()
        case AttentionOperation.categorize:
            try empty(payload)
            return try await AttentionPayload.encode(service.categorize())
        case AttentionOperation.backup:
            try empty(payload); try await service.backup(); return Data()
        case AttentionOperation.restore:
            try empty(payload); try await service.restore(); return Data()
        case "attention.settings.get":
            try empty(payload)
            return try AttentionPayload.encode(service.dataRepository.loadSettings())
        case "attention.settings.set":
            var settings = try AttentionPayload.decode(AttentionSettings.self, from: payload)
            try AttentionAdmission.settings(settings)
            settings.normalizeCategories()
            try service.dataRepository.saveSettings(settings)
            _ = try await service.run()
            return try AttentionPayload.encode(settings)
        case "attention.rules.export":
            try empty(payload)
            let settings = service.dataRepository.loadSettings()
            return try AttentionPayload.encode(
                AttentionRuleDocument(categories: settings.categories, rules: settings.rules))
        case "attention.rules.import":
            let document = try AttentionPayload.decode(AttentionRuleDocument.self, from: payload)
            let settings = try document.applying(to: service.dataRepository.loadSettings())
            try AttentionAdmission.settings(settings)
            try service.dataRepository.saveSettings(settings)
            _ = try await service.run()
            return try AttentionPayload.encode(settings)
        case "attention.focus.start":
            let request = try AttentionPayload.decode(AttentionFocusRequest.self, from: payload)
            guard request.name.utf8.count <= 300, request.duration.isFinite,
                (60...86_400).contains(request.duration)
            else { throw ExtensionPeerError.invalidRequest }
            return try AttentionPayload.encode(
                AttentionFocusOperationExecution.start(
                    name: request.name, duration: request.duration,
                    repository: service.dataRepository))
        case "attention.focus.stop":
            try empty(payload)
            return try AttentionPayload.encode(
                AttentionFocusOperationExecution.stop(repository: service.dataRepository))
        case "attention.focus.get":
            try empty(payload)
            return try AttentionPayload.encode(service.dataRepository.activeFocus())
        case "attention.export":
            let request = try AttentionPayload.decode(AttentionExportRequest.self, from: payload)
            try interval(from: request.from, to: request.to)
            let range = try await service.range(.init(from: request.from, to: request.to))
            return try AttentionExport.render(range.events, format: request.format)
        default: throw ExtensionPeerError.invalidRequest
        }
    }
    static func empty(_ payload: Data) throws {
        guard payload.isEmpty || payload == Data("{}".utf8) else {
            throw ExtensionPeerError.invalidRequest
        }
    }
    static func interval(from: Date, to: Date, allTime: Bool = false) throws {
        guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite,
            to >= from, allTime || to.timeIntervalSince(from) <= 366 * 86_400
        else { throw ExtensionPeerError.invalidRequest }
    }
}

enum AttentionAdmission {
    static func settings(_ settings: AttentionSettings) throws {
        guard settings.categories.count <= 100, settings.rules.count <= 1000,
            settings.serverToken.utf8.count <= 256, settings.idleThreshold.isFinite,
            (0...86_400).contains(settings.idleThreshold), settings.profileNote.utf8.count <= 8192
        else { throw ExtensionPeerError.invalidRequest }
    }
    static func batch(_ batch: AttentionBatch, settings: AttentionSettings) throws -> AttentionBatch
    {
        guard batch.events.count <= 32, batch.pulseTime.isFinite,
            (0...300).contains(batch.pulseTime)
        else { throw ExtensionPeerError.invalidRequest }
        let events = try batch.events.map { event -> AttentionEvent in
            guard !event.id.isEmpty, event.id.utf8.count <= 512, event.duration.isFinite,
                event.duration > 0, event.duration <= 172_800,
                event.startedAt.timeIntervalSince1970.isFinite,
                event.startedAt <= Date().addingTimeInterval(300),
                (event.appName?.utf8.count ?? 0) <= 1024,
                (event.tags?.count ?? 0) <= 32,
                [event.bundleID, event.windowTitle, event.url, event.domain, event.faviconURL]
                    .allSatisfy({ ($0?.utf8.count ?? 0) <= 8192 })
            else { throw ExtensionPeerError.invalidRequest }
            var event = event
            if settings.privacyLevel != .detailed || !settings.windowTitlesEnabled {
                event.windowTitle = nil
            }
            if settings.privacyLevel == .applications {
                event.url = nil; event.domain = nil; event.faviconURL = nil
            } else if var components = event.url.flatMap(URLComponents.init(string:)) {
                components.user = nil; components.password = nil; components.query = nil;
                components.fragment = nil
                if settings.privacyLevel == .domains {
                    event.url = nil
                } else {
                    event.url = components.string
                }
            }
            event.tags = AttentionTag.filtered(event.tags, privacyLevel: settings.privacyLevel)
            return event
        }
        return AttentionBatch(events: events, pulseTime: batch.pulseTime)
    }
}
