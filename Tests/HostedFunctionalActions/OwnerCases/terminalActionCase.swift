import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import TerminalExtension

@MainActor
final class TerminalActionCase: HostedFunctionalActionCase {
    static let owner = "terminal"
    static let activationOperation = "terminal.open"
    private let transport: HostedFunctionalActionTransport
    private let client: TerminalRemoteClient
    private let model: TerminalTabsModel
    private var opened: [TerminalEngine.Session] = []

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        client = TerminalRemoteClient(client: try transport.makeEngineClient())
        model = TerminalTabsModel(client: client)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let snapshot = try JSONDecoder().decode(
            TerminalEngine.Snapshot.self, from: await transport.readAuthoritative("terminal.snapshot"))
        guard snapshot.sessions.isEmpty else { throw HostedFunctionalActionError.invalid }
        var count = transport.originalInvocationCount
        model.ensureFirstTab()
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.tabs.count != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard model.tabs.count == 1 else { throw HostedFunctionalActionError.invalid }
        count = transport.originalInvocationCount
        model.addTab()
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        await client.refresh()
        guard client.error == nil, client.snapshot.sessions.count == 2 else {
            throw HostedFunctionalActionError.invalid
        }
        opened = client.snapshot.sessions
        for session in opened {
            guard session.running, session.directory.hasPrefix(context.home + "/")
                || session.directory == context.home
            else { throw HostedFunctionalActionError.invalid }
            try await client.input(Data("printf 'functional-%s\\n' shell\n".utf8), to: session)
        }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context, opened.count == 2 else { throw HostedFunctionalActionError.invalid }
        var outputs: [String] = []
        for session in opened {
            var offset: UInt64 = 0
            var bytes = Data()
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline, bytes.count < 65_536 {
                let request = TerminalEngine.ReadRequest(
                    session: .init(id: session.id, generation: session.generation), offset: offset)
                let output = try JSONDecoder().decode(
                    TerminalPTY.Output.self,
                    from: await transport.readAuthoritative("terminal.read", payload: JSONEncoder().encode(request)))
                guard output.nextOffset == offset + UInt64(output.bytes.count) else {
                    throw HostedFunctionalActionError.invalid
                }
                bytes.append(output.bytes)
                offset = output.nextOffset
                if String(decoding: bytes, as: UTF8.self).contains("functional-shell") { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard String(decoding: bytes, as: UTF8.self).contains("functional-shell") else {
                throw HostedFunctionalActionError.invalid
            }
            outputs.append(String(decoding: bytes, as: UTF8.self))
        }
        return try JSONEncoder().encode(outputs)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let value = try JSONDecoder().decode(
            TerminalSettings.self, from: await transport.readAuthoritative("terminal.preferences"))
        try value.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func shutdownPresentation() async {
        await client.closeAll()
        model.stopAll()
        opened.removeAll()
    }
}
