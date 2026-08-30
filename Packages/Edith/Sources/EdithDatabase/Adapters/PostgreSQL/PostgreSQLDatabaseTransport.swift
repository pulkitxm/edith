import Foundation
import NIOCore
import NIOSSL
import NIOTransportServices
import PostgresNIO

struct PostgreSQLDatabaseTransportResource: @unchecked Sendable {
    let connection: PostgresConnection
    let eventLoopGroup: NIOTSEventLoopGroup
}

enum PostgreSQLDatabaseTransport {
    static let maximumInboundFrameBytes = 16_777_216
    static let wireGuardName = "postgresql-wire-guard"
    static let decryptedWireGuardName = "postgresql-decrypted-wire-guard"

    static func connect(
        _ plan: PostgreSQLDatabaseConnectionPlan,
        connectionID: Int
    ) async throws -> PostgreSQLDatabaseTransportResource {
        let eventLoopGroup = NIOTSEventLoopGroup(loopCount: 1)
        let pendingChannels = PostgreSQLDatabasePendingChannels()
        var channel: (any Channel)?
        do {
            let guardMode: PostgreSQLDatabaseWireGuard.Mode
            switch plan.tls {
            case .disabled:
                guardMode = .postgres
            case .preferred, .required:
                guardMode = .sslNegotiation
            }
            let bootstrap = NIOTSConnectionBootstrap(group: eventLoopGroup)
                .connectTimeout(
                    .milliseconds(Int64(clamping: plan.connectTimeoutMilliseconds))
                )
                .channelInitializer { channel in
                    pendingChannels.register(channel)
                    return channel.pipeline.addHandler(
                        PostgreSQLDatabaseWireGuard(
                            mode: guardMode,
                            maximumFrameBytes: maximumInboundFrameBytes),
                        name: wireGuardName)
                }
            let connectedChannel = try await awaitConnectedChannel(
                bootstrap.connect(
                    host: plan.host,
                    port: plan.port),
                pendingChannels: pendingChannels)
            channel = connectedChannel
            let configuration = try plan.configuration(
                establishedChannel: connectedChannel)
            let connection = try await PostgresConnection.connect(
                on: connectedChannel.eventLoop,
                configuration: configuration,
                id: connectionID,
                logger: Logger(label: "com.edith.database.postgresql"))
            return PostgreSQLDatabaseTransportResource(
                connection: connection,
                eventLoopGroup: eventLoopGroup)
        } catch {
            pendingChannels.cancel()
            try? await channel?.close()
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
    }

    static func awaitConnectedChannel(
        _ future: EventLoopFuture<any Channel>,
        pendingChannels: PostgreSQLDatabasePendingChannels
    ) async throws -> any Channel {
        do {
            return try await withTaskCancellationHandler {
                try await future.get()
            } onCancel: {
                pendingChannels.cancel()
            }
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}

final class PostgreSQLDatabasePendingChannels: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [any Channel] = []
    private var cancelled = false

    func register(_ channel: any Channel) {
        let closeImmediately = lock.withLock {
            guard !cancelled else { return true }
            channels.append(channel)
            return false
        }
        if closeImmediately {
            channel.close(promise: nil)
        }
    }

    func cancel() {
        let channels = lock.withLock {
            cancelled = true
            let channels = self.channels
            self.channels.removeAll(keepingCapacity: false)
            return channels
        }
        for channel in channels {
            channel.close(promise: nil)
        }
    }
}

struct PostgreSQLDatabaseFrameValidator: Sendable {
    private let maximumFrameBytes: Int
    private var header: [UInt8] = []
    private var remainingPayloadBytes = 0

    init(maximumFrameBytes: Int) {
        self.maximumFrameBytes = max(5, maximumFrameBytes)
        header.reserveCapacity(5)
    }

    mutating func consume(_ bytes: ByteBufferView) -> Bool {
        for byte in bytes {
            if remainingPayloadBytes > 0 {
                remainingPayloadBytes -= 1
                continue
            }
            header.append(byte)
            guard header.count == 5 else { continue }
            let length =
                UInt32(header[1]) << 24
                | UInt32(header[2]) << 16
                | UInt32(header[3]) << 8
                | UInt32(header[4])
            header.removeAll(keepingCapacity: true)
            guard length >= 4,
                UInt64(length) + 1 <= UInt64(maximumFrameBytes)
            else {
                return false
            }
            remainingPayloadBytes = Int(length) - 4
        }
        return true
    }
}

final class PostgreSQLDatabaseWireGuard: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    enum Mode {
        case postgres
        case sslNegotiation
        case passthrough
    }

    private var mode: Mode
    private let maximumFrameBytes: Int
    private var validator: PostgreSQLDatabaseFrameValidator

    init(mode: Mode, maximumFrameBytes: Int) {
        self.mode = mode
        self.maximumFrameBytes = maximumFrameBytes
        validator = PostgreSQLDatabaseFrameValidator(
            maximumFrameBytes: maximumFrameBytes)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        switch mode {
        case .postgres:
            forwardPostgres(buffer, context: context)
        case .sslNegotiation:
            forwardSSLNegotiation(buffer, context: context)
        case .passthrough:
            context.fireChannelRead(wrapInboundOut(buffer))
        }
    }

    private func forwardPostgres(
        _ buffer: ByteBuffer,
        context: ChannelHandlerContext
    ) {
        guard validator.consume(buffer.readableBytesView) else {
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    private func forwardSSLNegotiation(
        _ buffer: ByteBuffer,
        context: ChannelHandlerContext
    ) {
        guard buffer.readableBytes > 0,
            let response = buffer.getInteger(
                at: buffer.readerIndex,
                as: UInt8.self),
            response == UInt8(ascii: "S") || response == UInt8(ascii: "N"),
            let responseBuffer = buffer.getSlice(
                at: buffer.readerIndex,
                length: 1)
        else {
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(wrapInboundOut(responseBuffer))
        let remainder = buffer.getSlice(
            at: buffer.readerIndex + 1,
            length: buffer.readableBytes - 1)
        if response == UInt8(ascii: "S") {
            guard installDecryptedGuard(context: context) else { return }
            mode = .passthrough
            if let remainder, remainder.readableBytes > 0 {
                context.fireChannelRead(wrapInboundOut(remainder))
            }
        } else {
            mode = .postgres
            if let remainder, remainder.readableBytes > 0 {
                forwardPostgres(remainder, context: context)
            }
        }
    }

    private func installDecryptedGuard(
        context: ChannelHandlerContext
    ) -> Bool {
        do {
            let sslHandler = try context.pipeline.syncOperations.handler(
                type: NIOSSLClientHandler.self)
            try context.pipeline.syncOperations.addHandler(
                PostgreSQLDatabaseWireGuard(
                    mode: .postgres,
                    maximumFrameBytes: maximumFrameBytes),
                name: PostgreSQLDatabaseTransport.decryptedWireGuardName,
                position: .after(sslHandler))
            return true
        } catch {
            context.close(promise: nil)
            return false
        }
    }
}
