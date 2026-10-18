import EdithExtensionCommands
import Foundation
import Testing
@testable import AudioMixerExtension

@Suite(.serialized) @MainActor struct AudioMixerCLIBridgeTests {
    @Test func originalCommandsPreserveOutputAndRealTapFailures() async throws {
        guard #available(macOS 14.4, *) else { return }
        let engine = MixerEngine(
            snapshotLoader: {
                .init(
                    apps: [
                        .init(
                            objectID: 1, pid: 424242, bundleID: "synthetic.audio",
                            name: "Synthetic Audio", icon: nil, volume: 1)
                    ], outputUID: "synthetic")
            }, tapFactory: { _, _, _ in .failure(.deviceStart(-50)) })
        defer { engine.shutdown() }
        let list = try await AudioCLIExecution.run(
            .init(arguments: ["ls", "--json"]), engine: engine)
        #expect(
            list.exitCode == 0 && list.stderr.isEmpty && list.stdout.contains("Synthetic Audio"))
        let failed = try await AudioCLIExecution.run(
            .init(arguments: ["volume", "synthetic.audio", "40", "--json"]), engine: engine)
        #expect(
            failed.exitCode != 0 && failed.stdout.isEmpty && failed.stderr.contains("-50")
                && engine.apps.first?.volume == 1)
        let invalid = try await AudioCLIExecution.run(
            .init(arguments: ["volume", "synthetic.audio", "999"]), engine: engine)
        #expect(invalid.exitCode == 2 && invalid.stdout.isEmpty && !invalid.stderr.isEmpty)
        for args in [["mute", "--help"], ["unmute", "--help"], ["--help"]] {
            let help = try await AudioCLIExecution.run(.init(arguments: args), engine: engine)
            #expect(help.exitCode == 0 && help.stdout.contains("USAGE:") && help.stderr.isEmpty)
        }
        #expect(AudioCLIEnvironment.engine == nil)
    }
}
