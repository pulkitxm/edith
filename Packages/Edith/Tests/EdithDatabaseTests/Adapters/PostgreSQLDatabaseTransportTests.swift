import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSL
import Testing

@testable import EdithDatabase

@Test func postgresqlTransportValidatorAcceptsSplitAndConsecutiveFrames() {
    var validator = PostgreSQLDatabaseFrameValidator(maximumFrameBytes: 32)
    var first = ByteBuffer()
    first.writeBytes([UInt8(ascii: "Z"), 0, 0])
    let acceptedFirst = validator.consume(first.readableBytesView)
    #expect(acceptedFirst)
    var second = ByteBuffer()
    second.writeBytes([0, 5, UInt8(ascii: "I"), UInt8(ascii: "1"), 0, 0, 0, 4])
    let acceptedSecond = validator.consume(second.readableBytesView)
    #expect(acceptedSecond)
}

@Test func postgresqlTransportValidatorRejectsUnderlengthFrame() {
    var validator = PostgreSQLDatabaseFrameValidator(maximumFrameBytes: 32)
    var buffer = ByteBuffer()
    buffer.writeBytes([UInt8(ascii: "Z"), 0, 0, 0, 3])
    let accepted = validator.consume(buffer.readableBytesView)
    #expect(!accepted)
}

@Test func postgresqlTransportValidatorRejectsOversizedFrameBeforePayload() {
    var validator = PostgreSQLDatabaseFrameValidator(maximumFrameBytes: 16)
    var buffer = ByteBuffer()
    buffer.writeBytes([UInt8(ascii: "D"), 0, 0, 0, 16])
    let accepted = validator.consume(buffer.readableBytesView)
    #expect(!accepted)
}

@Test func postgresqlTransportWireGuardForwardsValidFrames() throws {
    let channel = EmbeddedChannel(
        handler: PostgreSQLDatabaseWireGuard(
            mode: .postgres,
            maximumFrameBytes: 32))
    var buffer = channel.allocator.buffer(capacity: 6)
    buffer.writeBytes([UInt8(ascii: "Z"), 0, 0, 0, 5, UInt8(ascii: "I")])
    let state = try channel.writeInbound(buffer)
    #expect(state.isFull)
    let inbound: ByteBuffer? = try channel.readInbound(as: ByteBuffer.self)
    let forwarded = try #require(inbound)
    #expect(Array(forwarded.readableBytesView) == Array(buffer.readableBytesView))
    _ = try channel.finish()
}

@Test func postgresqlTransportWireGuardClosesOnOversizedFrame() throws {
    let channel = EmbeddedChannel(
        handler: PostgreSQLDatabaseWireGuard(
            mode: .postgres,
            maximumFrameBytes: 16))
    var buffer = channel.allocator.buffer(capacity: 5)
    buffer.writeBytes([UInt8(ascii: "D"), 0, 0, 0, 16])
    let state = try channel.writeInbound(buffer)
    #expect(state.isEmpty)
    #expect(!channel.isActive)
    #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
    _ = try channel.finish(acceptAlreadyClosed: true)
}

@Test func postgresqlTransportWireGuardTransitionsFromUnsupportedTLS() throws {
    let channel = EmbeddedChannel(
        handler: PostgreSQLDatabaseWireGuard(
            mode: .sslNegotiation,
            maximumFrameBytes: 32))
    var buffer = channel.allocator.buffer(capacity: 7)
    buffer.writeBytes([
        UInt8(ascii: "N"), UInt8(ascii: "Z"), 0, 0, 0, 5, UInt8(ascii: "I"),
    ])
    let state = try channel.writeInbound(buffer)
    #expect(state.isFull)
    let inboundResponse: ByteBuffer? = try channel.readInbound(as: ByteBuffer.self)
    let inboundFrame: ByteBuffer? = try channel.readInbound(as: ByteBuffer.self)
    let response = try #require(inboundResponse)
    let frame = try #require(inboundFrame)
    #expect(Array(response.readableBytesView) == [UInt8(ascii: "N")])
    #expect(
        Array(frame.readableBytesView)
            == [UInt8(ascii: "Z"), 0, 0, 0, 5, UInt8(ascii: "I")])
    _ = try channel.finish()
}

