import Crypto
import Foundation
import Logging
import MongoClient
import MongoCore
import MongoKitten
import NIOCore
import NIOPosix
import NIOSSL

enum MongoDBDatabaseTransportFailure: Error, Equatable, Sendable {
    case cancelled
    case timeout
    case invalidFrame
    case frameTooLarge
    case invalidDocument
    case documentTooLarge
    case authentication
}

typealias MongoDBDatabaseEventLoopFactory = @Sendable () -> MultiThreadedEventLoopGroup
typealias MongoDBDatabaseEventLoopShutdown =
    @Sendable (MultiThreadedEventLoopGroup) async throws -> Void

actor MongoDBDatabaseOwnedEventLoop {
    private enum State {
        case active
        case shuttingDown(Task<Void, Error>)
        case shutDown
    }

    nonisolated let group: MultiThreadedEventLoopGroup
    private let shutdownOperation: MongoDBDatabaseEventLoopShutdown
    private var state = State.active

    init(
        group: MultiThreadedEventLoopGroup,
        shutdownOperation: @escaping MongoDBDatabaseEventLoopShutdown
    ) {
        self.group = group
        self.shutdownOperation = shutdownOperation
    }

    func shutdown() async throws {
        let task: Task<Void, Error>
        switch state {
        case .active:
            let group = group
            let shutdownOperation = shutdownOperation
            task = Task {
                try await shutdownOperation(group)
            }
            state = .shuttingDown(task)
        case let .shuttingDown(existingTask):
            task = existingTask
        case .shutDown:
            return
        }
        do {
            try await task.value
            state = .shutDown
        } catch {
            state = .active
            throw error
        }
    }

    func isShutdown() -> Bool {
        if case .shutDown = state {
            return true
        }
        return false
    }
}

actor MongoDBDatabaseConnectedTransport {
    private var connection: MongoConnection?
    private let channel: any Channel
    private let eventLoop: MongoDBDatabaseOwnedEventLoop
    nonisolated let identity: DatabaseProductIdentity

    init(
        connection: MongoConnection,
        channel: any Channel,
        eventLoop: MongoDBDatabaseOwnedEventLoop,
        identity: DatabaseProductIdentity
    ) {
        self.connection = connection
        self.channel = channel
        self.eventLoop = eventLoop
        self.identity = identity
    }

    func activeConnection() throws -> MongoConnection {
        guard let connection else {
            throw MongoDBDatabaseDriverFailure.connection
        }
        return connection
    }

    func close() async throws {
        let closeError = await closeChannelAndReleaseConnection()
        try await eventLoop.shutdown()
        if let closeError {
            throw closeError
        }
    }

    private func closeChannelAndReleaseConnection() async -> Error? {
        let connection = self.connection
        self.connection = nil
        channel.close(mode: .all, promise: nil)
        let closeError: Error?
        do {
            try await channel.closeFuture.get()
            closeError = nil
        } catch {
            closeError = error
        }
        _ = connection
        return closeError
    }
}

enum MongoDBDatabaseTransport {
    static let maximumFrameBytes = 48_000_000
    static let maximumDocumentBytes = 16_793_600

