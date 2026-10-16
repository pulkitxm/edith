import Darwin
import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite struct ExtensionPeerSocketTests {
    private func pair() throws -> (ExtensionPeerSocketConnection, ExtensionPeerSocketConnection) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw ExtensionPeerError.unavailable
        }
        let first: ExtensionPeerSocketConnection
        do {
            first = try ExtensionPeerSocketConnection(descriptor: descriptors[0])
        } catch {
            Darwin.close(descriptors[1])
            throw error
        }
        let second = try ExtensionPeerSocketConnection(descriptor: descriptors[1])
        return (first, second)
    }

    private func rawWrite(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count else {
                throw ExtensionPeerError.unavailable
            }
        }
    }

    @Test func binaryFrameRoundTripRetainsLengthAndPayload() throws {
        let (sender, receiver) = try pair()
        defer { sender.close(); receiver.close() }
        let payload = Data([0, 255, 1, 127, 10, 13])
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        let deadline = DispatchTime.now() + 1
        try sender.writeFrame(frame, deadline: deadline)
        #expect(try receiver.readFrame(deadline: deadline) == payload)
    }

    @Test(arguments: [Data(), Data([0, 0]), Data([0, 0, 0, 3, 1])])
    func closedAndTruncatedFramesAreUnavailable(_ bytes: Data) throws {
        let (sender, receiver) = try pair()
        defer { sender.close(); receiver.close() }
        if !bytes.isEmpty { try rawWrite(bytes, to: sender.descriptor) }
        sender.close()
        do {
            _ = try receiver.readFrame(deadline: DispatchTime.now() + 1)
            Issue.record("An incomplete frame must fail at EOF.")
        } catch ExtensionPeerError.unavailable {}
    }

    @Test(arguments: [UInt32(0), UInt32(ExtensionPeerEndpoint.maximumMessageBytes + 1), UInt32.max])
    func invalidLengthsFailBeforeReadingOrAllocatingBodies(_ size: UInt32) throws {
        let (sender, receiver) = try pair()
        defer { sender.close(); receiver.close() }
        var size = size.bigEndian
        try rawWrite(withUnsafeBytes(of: &size) { Data($0) }, to: sender.descriptor)
        do {
            _ = try receiver.readFrame(deadline: DispatchTime.now() + 1)
            Issue.record("An invalid length must fail before reading a body.")
        } catch ExtensionPeerError.invalidRequest {}
    }

    private func fill(_ connection: ExtensionPeerSocketConnection) throws {
        var buffer = [UInt8](repeating: 1, count: 16_384)
        for _ in 0..<128 {
            let count = Darwin.write(connection.descriptor, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            guard count > 0 else { throw ExtensionPeerError.unavailable }
        }
        throw ExtensionPeerError.invalidRequest
    }

    @Test func pendingConnectUsesOneMonotonicDeadline() throws {
        let (sender, receiver) = try pair()
        defer { sender.close(); receiver.close() }
        try fill(sender)
        let start = ContinuousClock.now
        let deadline = DispatchTime.now() + 0.08
        do {
            try sender.finishConnection(deadline: deadline)
            Issue.record("A pending connection must not outlive its deadline.")
        } catch ExtensionPeerError.timedOut {}
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func cancelledBlockedReadJoinsBeforeDescriptorRetirement() async throws {
        let (sender, receiver) = try pair()
        defer { sender.close(); receiver.close() }
        let ready = AsyncStream<Void>.makeStream()
        let work = Task.detached {
            ready.continuation.yield(())
            return try receiver.readFrame(deadline: DispatchTime.now() + 30)
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        let start = ContinuousClock.now
        receiver.cancel()
        do {
            _ = try await work.value
            Issue.record("A cancelled socket read must fail.")
        } catch is CancellationError {}
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(fcntl(receiver.descriptor, F_GETFD) >= 0)
        receiver.close()
        #expect(fcntl(receiver.descriptor, F_GETFD) == -1)
    }

    @Test func cancelledBackpressuredWriteJoinsBeforeDescriptorRetirement() async throws {
        let (sender, receiver) = try pair()
        defer { sender.close(); receiver.close() }
        try fill(sender)
        let ready = AsyncStream<Void>.makeStream()
        let work = Task.detached {
            ready.continuation.yield(())
            try sender.writeFrame(
                Data(repeating: 1, count: 16_388),
                deadline: DispatchTime.now() + 30)
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        let start = ContinuousClock.now
        sender.cancel()
        do {
            try await work.value
            Issue.record("A cancelled backpressured write must fail.")
        } catch is CancellationError {}
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(fcntl(sender.descriptor, F_GETFD) >= 0)
        sender.close()
        #expect(fcntl(sender.descriptor, F_GETFD) == -1)
    }

    @Test func repeatedRetirementDoesNotCloseAReusedDescriptor() throws {
        let (sender, receiver) = try pair()
        defer { receiver.close() }
        let retired = sender.descriptor
        sender.close()
        var replacement: Int32?
        for _ in 0..<128 {
            let candidate = open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard candidate >= 0 else { throw ExtensionPeerError.unavailable }
            if candidate == retired {
                replacement = candidate
                break
            }
            Darwin.close(candidate)
        }
        guard let replacement else {
            sender.cancel()
            sender.close()
            return
        }
        defer { Darwin.close(replacement) }
        sender.cancel()
        sender.close()
        #expect(fcntl(retired, F_GETFD) >= 0)
        do {
            _ = try sender.readFrame(deadline: DispatchTime.now() + 1)
            Issue.record("A retired connection must not access a reused descriptor.")
        } catch ExtensionPeerError.unavailable {}
    }

    private func connectedPair() throws
        -> (ExtensionPeerSocketConnection, ExtensionPeerSocketConnection)
    {
        try ExtensionPeerSocket.prepare()
        let path = ExtensionPeerSocket.path("peer-identity-fixture.\(UUID().uuidString)")
        let listener = try ExtensionPeerSocketConnection()
        defer { listener.close(); unlink(path) }
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ExtensionPeerError.unavailable
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener.descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(listener.descriptor, 1) == 0 else {
            throw ExtensionPeerError.unavailable
        }
        let client = try ExtensionPeerSocketConnection()
        try client.connect(path: path, deadline: DispatchTime.now() + 1)
        let accepted = Darwin.accept(listener.descriptor, nil, nil)
        guard accepted >= 0 else { throw ExtensionPeerError.unavailable }
        let server = try ExtensionPeerSocketConnection(descriptor: accepted)
        return (client, server)
    }

    private func waitForPeerDisconnect(
        _ connection: ExtensionPeerSocketConnection, deadline: DispatchTime
    ) throws {
        while true {
            try connection.check(deadline: deadline)
            var pid: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            let result = getsockopt(
                connection.descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size)
            let error = errno
            if result == -1, error == ENOTCONN { return }
            guard result == 0, size == MemoryLayout<Int32>.size else {
                throw ExtensionPeerError.unavailable
            }
            usleep(1_000)
        }
    }

    @Test func revalidationRequiresKernelCapturedPeer() throws {
        let (client, server) = try connectedPair()
        defer { client.close(); server.close() }
        let peer = try #require(ExtensionPeerProcess.read(getpid()))
        do {
            try client.revalidatePeer(expected: peer.birth, deadline: DispatchTime.now() + 1)
            Issue.record("An uncaptured peer must not qualify.")
        } catch ExtensionPeerError.unavailable {}
    }

    @Test func completeResponseCloseRetainsStrictCapturedIdentity() throws {
        let (client, server) = try connectedPair()
        defer { client.close(); server.close() }
        let peer = try #require(ExtensionPeerProcess.read(getpid()))
        let deadline = DispatchTime.now() + 1
        try client.capturePeer(expected: peer.birth, deadline: deadline)
        let request = try ExtensionPeerFrame.encode(Data([1]))
        try client.writeFrame(request, deadline: deadline)
        _ = try server.readFrame(deadline: deadline)
        let payload = Data([0, 255, 1, 127])
        var length = UInt32(payload.count).bigEndian
        var response = withUnsafeBytes(of: &length) { Data($0) }
        response.append(payload)
        try server.writeFrame(response, deadline: deadline)
        server.close()
        try waitForPeerDisconnect(client, deadline: deadline)
        var uid: uid_t = 0
        var gid: gid_t = 0
        #expect(getpeereid(client.descriptor, &uid, &gid) == 0)
        #expect(uid == getuid())
        try client.revalidatePeer(expected: peer.birth, deadline: deadline)
        #expect(try client.readFrame(deadline: deadline) == payload)
        try client.revalidatePeer(expected: peer.birth, deadline: deadline)
        #expect(peer.isCurrent)
    }

    @Test(arguments: [false, true])
    func initialCaptureRejectsWrongExpectedBirth(_ wrongPID: Bool) throws {
        let (client, server) = try connectedPair()
        defer { client.close(); server.close() }
        let peer = try #require(ExtensionPeerProcess.read(getpid()))
        let wrong = ExtensionProcessIdentity(
            pid: wrongPID ? peer.birth.pid + 1 : peer.birth.pid,
            generation: wrongPID ? peer.birth.generation : peer.birth.generation + ".different")
        do {
            try client.capturePeer(expected: wrong, deadline: DispatchTime.now() + 1)
            Issue.record("A mismatched registered process must not qualify.")
        } catch ExtensionPeerError.unavailable {}
        do {
            try client.revalidatePeer(expected: peer.birth, deadline: DispatchTime.now() + 1)
            Issue.record("A failed capture must leave no authenticated peer.")
        } catch ExtensionPeerError.unavailable {}
    }

    @Test func postCloseRevalidationRejectsChangedExpectedBirth() throws {
        let (client, server) = try connectedPair()
        defer { client.close(); server.close() }
        let peer = try #require(ExtensionPeerProcess.read(getpid()))
        let deadline = DispatchTime.now() + 1
        try client.capturePeer(expected: peer.birth, deadline: deadline)
        server.close()
        try waitForPeerDisconnect(client, deadline: deadline)
        let wrong = ExtensionProcessIdentity(
            pid: peer.birth.pid, generation: peer.birth.generation + ".different")
        do {
            try client.revalidatePeer(expected: wrong, deadline: deadline)
            Issue.record("Peer closure must not admit a different process birth.")
        } catch ExtensionPeerError.unavailable {}
    }

    @Test func capturedPeerCannotBeReplacedByAnotherCapture() throws {
        let (client, server) = try connectedPair()
        defer { client.close(); server.close() }
        let peer = try #require(ExtensionPeerProcess.read(getpid()))
        let deadline = DispatchTime.now() + 1
        try client.capturePeer(expected: peer.birth, deadline: deadline)
        do {
            try client.capturePeer(expected: peer.birth, deadline: deadline)
            Issue.record("A captured connection identity must remain immutable.")
        } catch ExtensionPeerError.unavailable {}
        try client.revalidatePeer(expected: peer.birth, deadline: deadline)
    }
}
