import Darwin
import Foundation

@MainActor
final class FunctionalProducerReceiver {
    private let root: FunctionalPinnedPath
    private let issuer: FunctionalIssuer
    private let producer: FunctionalBirth
    private var socket: FunctionalHostSocket?
    private var held: FunctionalHeldPresentation?
    private var journal: FunctionalRequestJournal?
    private var requestIDs = Set<String>()
    private var closed = false

    init(root: FunctionalPinnedPath, issuer: FunctionalIssuer, producer: FunctionalBirth) throws {
        self.root = root
        self.issuer = issuer
        self.producer = producer
        try root.requireCurrent()
        try producer.requireCurrent()
        socket = try FunctionalHostSocket(root: root, endpoint: .producer) { [weak self] caller, message in
            guard let self else { throw FunctionalFailure.invalid("released producer receiver") }
            return try self.receive(caller, message)
        }
    }

    func requireHealthy() throws {
        guard !closed, let socket else { throw FunctionalFailure.invalid("closed producer receiver") }
        try root.requireCurrent()
        try producer.requireCurrent()
        try socket.requireHealthy()
    }

    func hold(_ value: FunctionalHeldPresentation) throws {
        try requireHealthy()
        guard held == nil, journal == nil else { throw FunctionalFailure.invalid("active original receiver generation") }
        let next = try FunctionalRequestJournal(held: value)
        held = value
        journal = next
    }

    func retire(_ value: FunctionalHeldPresentation) throws {
        try requireHealthy()
        guard held === value, let journal else { throw FunctionalFailure.invalid("unheld original receiver generation") }
        try value.requireCompletedOriginalSteps()
        try journal.requireRetired()
        self.journal = nil
        held = nil
    }

    func closeAndJoin() async throws {
        guard !closed, let socket else { throw FunctionalFailure.invalid("producer receiver already joined") }
        closed = true
        try await socket.closeAndJoin()
        self.socket = nil
    }

    private func receive(_ caller: FunctionalSocketPeer, _ message: [String: Any]) throws -> Data {
        try requireHealthy()
        guard try FunctionalBytes.integer(message, "schema") == 1,
            message["sourceCommit"] as? String == issuer.sourceCommit,
            message["session"] as? String == issuer.session,
            let requestID = message["requestID"] as? String, FunctionalBytes.uuid(requestID),
            requestIDs.count < 4096, requestIDs.insert(requestID).inserted,
            let operation = message["operation"] as? String,
            let owner = message["owner"] as? String,
            let event = FunctionalRequestJournal.Event(rawValue: operation)
        else { throw FunctionalFailure.invalid("source-owned original receiver event") }
        guard let held, let journal, held.capability.owner == owner else {
            throw FunctionalFailure.invalid("original receiver has no admitted held generation") }
        let common: Set<String> = ["schema", "sourceCommit", "session", "requestID", "operation", "owner"]
        let eventFields: Set<String>
        switch event {
        case .hostBefore: eventFields = ["ui", "engine", "receiver", "request"]
        case .engineBefore: eventFields = ["source", "receiver", "request", "endpoint"]
        case .engineAfter: eventFields = ["source", "receiver", "request", "endpoint", "result"]
        case .hostAfter: eventFields = ["ui", "engine", "receiver", "request", "result"]
        case .nativeReply: eventFields = ["ui", "receiver", "request", "reply", "encodedReplySHA256"]
        }
        try FunctionalBytes.exact(message, common.union(eventFields))
        try journal.receive(event: event, caller: caller.birth,
            fields: message.filter { eventFields.contains($0.key) })
        try requireHealthy()
        return try issuer.seal(["schema": 1, "sourceCommit": issuer.sourceCommit,
            "session": issuer.session, "requestID": requestID, "operation": operation,
            "owner": owner, "phase": held.capability.phase,
            "capabilitySHA256": held.capabilitySHA256, "presentationID": held.presentationID,
            "eventOrdinal": journal.records.count - 1])
    }
}
