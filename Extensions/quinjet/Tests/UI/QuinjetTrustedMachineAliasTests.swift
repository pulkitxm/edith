import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import QuinjetUI

@MainActor @Suite(.serialized) struct QuinjetTrustedMachineAliasTests {
    @Test func trustedOptionalMachineAliasesPreserveExactAndAmbiguousSelectors() async throws {
        defer { MachineRegistry.shutdown() }
        let id = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: [
            "machines": [
                [
                    "id": id.uuidString, "name": "Synthetic saved host",
                    "sshTarget": "synthetic@host.invalid",
                    "aliases": ["original-build-alias"],
                ]
            ]
        ])
        try await MachineRegistry.refresh { operation, payload, _ in
            #expect(operation == "machines.companion.hosts" && payload == Data("{}".utf8))
            return bytes
        }
        #expect(try MachineResolver.machine("ORIGINAL-BUILD-ALIAS").id == id)
        #expect(try MachineResolver.machine("original-build").id == id)
        let other = Machine(name: "Other", host: "other.invalid", aliases: ["original-build-alias"])
        #expect(throws: CLIFailure.self) {
            try MachineResolver.machine(
                "original-build-alias", in: MachineRegistry.machines() + [other])
        }
        let malformed = try JSONSerialization.data(withJSONObject: [
            "machines": [
                [
                    "id": id.uuidString, "name": "Synthetic", "sshTarget": "host.invalid",
                    "aliases": ["*"],
                ]
            ]
        ])
        await #expect(throws: ExtensionPeerError.self) {
            try await MachineRegistry.refresh { _, _, _ in malformed }
        }
        #expect(MachineRegistry.machines().first?.aliases == ["original-build-alias"])
    }
}
