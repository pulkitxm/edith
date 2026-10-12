import Foundation
import Network

enum ExtensionPeerFailureDiagnostics {
    enum Stage: String, CaseIterable, Hashable, Sendable {
        case registrationOpen = "registration_open"
        case registrationMetadata = "registration_metadata"
        case registrationRead = "registration_read"
        case registrationDecode = "registration_decode"
        case registrationLogicalName = "registration_logical_name"
        case registrationPhysicalName = "registration_physical_name"
        case registrationProcess = "registration_process"
        case connectionFailed = "connection_failed"
        case sendFailed = "send_failed"
        case responseReadUnavailable = "response_read_unavailable"
        case serverPeerCredentials = "server_peer_credentials"
        case serverPeerUID = "server_peer_uid"
        case serverPeerPID = "server_peer_pid"
        case serverPeerPIDSize = "server_peer_pid_size"
        case serverPeerIdentity = "server_peer_identity"
        case serverSocketConfiguration = "server_socket_configuration"
        case serverAuthentication = "server_authentication"
        case serverReceive = "server_receive"
        case serverAdmission = "server_admission"
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private var seen: Set<Stage> = []
        private let sink: @Sendable (Data) -> Void

        init(capacity: Int = 16, sink: @escaping @Sendable (Data) -> Void) {
            remaining = min(16, max(0, capacity))
            self.sink = sink
        }

        func report(_ stage: Stage?, errorNumber: Int32? = nil) {
            guard let stage else { return }
            let admitted = lock.withLock {
                guard remaining > 0, seen.insert(stage).inserted else { return false }
                remaining -= 1
                return true
            }
            guard admitted else { return }
            var fields: [String: Any] = ["stage": stage.rawValue]
            if let errorNumber, (1...4095).contains(errorNumber) { fields["errno"] = errorNumber }
            guard let data = try? JSONSerialization.data(withJSONObject: ["peerFailure": fields])
            else { return }
            sink(data + Data([10]))
        }
    }

    private static let recorder = Recorder { FileHandle.standardError.write($0) }

    static func report(_ stage: Stage, errorNumber: Int32? = nil) {
        recorder.report(stage, errorNumber: errorNumber)
    }

    static func report(_ stage: Stage, networkError: NWError?) {
        if let networkError, case let .posix(code) = networkError {
            report(stage, errorNumber: code.rawValue)
        } else {
            report(stage)
        }
    }
}
