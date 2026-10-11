import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import MachinesExtension

@MainActor
final class MachinesActionCase: HostedFunctionalActionCase {
    static let owner = "machines"
    static let activationOperation = "machines.ui.mutate"
    private let transport: HostedFunctionalActionTransport
    private let client: MachineUIClient
    private let model: MachinesModel
    private static let machineID = UUID(uuidString: "90000000-0000-4000-8000-000000000001")!

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        client = MachineUIClient(client: try transport.makeEngineClient())
        model = MachinesModel(uiClient: client)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let baseline = try await readState(context: context, name: "Synthetic retained machine")
        let snapshot = try JSONDecoder().decode(
            MachineUIState.self, from: await transport.readAuthoritative("machines.ui.state"))
        guard snapshot.machines.count == 1, var machine = snapshot.machines.first,
            machine.id == Self.machineID, machine.host == "127.0.0.1", !machine.sshClipboardEnabled
        else { throw HostedFunctionalActionError.invalid }
        model.applyUIState(snapshot)
        machine.name = "Synthetic temporary machine"
        var count = transport.originalInvocationCount
        model.update(machine)
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        let changed = try await readState(context: context, name: "Synthetic temporary machine")
        guard changed != baseline else { throw HostedFunctionalActionError.invalid }
        machine.name = "Synthetic retained machine"
        count = transport.originalInvocationCount
        model.update(machine)
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        guard try await readState(context: context, name: "Synthetic retained machine") == baseline else {
            throw HostedFunctionalActionError.invalid
        }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        try await readState(context: context, name: "Synthetic retained machine")
    }

    private func readState(context: HostedFunctionalActionContext, name: String) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let snapshot = try JSONDecoder().decode(
            MachineUIState.self, from: await transport.readAuthoritative("machines.ui.state"))
        guard snapshot.machines.count == 1, let machine = snapshot.machines.first,
            machine.id == Self.machineID, machine.name == name,
            machine.host == "127.0.0.1", !machine.sshClipboardEnabled
        else { throw HostedFunctionalActionError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot.machines)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async {
        await model.shutdown()
        client.shutdown()
    }
}
