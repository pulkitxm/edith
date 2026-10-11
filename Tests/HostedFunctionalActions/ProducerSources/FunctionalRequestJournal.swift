import Foundation

@MainActor
final class FunctionalRequestJournal {
    enum Event: String, CaseIterable {
        case hostBefore = "before-original-request"
        case engineBefore = "before-engine-receiver"
        case engineAfter = "after-engine-receiver"
        case hostAfter = "after-original-response"
        case nativeReply = "native-emitted-reply"
    }

    struct Record {
        let ordinal: Int
        let event: Event
        let token: String
        let operation: String
        let presentationID: String
        let payloadSHA256: String
        let responseSHA256: String?
        let caller: FunctionalBirth
        let outcome: Bool?
    }

    private struct Pending {
        let operation: String
        let payloadSHA256: String
        let payloadBytes: Int
        var next: Event
        var responseSHA256: String?
        var outcome: Bool?
    }

    private let held: FunctionalHeldPresentation
    private var pending: [String: Pending] = [:]
    private var completed = Set<String>()
    private(set) var records: [Record] = []
    private var failed = false

    init(held: FunctionalHeldPresentation) throws {
        try held.requireCurrent()
        self.held = held
    }

    func receive(event: Event, caller: FunctionalBirth, fields: [String: Any]) throws {
        guard !failed else { throw FunctionalFailure.invalid("failed original request journal") }
        do { try record(event: event, caller: caller, fields: fields) }
        catch { failed = true; throw error }
    }

    func requireComplete() throws {
        guard !failed, pending.isEmpty, !records.isEmpty else {
            throw FunctionalFailure.invalid("incomplete actual original request journal") }
        try held.requireCurrent()
    }

    func completedRequests(operation: String) throws -> [Record] {
        try requireComplete()
        guard held.capability.operations.contains(operation) else {
            throw FunctionalFailure.invalid("uncompiled original operation selection") }
        return records.filter { $0.event == .nativeReply && $0.operation == operation && $0.outcome == true }
    }

    private func record(event: Event, caller: FunctionalBirth, fields: [String: Any]) throws {
        guard records.count < 4096, let request = fields["request"] as? [String: Any] else {
            throw FunctionalFailure.invalid("bounded actual request event") }
        let engineReceiver = event == .engineBefore || event == .engineAfter
        try held.requireObserver(caller, engineReceiver: engineReceiver)
        guard let token = request["token"] as? String, FunctionalBytes.uuid(token),
            engineReceiver || request["presentationID"] as? String == held.presentationID,
            let operation = request["operation"] as? String, held.capability.operations.contains(operation),
            let payloadSHA256 = request["payloadSHA256"] as? String, FunctionalBytes.hex(payloadSHA256, length: 64),
            let payloadBytes = Int(exactly: try FunctionalBytes.integer(request, "payloadBytes")),
            payloadBytes >= 0, payloadBytes <= 1_048_576
        else { throw FunctionalFailure.invalid("source original request correlation") }
        if let text = request["payload"] as? String {
            guard held.capability.owner != "jev", let bytes = Data(base64Encoded: text),
                bytes.base64EncodedString() == text, bytes.count == payloadBytes,
                FunctionalBytes.digest(bytes) == payloadSHA256
            else { throw FunctionalFailure.invalid("actual request payload bytes") }
        } else if held.capability.owner != "jev" { throw FunctionalFailure.invalid("missing original payload bytes") }
        if !engineReceiver {
            guard let source = fields["ui"] as? [String: Any],
                try FunctionalBytes.canonical(source.filter { $0.key != "codeHash" }) == FunctionalBytes.canonical(held.ui.object)
            else { throw FunctionalFailure.invalid("actual original UI source birth") }
        }
        let expectedReceiver = engineReceiver ? held.engine : caller
        guard let receiver = fields["receiver"] as? [String: Any],
            try FunctionalBytes.canonical(receiver) == FunctionalBytes.canonical(expectedReceiver.object)
        else { throw FunctionalFailure.invalid("actual receiver kernel birth") }
        if engineReceiver {
            guard let source = fields["source"] as? [String: Any] else {
                throw FunctionalFailure.invalid("actual original engine socket sender") }
            let birth = try JSONDecoder().decode(FunctionalBirth.self, from: FunctionalBytes.canonical(source))
            try held.requireForwardingSource(birth)
        }
        var responseSHA256: String?
        var outcome: Bool?
        switch event {
        case .hostBefore:
            guard pending.count < 8, pending[token] == nil, !completed.contains(token) else {
                throw FunctionalFailure.invalid("replayed original request token") }
            pending[token] = Pending(operation: operation, payloadSHA256: payloadSHA256,
                payloadBytes: payloadBytes, next: .engineBefore)
        case .engineBefore, .engineAfter, .hostAfter, .nativeReply:
            guard var current = pending[token], current.next == event,
                current.operation == operation, current.payloadSHA256 == payloadSHA256,
                current.payloadBytes == payloadBytes else { throw FunctionalFailure.invalid("out of order original request event") }
            if event != .engineBefore {
                let result = fields[event == .nativeReply ? "reply" : "result"] as? [String: Any]
                guard let result else { throw FunctionalFailure.invalid("actual original response outcome") }
                let ok = try FunctionalBytes.boolean(result, "ok")
                outcome = ok
                if ok {
                    guard let digest = result["payloadSHA256"] as? String, FunctionalBytes.hex(digest, length: 64),
                        try FunctionalBytes.integer(result, "payloadBytes") >= 0,
                        try FunctionalBytes.integer(result, "payloadBytes") <= 1_048_576 else {
                        throw FunctionalFailure.invalid("actual original response payload") }
                    responseSHA256 = digest
                    if let text = result["payload"] as? String {
                        guard held.capability.owner != "jev", let bytes = Data(base64Encoded: text),
                            bytes.base64EncodedString() == text,
                            bytes.count == (try FunctionalBytes.integer(result, "payloadBytes")),
                            FunctionalBytes.digest(bytes) == digest else { throw FunctionalFailure.invalid("actual response bytes changed") }
                    } else if held.capability.owner != "jev" { throw FunctionalFailure.invalid("missing actual response bytes") }
                }
                if event == .engineAfter { current.responseSHA256 = responseSHA256; current.outcome = outcome }
                else { guard current.responseSHA256 == responseSHA256, current.outcome == outcome else {
                    throw FunctionalFailure.invalid("original response changed between receiver and native reply") } }
                if event == .nativeReply {
                    guard result["token"] as? String == token,
                        let wire = fields["encodedReplySHA256"] as? String, FunctionalBytes.hex(wire, length: 64)
                    else { throw FunctionalFailure.invalid("actual native encoded reply token") }
                }
            }
            switch event {
            case .engineBefore: current.next = .engineAfter
            case .engineAfter: current.next = .hostAfter
            case .hostAfter: current.next = .nativeReply
            case .nativeReply:
                pending.removeValue(forKey: token)
                completed.insert(token)
            case .hostBefore: throw FunctionalFailure.invalid("duplicate original start")
            }
            if event != .nativeReply { pending[token] = current }
        }
        try held.requireCurrent()
        records.append(Record(ordinal: records.count, event: event, token: token, operation: operation,
            presentationID: held.presentationID, payloadSHA256: payloadSHA256,
            responseSHA256: responseSHA256, caller: caller, outcome: outcome))
    }
}
