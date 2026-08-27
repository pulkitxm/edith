import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

private final class AudioSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: String) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

@Suite(.serialized) struct CLIAudioTests {
    private static let input = AudioDeviceDescriptor(
        uid: "input-1", name: "Studio Mic", supportsInput: true, supportsOutput: false,
        isDefaultInput: true, isDefaultOutput: false, isHeadphones: false)
    private static let speakers = AudioDeviceDescriptor(
        uid: "output-1", name: "Desk Speakers", supportsInput: false, supportsOutput: true,
        isDefaultInput: false, isDefaultOutput: true, isHeadphones: false)
    private static let headphones = AudioDeviceDescriptor(
        uid: "output-2", name: "USB Headphones", supportsInput: false, supportsOutput: true,
        isDefaultInput: false, isDefaultOutput: false, isHeadphones: true)

    private static var snapshot: AudioDeviceSnapshot {
        AudioDeviceSnapshot(
            devices: [input, speakers, headphones], defaultInputUID: input.uid,
            defaultOutputUID: speakers.uid)
    }

    @Test func commandTreeAndParserExposeEveryAudioOperation() throws {
        let node = try #require(CommandTree.root.child("audio"))
        #expect(Set(node.children.map(\.name)) == ["status", "input", "output", "route"])
        #expect(try EdRoot.parseAsRoot(["audio"]) is AudioStatusCommand)
        #expect(try EdRoot.parseAsRoot(["audio", "status", "--json"]) is AudioStatusCommand)
        #expect(try EdRoot.parseAsRoot(["audio", "input", "Studio Mic"]) is AudioInputCommand)
        #expect(
            try EdRoot.parseAsRoot(["audio", "output", "output-1"]) is AudioOutputCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "audio", "route", "com.example.Player", "USB Headphones",
            ]) is AudioRouteCommand)
    }

    @Test func statusReportsDefaultsDevicesAndRoutes() async throws {
        try await CLIProbe.inWorld { world in
            world.shared.set(
                ["com.example.Player": "output-2"],
                forKey: AppStorageKeys.Audio.appOutputRoutes)
            world.shared.set("input-1", forKey: AppStorageKeys.Audio.preferredInputUID)
            CLIEnvironment.audioSnapshot = { Self.snapshot }
            let result = await CLIProbe.capture(["audio", "status", "--json"])
            #expect(result.code == 0)
            #expect(result.stderr.isEmpty)
            let object = try #require(result.object)
            #expect(object["defaultInputUID"] as? String == "input-1")
            #expect(object["defaultOutputUID"] as? String == "output-1")
            #expect((object["devices"] as? [Any])?.count == 3)
            #expect((object["routes"] as? [String: String])?["com.example.Player"] == "output-2")
        }
    }

    @Test func inputPinsByNameAndSystemClearsThePin() async throws {
        await CLIProbe.inWorld { world in
            let selected = AudioSelection()
            CLIEnvironment.audioSnapshot = { Self.snapshot }
            CLIEnvironment.setAudioInput = { selected.set($0) }
            var result = await CLIProbe.capture(["audio", "input", "Studio Mic"])
            #expect(result.code == 0)
            #expect(selected.value == "input-1")
            #expect(
                world.shared.string(forKey: AppStorageKeys.Audio.preferredInputUID)
                    == "input-1")
            result = await CLIProbe.capture(["audio", "input", "system"])
            #expect(result.code == 0)
            #expect(
                world.shared.object(forKey: AppStorageKeys.Audio.preferredInputUID) == nil)
        }
    }

    @Test func outputSwitchesByUIDAndRejectsSystem() async throws {
        await CLIProbe.inWorld { _ in
            let selected = AudioSelection()
            CLIEnvironment.audioSnapshot = { Self.snapshot }
            CLIEnvironment.setAudioOutput = { selected.set($0) }
            var result = await CLIProbe.capture(["audio", "output", "output-2"])
            #expect(result.code == 0)
            #expect(selected.value == "output-2")
            result = await CLIProbe.capture(["audio", "output", "system"])
            #expect(result.code == ExitCodes.usage)
        }
    }

    @Test func routePersistsUIDAndSystemRemovesIt() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.audioSnapshot = { Self.snapshot }
            var result = await CLIProbe.capture([
                "audio", "route", "com.example.Player", "USB Headphones",
            ])
            #expect(result.code == 0)
            #expect(
                AudioControlPolicy.routeMap(
                    world.shared.dictionary(forKey: AppStorageKeys.Audio.appOutputRoutes))[
                        "com.example.Player"] == "output-2")
            result = await CLIProbe.capture([
                "audio", "route", "com.example.Player", "system",
            ])
            #expect(result.code == 0)
            #expect(
                AudioControlPolicy.routeMap(
                    world.shared.dictionary(forKey: AppStorageKeys.Audio.appOutputRoutes)
                ).isEmpty)
        }
    }

    @Test func routeRejectsUnknownDevicesAndMalformedBundleIdentifiers() async throws {
        await CLIProbe.inWorld { _ in
            CLIEnvironment.audioSnapshot = { Self.snapshot }
            var result = await CLIProbe.capture([
                "audio", "route", "com.example.Player", "Nowhere",
            ])
            #expect(result.code == ExitCodes.notFound)
            result = await CLIProbe.capture(["audio", "route", "Music", "system"])
            #expect(result.code == ExitCodes.usage)
        }
    }
}