    static func connect(
        _ plan: MongoDBDatabaseConnectionPlan,
        context: DatabaseAdapterConnectionContext,
        eventLoopFactory: MongoDBDatabaseEventLoopFactory = {
            MultiThreadedEventLoopGroup(numberOfThreads: 1)
        },
        eventLoopShutdown: @escaping MongoDBDatabaseEventLoopShutdown = { group in
            try await group.shutdownGracefully()
        }
    ) async throws -> MongoDBDatabaseConnectedTransport {
        let deadline = try effectiveDeadline(settings: plan.settings, context: context)
        let eventLoop = MongoDBDatabaseOwnedEventLoop(
            group: eventLoopFactory(),
            shutdownOperation: eventLoopShutdown)
        let attempt = MongoDBDatabaseConnectionAttempt()
        let cancellationTask = Task {
            for await reason in await context.cancellation.events() {
                switch reason {
                case .deadlineExceeded:
                    attempt.terminate(.timeout)
                case .userRequested, .sessionDisconnected:
                    attempt.terminate(.cancelled)
                }
                return
            }
        }
        let deadlineTask = Task {
            let delay = max(0, deadline.timeIntervalSinceNow)
            let nanoseconds = UInt64(min(delay * 1_000_000_000, Double(UInt64.max)))
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await context.cancellation.cancel(.deadlineExceeded)
            attempt.terminate(.timeout)
        }

        do {
            let transport = try await withTaskCancellationHandler {
                try await connectToAvailableHost(
                    plan,
                    context: context,
                    deadline: deadline,
                    eventLoop: eventLoop,
                    attempt: attempt)
            } onCancel: {
                attempt.terminate(.cancelled)
            }
            cancellationTask.cancel()
            deadlineTask.cancel()
            attempt.finish()
            return transport
        } catch {
            cancellationTask.cancel()
            deadlineTask.cancel()
            await attempt.closeCurrentChannel()
            do {
                try await eventLoop.shutdown()
            } catch {
                throw MongoDBDatabaseDriverFailure.connection
            }
            if let termination = attempt.termination {
                switch termination {
                case .cancelled:
                    throw CancellationError()
                case .timeout:
                    throw MongoDBDatabaseDriverFailure.timeout
                default:
                    break
                }
            }
            if let failure = error as? MongoDBDatabaseDriverFailure {
                throw failure
            }
            if let failure = error as? MongoDBDatabaseTransportFailure {
                switch failure {
                case .cancelled:
                    throw CancellationError()
                case .timeout:
                    throw MongoDBDatabaseDriverFailure.timeout
                case .authentication:
                    throw MongoDBDatabaseDriverFailure.authentication
                case .invalidFrame, .frameTooLarge, .invalidDocument, .documentTooLarge:
                    throw MongoDBDatabaseDriverFailure.connection
                }
            }
            throw try MongoDBDatabaseDriverErrorClassifier.classify(error)
        }
    }

