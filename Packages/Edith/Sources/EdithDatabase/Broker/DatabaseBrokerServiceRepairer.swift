import Darwin
import Dispatch
import Foundation

public struct DatabaseBrokerServiceRepairer: Sendable {
    private static let releaseBudgetNanoseconds: UInt64 = 3_000_000_000
    private static let retryDelayNanoseconds: UInt64 = 25_000_000

    private let paths: DatabaseBrokerPaths

    public init() {
        paths = DatabaseBrokerPaths()
    }

    init(paths: DatabaseBrokerPaths) {
        self.paths = paths
    }

    public func repair() async throws {
        try Task.checkCancellation()
        guard let processIdentifier = try stopSocketOwner() else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(
            Self.releaseBudgetNanoseconds)
        let releaseDeadline = deadline.overflow ? UInt64.max : deadline.partialValue
        while processIsRunning(processIdentifier) {
            try Task.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < releaseDeadline else {
                throw DatabaseBrokerAvailabilityError.readinessTimedOut
            }
            try await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
        }
    }

    private func stopSocketOwner() throws -> pid_t? {
        let connection: DatabaseBrokerSocketConnection
        do {
            connection = try DatabaseBrokerSocketConnection.connect(
                paths: paths,
                timeoutMilliseconds: 250)
        } catch DatabaseBrokerSocketError.socketNotFound,
            DatabaseBrokerSocketError.connectionRefused
        {
            return nil
        } catch {
            throw DatabaseBrokerAvailabilityError.unavailable
        }
        defer { connection.close() }

        return try connection.withSocketDescriptor { descriptor in
            let identity = try peerIdentity(socketDescriptor: descriptor)
            guard
                identity.userIdentifier == geteuid(),
                identity.processIdentifier > 1,
                identity.processIdentifier != getpid()
            else {
                throw DatabaseBrokerAvailabilityError.unsafePeer
            }
            let executablePath = try processPath(identity.processIdentifier)
            do {
                try DatabaseBrokerExecutableCandidateValidator().validate(
                    path: executablePath)
            } catch {
                throw DatabaseBrokerAvailabilityError.unsafePeer
            }
            guard kill(identity.processIdentifier, SIGTERM) == 0 || errno == ESRCH else {
                throw DatabaseBrokerAvailabilityError.unavailable
            }
            return identity.processIdentifier
        }
    }

    private func peerIdentity(socketDescriptor: Int32) throws -> PeerIdentity {
        var userIdentifier = uid_t()
        var groupIdentifier = gid_t()
        guard getpeereid(socketDescriptor, &userIdentifier, &groupIdentifier) == 0 else {
            throw DatabaseBrokerAvailabilityError.unsafePeer
        }
        var processIdentifier = pid_t()
        var processIdentifierLength = socklen_t(MemoryLayout<pid_t>.size)
        guard
            getsockopt(
                socketDescriptor,
                SOL_LOCAL,
                LOCAL_PEERPID,
                &processIdentifier,
                &processIdentifierLength) == 0,
            processIdentifierLength == socklen_t(MemoryLayout<pid_t>.size)
        else {
            throw DatabaseBrokerAvailabilityError.unsafePeer
        }
        return PeerIdentity(
            userIdentifier: userIdentifier,
            processIdentifier: processIdentifier)
    }

    private func processPath(_ processIdentifier: pid_t) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        let length = proc_pidpath(
            processIdentifier,
            &buffer,
            UInt32(buffer.count))
        guard length > 0 else {
            throw DatabaseBrokerAvailabilityError.unsafePeer
        }
        return String(cString: buffer)
    }

    private func processIsRunning(_ processIdentifier: pid_t) -> Bool {
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }
}

private struct PeerIdentity {
    let userIdentifier: uid_t
    let processIdentifier: pid_t
}
