import NIOCore
import NIOEmbedded
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