    private static func connectToAvailableHost(
        _ plan: MongoDBDatabaseConnectionPlan,
        context: DatabaseAdapterConnectionContext,
        deadline: Date,
        eventLoop: MongoDBDatabaseOwnedEventLoop,
        attempt: MongoDBDatabaseConnectionAttempt
    ) async throws -> MongoDBDatabaseConnectedTransport {
        var lastError: Error = MongoDBDatabaseDriverFailure.connection
        for host in plan.settings.hosts {
            try await check(context: context, deadline: deadline, attempt: attempt)
            do {
                return try await connect(
                    plan,
                    host: host,
                    context: context,
                    deadline: deadline,
                    eventLoop: eventLoop,
                    attempt: attempt)
            } catch let failure as MongoDBDatabaseDriverFailure {
                if case .authentication = failure {
                    throw failure
                }
                lastError = failure
            } catch MongoDBDatabaseTransportFailure.authentication {
                throw MongoDBDatabaseDriverFailure.authentication
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            await attempt.closeCurrentChannel()
        }
        throw lastError
    }

    private static func connect(
        _ plan: MongoDBDatabaseConnectionPlan,
        host: ConnectionSettings.Host,
        context: DatabaseAdapterConnectionContext,
        deadline: Date,
        eventLoop: MongoDBDatabaseOwnedEventLoop,
        attempt: MongoDBDatabaseConnectionAttempt
    ) async throws -> MongoDBDatabaseConnectedTransport {
        let timeout = try remainingTime(deadline)
        let logger = Logger(label: "com.pulkitxm.edith.database.mongodb")
        let mongoContext = MongoClientContext(logger: logger)
        let sslContext =
            try plan.settings.useSSL
            ? NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
            : nil
        let bootstrap = ClientBootstrap(group: eventLoop.group)
            .connectTimeout(timeout)
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                value: 1
            )
            .channelInitializer { channel in
                if let termination = attempt.install(channel) {
                    channel.close(mode: .all, promise: nil)
                    return channel.eventLoop.makeFailedFuture(termination)
                }
                let tlsFuture: EventLoopFuture<Void>
                if let sslContext {
                    do {
                        let handler = try NIOSSLClientHandler(
                            context: sslContext,
                            serverHostname: host.hostname)
                        tlsFuture = channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(handler)
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                } else {
                    tlsFuture = channel.eventLoop.makeSucceededVoidFuture()
                }
                return tlsFuture.flatMap {
                    channel.pipeline.addHandler(
                        MongoDBDatabaseBoundedFrameHandler(context: mongoContext))
                }.flatMap {
                    MongoConnection.addHandlers(to: channel, context: mongoContext)
                }
            }
        let channel = try await bootstrap.connect(host: host.hostname, port: host.port).get()
        try await check(context: context, deadline: deadline, attempt: attempt)
        let connection = MongoConnection(channel: channel, context: mongoContext)
        await connection.setDatabaseQueryTimeout(try remainingTime(deadline))
        let handshake = try await authenticate(
            connection,
            settings: plan.settings,
            cancellationCheck: {
                try await check(context: context, deadline: deadline, attempt: attempt)
            })
        try await check(context: context, deadline: deadline, attempt: attempt)
        try await connection.ping()
        let build = try await connection.executeCodable(
            MongoDBBuildInfoCommand(),
            decodeAs: MongoDBBuildInfoResponse.self,
            namespace: .administrativeCommand,
            sessionId: connection.implicitSessionId,
            traceLabel: "DatabaseIdentity")
        let identity = MongoDBDatabaseDriverSupport.identity(handshake: handshake, build: build)
        return MongoDBDatabaseConnectedTransport(
            connection: connection,
            channel: channel,
            eventLoop: eventLoop,
            identity: identity)
    }

    private static func authenticate(
        _ connection: MongoConnection,
        settings: ConnectionSettings,
        cancellationCheck: @escaping @Sendable () async throws -> Void
    ) async throws -> ServerHandshake {
        try await cancellationCheck()
        switch settings.authentication {
        case .unauthenticated:
            let handshake = try await connection.doHandshake(
                clientDetails: nil,
                credentials: .unauthenticated,
                authenticationDatabase: settings.authenticationSource ?? "admin")
            try await cancellationCheck()
            return handshake
        case let .scramSha256(username, password):
            let source = settings.authenticationSource ?? "admin"
            let handshake = try await connection.doHandshake(
                clientDetails: nil,
                credentials: .auto(username: username, password: password),
                authenticationDatabase: source)
            guard handshake.saslSupportedMechs?.contains("SCRAM-SHA-256") == true else {
                throw MongoDBDatabaseDriverFailure.authentication
            }
            try await MongoDBDatabaseSCRAMSHA256.authenticate(
                connection,
                username: username,
                password: password,
                database: source,
                cancellationCheck: cancellationCheck)
            try await cancellationCheck()
            return handshake
        case .auto, .scramSha1, .mongoDBCR:
            throw MongoDBDatabaseDriverFailure.authentication
        }
    }

    private static func effectiveDeadline(
        settings: ConnectionSettings,
        context: DatabaseAdapterConnectionContext
    ) throws -> Date {
        let configured = settings.connectTimeout
        guard configured.isFinite, configured > 0 else {
            throw MongoDBDatabaseDriverFailure.connection
        }
        let configuredDeadline = Date().addingTimeInterval(configured)
        guard let contextDeadline = context.deadline else { return configuredDeadline }
        guard contextDeadline.timeIntervalSinceReferenceDate.isFinite else {
            throw MongoDBDatabaseDriverFailure.timeout
        }
        return min(configuredDeadline, contextDeadline)
    }

    private static func remainingTime(_ deadline: Date) throws -> TimeAmount {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining.isFinite, remaining > 0 else {
            throw MongoDBDatabaseDriverFailure.timeout
        }
        let milliseconds = Int64(min(max(1, floor(remaining * 1_000)), Double(Int64.max)))
        return .milliseconds(milliseconds)
    }

    private static func check(
        context: DatabaseAdapterConnectionContext,
        deadline: Date,
        attempt: MongoDBDatabaseConnectionAttempt
    ) async throws {
        if let termination = attempt.termination {
            switch termination {
            case .cancelled:
                throw CancellationError()
            case .timeout:
                throw MongoDBDatabaseDriverFailure.timeout
            default:
                throw MongoDBDatabaseDriverFailure.connection
            }
        }
        switch await context.cancellation.reason() {
        case .deadlineExceeded:
            throw MongoDBDatabaseDriverFailure.timeout
        case .userRequested, .sessionDisconnected:
            throw CancellationError()
        case nil:
            break
        }
        guard deadline > Date() else {
            throw MongoDBDatabaseDriverFailure.timeout
        }
        try Task.checkCancellation()
    }
}

private final class MongoDBDatabaseConnectionAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var currentChannel: (any Channel)?
    private var storedTermination: MongoDBDatabaseTransportFailure?

