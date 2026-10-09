import Foundation

struct CameraCarrierRestartRequired: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CameraCarrierOperation: String, Codable, Sendable {
    case activate, deactivate, status, cancel, microphonePrepare
}

struct CameraCarrierRequest: Codable, Sendable {
    let token: UUID
    let operation: CameraCarrierOperation
    var cancelledToken: UUID?
}

struct CameraCarrierStatus: Codable, Equatable, Sendable {
    let phase: String
    let ownsProvider: Bool
    let pending: Bool
    var message: String?

    init(phase: String, ownsProvider: Bool, pending: Bool, message: String? = nil) {
        self.phase = phase; self.ownsProvider = ownsProvider; self.pending = pending;
        self.message = message
    }

    var isValid: Bool {
        [
            "idle", "activating", "awaitingApproval", "active", "deactivating", "stopped",
            "restartRequired", "failed",
        ].contains(phase)
            && (message?.utf8.count ?? 0) <= 4096
            && (!["active", "activating", "awaitingApproval", "deactivating", "restartRequired"]
                .contains(phase) || ownsProvider)
            && (!["idle", "stopped"].contains(phase) || !ownsProvider)
    }

    @MainActor init(_ controller: CameraSystemExtensionController) {
        ownsProvider = controller.ownsProvider
        pending = controller.pendingRequest
        switch controller.phase {
        case .idle: phase = "idle"
        case .activating: phase = "activating"
        case .awaitingApproval: phase = "awaitingApproval"
        case .active: phase = "active"
        case .deactivating: phase = "deactivating"
        case .stopped: phase = "stopped"
        case .restartRequired: phase = "restartRequired"
        case .failed(let error): phase = "failed"; message = String(error.prefix(1024))
        }
    }
}

struct CameraCarrierReply: Codable, Sendable {
    let token: UUID?
    let status: CameraCarrierStatus
    var error: String?
}

struct CameraCarrierFrames {
    static let maximumBytes = 32_768
    private var data = Data()

    mutating func append(_ incoming: Data) throws -> [Data] {
        guard incoming.count <= Self.maximumBytes,
            data.count <= Self.maximumBytes - incoming.count
        else { throw CocoaError(.fileReadCorruptFile) }
        data.append(incoming)
        var result: [Data] = []
        while let newline = data.firstIndex(of: 10) {
            let frame = Data(data[..<newline])
            guard !frame.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            result.append(frame)
            data.removeSubrange(...newline)
        }
        return result
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count < maximumBytes else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return encoded + Data([10])
    }
}