@Test func postgresqlTransportWireGuardInstallsGuardAfterTLS() throws {
    var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
    tlsConfiguration.certificateVerification = .none
    let tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
    let installer = PostgreSQLDatabaseTestTLSInstaller(tlsContext: tlsContext)
    let channel = EmbeddedChannel(handlers: [
        PostgreSQLDatabaseWireGuard(
            mode: .sslNegotiation,
            maximumFrameBytes: 32),
        installer,
    ])
    var buffer = channel.allocator.buffer(capacity: 1)
    buffer.writeInteger(UInt8(ascii: "S"))
    let state = try channel.writeInbound(buffer)
    #expect(state.isEmpty)
    try channel.pipeline.containsHandler(
        name: PostgreSQLDatabaseTransport.decryptedWireGuardName
    ).wait()
    _ = try channel.finish(acceptAlreadyClosed: true)
}

@Test func postgresqlTransportWireGuardRejectsInvalidTLSResponse() throws {
    let channel = EmbeddedChannel(
        handler: PostgreSQLDatabaseWireGuard(
            mode: .sslNegotiation,
            maximumFrameBytes: 32))
    var buffer = channel.allocator.buffer(capacity: 1)
    buffer.writeInteger(UInt8(ascii: "X"))
    let state = try channel.writeInbound(buffer)
    #expect(state.isEmpty)
    #expect(!channel.isActive)
    _ = try channel.finish(acceptAlreadyClosed: true)
}

@Test func postgresqlTransportCancelsPendingConnect() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    var channels: [any Channel] = []
    do {
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        channels.append(server)
        let port = try #require(server.localAddress?.port)
        let channel = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: port)
            .get()
        channels.append(channel)
        let pendingChannels = PostgreSQLDatabasePendingChannels()
        pendingChannels.register(channel)
        let promise = channel.eventLoop.makePromise(of: (any Channel).self)
        channel.closeFuture.whenComplete { _ in
            promise.fail(ChannelError.ioOnClosedChannel)
        }
        let fallback = channel.eventLoop.scheduleTask(in: .seconds(1)) {
            channel.close(promise: nil)
        }
        let connection = Task {
            try await PostgreSQLDatabaseTransport.awaitConnectedChannel(
                promise.futureResult,
                pendingChannels: pendingChannels)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let startedAt = ContinuousClock.now
        connection.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await connection.value
        }
        #expect(ContinuousClock.now - startedAt < .seconds(1))
        #expect(!channel.isActive)
        fallback.cancel()
        await postgresqlTransportCloseTestChannels(channels, group: group)
    } catch {
        await postgresqlTransportCloseTestChannels(channels, group: group)
        throw error
    }
}

@Test func postgresqlTransportCancelsBlackholedConnect() async throws {
    let plan = PostgreSQLDatabaseConnectionPlan(
        host: "192.0.2.1",
        port: 5_432,
        username: "reader",
        password: "fixture-password",
        database: "edith_lab",
        tls: .disabled,
        tlsServerName: nil,
        connectTimeoutMilliseconds: 2_000,
        statementTimeoutMilliseconds: 2_000,
        readOnly: true)
    let connection = Task {
        try await PostgreSQLDatabaseTransport.connect(
            plan,
            connectionID: 1)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    let startedAt = ContinuousClock.now
    connection.cancel()
    do {
        let resource = try await connection.value
        try? await resource.connection.close()
        try? await resource.eventLoopGroup.shutdownGracefully()
        Issue.record("blackholed connection completed after cancellation")
    } catch is CancellationError {
    } catch {
        Issue.record("blackholed connection returned a non-cancellation failure")
    }
    #expect(ContinuousClock.now - startedAt < .seconds(1))
}

private func postgresqlTransportCloseTestChannels(
    _ channels: [any Channel],
    group: MultiThreadedEventLoopGroup
) async {
    for channel in channels.reversed() {
        try? await channel.close()
    }
    try? await group.shutdownGracefully()
}

private final class PostgreSQLDatabaseTestTLSInstaller: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let tlsContext: NIOSSLContext

    init(tlsContext: NIOSSLContext) {
        self.tlsContext = tlsContext
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard buffer.readableBytes == 1,
            buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == UInt8(ascii: "S")
        else {
            context.close(promise: nil)
            return
        }
        do {
            let handler = try NIOSSLClientHandler(
                context: tlsContext,
                serverHostname: nil)
            try context.pipeline.syncOperations.addHandler(
                handler,
                position: .before(self))
        } catch {
            context.close(promise: nil)
        }
    }
}