    var termination: MongoDBDatabaseTransportFailure? {
        lock.withLock { storedTermination }
    }

    func install(_ channel: any Channel) -> MongoDBDatabaseTransportFailure? {
        lock.withLock {
            currentChannel = channel
            return storedTermination
        }
    }

    func terminate(_ termination: MongoDBDatabaseTransportFailure) {
        let channel: (any Channel)? = lock.withLock {
            if storedTermination == nil {
                storedTermination = termination
            }
            return currentChannel
        }
        channel?.close(mode: .all, promise: nil)
    }

    func finish() {
        lock.withLock {
            currentChannel = nil
        }
    }

    func closeCurrentChannel() async {
        let channel: (any Channel)? = lock.withLock {
            defer { currentChannel = nil }
            return currentChannel
        }
        guard let channel else { return }
        channel.close(mode: .all, promise: nil)
        _ = try? await channel.closeFuture.get()
    }
}

final class MongoDBDatabaseBoundedFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let mongoContext: MongoClientContext
    private var buffered: ByteBuffer?
    private var expectedLength: Int?

    init(context: MongoClientContext) {
        mongoContext = context
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var input = unwrapInboundIn(data)
        do {
            try consume(&input, context: context)
        } catch {
            fail(context: context, error: error)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        Task {
            await mongoContext.cancelQueries(MongoDBDatabaseTransportFailure.cancelled)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(context: context, error: error)
    }

    private func consume(
        _ input: inout ByteBuffer,
        context: ChannelHandlerContext
    ) throws {
        while input.readableBytes > 0 {
            if buffered == nil {
                buffered = context.channel.allocator.buffer(capacity: 4)
            }
            guard var frame = buffered else {
                throw MongoDBDatabaseTransportFailure.invalidFrame
            }
            if expectedLength == nil {
                let prefixBytes = min(4 - frame.readableBytes, input.readableBytes)
                guard prefixBytes > 0, var prefix = input.readSlice(length: prefixBytes) else {
                    throw MongoDBDatabaseTransportFailure.invalidFrame
                }
                frame.writeBuffer(&prefix)
                buffered = frame
                guard frame.readableBytes == 4 else { continue }
                expectedLength = try MongoDBDatabaseWireReplyValidator.frameLength(frame)
            }
            guard let expectedLength else {
                throw MongoDBDatabaseTransportFailure.invalidFrame
            }
            let remaining = expectedLength - frame.readableBytes
            guard remaining >= 0 else {
                throw MongoDBDatabaseTransportFailure.invalidFrame
            }
            let count = min(remaining, input.readableBytes)
            if count > 0 {
                guard var chunk = input.readSlice(length: count) else {
                    throw MongoDBDatabaseTransportFailure.invalidFrame
                }
                frame.writeBuffer(&chunk)
                buffered = frame
            }
            guard frame.readableBytes == expectedLength else { continue }
            try MongoDBDatabaseWireReplyValidator.validate(frame)
            context.fireChannelRead(wrapInboundOut(frame))
            buffered = nil
            self.expectedLength = nil
        }
    }

    private func fail(context: ChannelHandlerContext, error: Error) {
        buffered = nil
        expectedLength = nil
        Task {
            await mongoContext.cancelQueries(error)
        }
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}

enum MongoDBDatabaseWireReplyValidator {
    private static let maximumElements = 65_536
    private static let maximumDepth = 32

    static func frameLength(_ buffer: ByteBuffer) throws -> Int {
        guard
            let rawLength = buffer.getInteger(
                at: buffer.readerIndex,
                endianness: .little,
                as: Int32.self),
            rawLength >= 16
        else {
            throw MongoDBDatabaseTransportFailure.invalidFrame
        }
        let length = Int(rawLength)
        guard length <= MongoDBDatabaseTransport.maximumFrameBytes else {
            throw MongoDBDatabaseTransportFailure.frameTooLarge
        }
        return length
    }

    static func validate(_ frame: ByteBuffer) throws {
        let start = frame.readerIndex
        let length = try frameLength(frame)
        guard frame.readableBytes == length,
            let opcode = frame.getInteger(
                at: start + 12,
                endianness: .little,
                as: Int32.self)
        else {
            throw MongoDBDatabaseTransportFailure.invalidFrame
        }
        var elements = 0
        switch opcode {
        case 1:
            try validateReply(frame, start: start, end: start + length, elements: &elements)
        case 2013:
            try validateMessage(frame, start: start, end: start + length, elements: &elements)
        default:
            throw MongoDBDatabaseTransportFailure.invalidFrame
        }
    }

    private static func validateReply(
        _ buffer: ByteBuffer,
        start: Int,
        end: Int,
        elements: inout Int
    ) throws {
        guard end - start >= 36,
            let count = buffer.getInteger(
                at: start + 32,
                endianness: .little,
                as: Int32.self),
            count >= 0,
            count <= 1_000
        else {
            throw MongoDBDatabaseTransportFailure.invalidFrame
        }
        var offset = start + 36
        for _ in 0..<Int(count) {
            offset = try validateDocument(
                buffer,
                start: offset,
                limit: end,
                depth: 0,
                elements: &elements)
        }
        guard offset == end else {
            throw MongoDBDatabaseTransportFailure.invalidFrame
        }
    }

    private static func validateMessage(
        _ buffer: ByteBuffer,
        start: Int,
        end: Int,
        elements: inout Int
    ) throws {
        guard end - start >= 25,
            let flags = buffer.getInteger(
                at: start + 16,
                endianness: .little,
                as: UInt32.self),
            flags == 0
        else {
            throw MongoDBDatabaseTransportFailure.invalidFrame
        }
        var offset = start + 20
        var foundBody = false
        while offset < end {
            guard let kind = buffer.getInteger(at: offset, as: UInt8.self) else {
                throw MongoDBDatabaseTransportFailure.invalidFrame
            }
            offset += 1
            switch kind {
            case 0:
                guard !foundBody else {
                    throw MongoDBDatabaseTransportFailure.invalidFrame
                }
                foundBody = true
                offset = try validateDocument(
                    buffer,
                    start: offset,
                    limit: end,
                    depth: 0,
                    elements: &elements)
            case 1:
                guard
                    let rawSize = buffer.getInteger(
                        at: offset,
                        endianness: .little,
                        as: Int32.self),
                    rawSize >= 5
                else {
                    throw MongoDBDatabaseTransportFailure.invalidFrame
                }
                let sectionEnd = offset + Int(rawSize)
                guard sectionEnd <= end else {
                    throw MongoDBDatabaseTransportFailure.invalidFrame
                }
                offset += 4
                offset = try consumeCString(buffer, from: offset, limit: sectionEnd)
                while offset < sectionEnd {
                    offset = try validateDocument(
                        buffer,
                        start: offset,
                        limit: sectionEnd,
                        depth: 0,
                        elements: &elements)
                }
                guard offset == sectionEnd else {
                    throw MongoDBDatabaseTransportFailure.invalidFrame
                }
            default:
                throw MongoDBDatabaseTransportFailure.invalidFrame
            }
        }
        guard foundBody, offset == end else {
            throw MongoDBDatabaseTransportFailure.invalidFrame
        }
    }

    private static func validateDocument(
        _ buffer: ByteBuffer,
        start: Int,
        limit: Int,
        depth: Int,
        elements: inout Int
    ) throws -> Int {
        guard depth <= maximumDepth,
            let rawLength = buffer.getInteger(
                at: start,
                endianness: .little,
                as: Int32.self),
            rawLength >= 5
        else {
            throw MongoDBDatabaseTransportFailure.invalidDocument
        }
        let length = Int(rawLength)
        guard length <= MongoDBDatabaseTransport.maximumDocumentBytes else {
            throw MongoDBDatabaseTransportFailure.documentTooLarge
        }
        let end = start + length
        guard end <= limit,
            buffer.getInteger(at: end - 1, as: UInt8.self) == 0
        else {
            throw MongoDBDatabaseTransportFailure.invalidDocument
        }
        var offset = start + 4
        while offset < end - 1 {
            guard let type = buffer.getInteger(at: offset, as: UInt8.self), type != 0 else {
                throw MongoDBDatabaseTransportFailure.invalidDocument
            }
            elements += 1
            guard elements <= maximumElements else {
                throw MongoDBDatabaseTransportFailure.invalidDocument
            }
            offset = try consumeCString(buffer, from: offset + 1, limit: end - 1)
            switch type {
            case 0x01:
                offset = try advance(offset, by: 8, limit: end - 1)
            case 0x02, 0x0D:
                offset = try consumeString(buffer, from: offset, limit: end - 1)
            case 0x03, 0x04:
                offset = try validateDocument(
                    buffer,
                    start: offset,
                    limit: end - 1,
                    depth: depth + 1,
                    elements: &elements)
            case 0x05:
                guard
                    let rawSize = buffer.getInteger(
                        at: offset,
                        endianness: .little,
                        as: Int32.self),
                    rawSize >= 0
                else {
                    throw MongoDBDatabaseTransportFailure.invalidDocument
                }
                offset = try advance(offset, by: 5 + Int(rawSize), limit: end - 1)
            case 0x07:
                offset = try advance(offset, by: 12, limit: end - 1)
            case 0x08:
                guard let value = buffer.getInteger(at: offset, as: UInt8.self), value <= 1 else {
                    throw MongoDBDatabaseTransportFailure.invalidDocument
                }
                offset = try advance(offset, by: 1, limit: end - 1)
            case 0x09, 0x11, 0x12:
                offset = try advance(offset, by: 8, limit: end - 1)
            case 0x0A, 0x7F, 0xFF:
                break
            case 0x0B:
                offset = try consumeCString(buffer, from: offset, limit: end - 1)
                offset = try consumeCString(buffer, from: offset, limit: end - 1)
            case 0x0F:
                guard
                    let rawSize = buffer.getInteger(
                        at: offset,
                        endianness: .little,
                        as: Int32.self),
                    rawSize >= 14
                else {
                    throw MongoDBDatabaseTransportFailure.invalidDocument
                }
                let scopeEnd = offset + Int(rawSize)
                guard scopeEnd <= end - 1 else {
                    throw MongoDBDatabaseTransportFailure.invalidDocument
                }
                var scopeOffset = try consumeString(buffer, from: offset + 4, limit: scopeEnd)
                scopeOffset = try validateDocument(
                    buffer,
                    start: scopeOffset,
                    limit: scopeEnd,
                    depth: depth + 1,
                    elements: &elements)
                guard scopeOffset == scopeEnd else {
                    throw MongoDBDatabaseTransportFailure.invalidDocument
                }
                offset = scopeEnd
            case 0x10:
                offset = try advance(offset, by: 4, limit: end - 1)
            case 0x13:
                offset = try advance(offset, by: 16, limit: end - 1)
            default:
                throw MongoDBDatabaseTransportFailure.invalidDocument
            }
        }
        guard offset == end - 1 else {
            throw MongoDBDatabaseTransportFailure.invalidDocument
        }
        return end
    }

    private static func consumeString(
        _ buffer: ByteBuffer,
        from offset: Int,
        limit: Int
    ) throws -> Int {
        guard
            let rawLength = buffer.getInteger(
                at: offset,
                endianness: .little,
                as: Int32.self),
            rawLength >= 1
        else {
            throw MongoDBDatabaseTransportFailure.invalidDocument
        }
        let contentStart = offset + 4
        let end = contentStart + Int(rawLength)
        guard end <= limit,
            buffer.getInteger(at: end - 1, as: UInt8.self) == 0,
            buffer.getString(at: contentStart, length: Int(rawLength) - 1) != nil
        else {
            throw MongoDBDatabaseTransportFailure.invalidDocument
        }
        return end
    }

    private static func consumeCString(
        _ buffer: ByteBuffer,
        from offset: Int,
        limit: Int
    ) throws -> Int {
        var end = offset
        while end < limit {
            guard let byte = buffer.getInteger(at: end, as: UInt8.self) else {
                throw MongoDBDatabaseTransportFailure.invalidDocument
            }
            if byte == 0 {
                guard buffer.getString(at: offset, length: end - offset) != nil else {
                    throw MongoDBDatabaseTransportFailure.invalidDocument
                }
                return end + 1
            }
            end += 1
        }
        throw MongoDBDatabaseTransportFailure.invalidDocument
    }

    private static func advance(_ offset: Int, by count: Int, limit: Int) throws -> Int {
        guard count >= 0, offset <= limit, count <= limit - offset else {
            throw MongoDBDatabaseTransportFailure.invalidDocument
        }
        return offset + count
    }
}

private enum MongoDBDatabaseSASLPayload: Codable {
    case binary(Binary)
    case string(String)

    init(from decoder: Decoder) throws {
        if let binary = try? Binary(from: decoder) {
            self = .binary(binary)
        } else {
            self = .string(try String(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .binary(value):
            try value.encode(to: encoder)
        case let .string(value):
            try value.encode(to: encoder)
        }
    }

    func decodedString() throws -> String {
        let encoded: String
        switch self {
        case let .binary(value):
            guard let string = String(data: value.data, encoding: .utf8) else {
                throw MongoDBDatabaseTransportFailure.authentication
            }
            encoded = string
        case let .string(value):
            encoded = value
        }
        guard encoded.utf8.count <= 8_192,
            let data = Data(base64Encoded: encoded),
            data.count <= 8_192,
            let decoded = String(data: data, encoding: .utf8)
        else {
            throw MongoDBDatabaseTransportFailure.authentication
        }
        return decoded
    }
}

private struct MongoDBDatabaseSASLStart: Encodable {
    let saslStart: Int32 = 1
    let mechanism = "SCRAM-SHA-256"
    let payload: MongoDBDatabaseSASLPayload
}

private struct MongoDBDatabaseSASLContinue: Encodable {
    let saslContinue: Int32 = 1
    let conversationId: Int32
    let payload: MongoDBDatabaseSASLPayload
}

private struct MongoDBDatabaseSASLReply: Decodable {
    let conversationId: Int32
    let done: Bool
    let payload: MongoDBDatabaseSASLPayload
}

private enum MongoDBDatabaseSCRAMSHA256 {
    static func authenticate(
        _ connection: MongoConnection,
        username: String,
        password: String,
        database: String,
        cancellationCheck: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await cancellationCheck()
        let escapedUsername =
            username
            .replacingOccurrences(of: "=", with: "=3D")
            .replacingOccurrences(of: ",", with: "=2C")
        let nonce = randomNonce()
        let clientFirstBare = "n=\(escapedUsername),r=\(nonce)"
        let clientFirst = "n,,\(clientFirstBare)"
        var reply = try await connection.executeCodable(
            MongoDBDatabaseSASLStart(
                payload: .string(Data(clientFirst.utf8).base64EncodedString())),
            decodeAs: MongoDBDatabaseSASLReply.self,
            namespace: MongoNamespace(to: "$cmd", inDatabase: database),
            sessionId: nil,
            traceLabel: "DatabaseAuthentication")
        try await cancellationCheck()
        guard !reply.done else {
            throw MongoDBDatabaseDriverFailure.authentication
        }
        let serverFirst = try reply.payload.decodedString()
        let challenge = try challenge(serverFirst, nonce: nonce)
        var passwordBytes = Data(password.utf8)
        var saltedPassword = try await pbkdf2(
            password: passwordBytes,
            salt: challenge.salt,
            iterations: challenge.iterations,
            cancellationCheck: cancellationCheck)
        var clientKey = hmac(key: saltedPassword, message: Data("Client Key".utf8))
        var serverKey = hmac(key: saltedPassword, message: Data("Server Key".utf8))
        defer {
            passwordBytes.resetBytes(in: 0..<passwordBytes.count)
            saltedPassword.resetBytes(in: 0..<saltedPassword.count)
            clientKey.resetBytes(in: 0..<clientKey.count)
            serverKey.resetBytes(in: 0..<serverKey.count)
        }
        var storedKey = Data(SHA256.hash(data: clientKey))
        defer {
            storedKey.resetBytes(in: 0..<storedKey.count)
        }
        let withoutProof = "c=biws,r=\(challenge.nonce)"
        let authenticationMessage = Data(
            "\(clientFirstBare),\(serverFirst),\(withoutProof)".utf8)
        let clientSignature = hmac(key: storedKey, message: authenticationMessage)
        let proof = xor(clientKey, clientSignature).base64EncodedString()
        let clientFinal = "\(withoutProof),p=\(proof)"
        reply = try await connection.executeCodable(
            MongoDBDatabaseSASLContinue(
                conversationId: reply.conversationId,
                payload: .string(Data(clientFinal.utf8).base64EncodedString())),
            decodeAs: MongoDBDatabaseSASLReply.self,
            namespace: MongoNamespace(to: "$cmd", inDatabase: database),
            sessionId: nil,
            traceLabel: "DatabaseAuthentication")
        try await cancellationCheck()
        let serverFinal = try reply.payload.decodedString()
        try verify(
            serverFinal,
            key: serverKey,
            authenticationMessage: authenticationMessage)
        if !reply.done {
            reply = try await connection.executeCodable(
                MongoDBDatabaseSASLContinue(
                    conversationId: reply.conversationId,
                    payload: .string("")),
                decodeAs: MongoDBDatabaseSASLReply.self,
                namespace: MongoNamespace(to: "$cmd", inDatabase: database),
                sessionId: nil,
                traceLabel: "DatabaseAuthentication")
            try await cancellationCheck()
        }
        guard reply.done else {
            throw MongoDBDatabaseDriverFailure.authentication
        }
    }

    private static func challenge(
        _ value: String,
        nonce: String
    ) throws -> (nonce: String, salt: Data, iterations: Int) {
        guard value.utf8.count <= 8_192 else {
            throw MongoDBDatabaseDriverFailure.authentication
        }
        var fields: [Character: String] = [:]
        for component in value.split(separator: ",", omittingEmptySubsequences: false) {
            guard component.count >= 3,
                let name = component.first,
                component[component.index(after: component.startIndex)] == "=",
                fields[name] == nil
            else {
                throw MongoDBDatabaseDriverFailure.authentication
            }
            fields[name] = String(component.dropFirst(2))
        }
        guard fields.keys.allSatisfy({ ["r", "s", "i"].contains($0) }),
            let serverNonce = fields["r"],
            serverNonce.hasPrefix(nonce),
            serverNonce.count > nonce.count,
            serverNonce.utf8.count <= 1_024,
            let saltText = fields["s"],
            saltText.utf8.count <= 1_024,
            let salt = Data(base64Encoded: saltText),
            !salt.isEmpty,
            salt.count <= 1_024,
            let iterationText = fields["i"],
            let iterations = Int(iterationText),
            (4_096...100_000).contains(iterations)
        else {
            throw MongoDBDatabaseDriverFailure.authentication
        }
        return (serverNonce, salt, iterations)
    }

    private static func verify(
        _ value: String,
        key: Data,
        authenticationMessage: Data
    ) throws {
        guard value.hasPrefix("v="),
            value.utf8.count <= 1_024,
            let signature = Data(base64Encoded: String(value.dropFirst(2))),
            HMAC<SHA256>.isValidAuthenticationCode(
                signature,
                authenticating: authenticationMessage,
                using: SymmetricKey(data: key))
        else {
            throw MongoDBDatabaseDriverFailure.authentication
        }
    }

    private static func pbkdf2(
        password: Data,
        salt: Data,
        iterations: Int,
        cancellationCheck: @escaping @Sendable () async throws -> Void
    ) async throws -> Data {
        guard (4_096...100_000).contains(iterations) else {
            throw MongoDBDatabaseDriverFailure.authentication
        }
        var firstInput = salt
        firstInput.append(contentsOf: [0, 0, 0, 1])
        var current = hmac(key: password, message: firstInput)
        var result = current
        if iterations > 1 {
            for iteration in 1..<iterations {
                if iteration.isMultiple(of: 128) {
                    try await cancellationCheck()
                }
                current = hmac(key: password, message: current)
                result = xor(result, current)
            }
        }
        try await cancellationCheck()
        current.resetBytes(in: 0..<current.count)
        return result
    }

    private static func hmac(key: Data, message: Data) -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: message,
                using: SymmetricKey(data: key)))
    }

    private static func xor(_ left: Data, _ right: Data) -> Data {
        guard left.count == right.count else { return Data() }
        let leftBytes = [UInt8](left)
        let rightBytes = [UInt8](right)
        return Data(zip(leftBytes, rightBytes).map(^))
    }

    private static func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }
}

extension MongoConnection {
    func setDatabaseQueryTimeout(_ timeout: TimeAmount) {
        queryTimeout = timeout
    }
}
