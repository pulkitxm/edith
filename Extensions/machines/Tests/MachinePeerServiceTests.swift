@testable import MachinesExtension
import CryptoKit
import EdithExtensionSupport
import Foundation
import Testing

@Suite @MainActor struct MachinePeerServiceTests {
    private func fixture() -> (MachineRegistry.Files, URL, Machine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = MachineRegistry.Files(
            machines: root.appendingPathComponent("machines.json"),
            forwards: root.appendingPathComponent("forwards.json"),
            snippets: root.appendingPathComponent("snippets.json"))
        let machine = Machine(
            name: "Synthetic builder", host: "builder.invalid", username: "test",
            createdAt: Date(timeIntervalSince1970: 1))
        MachineRegistry.add(machine, files)
        return (files, root, machine)
    }
    private func payload(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private var document: Data {
        Data(
            "{\"schemaVersion\":8,\"generatedAt\":\"2026-10-09T00:00:00Z\",\"sources\":[],\"daily\":[],\"sessions\":[],\"totals\":{}}"
                .utf8)
    }

    @Test func companionUsesOnlyTheRegistryTargetAndBoundedInput() async throws {
        let (files, root, machine) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var runs = 0
        let usage = MachineUsageCollectionService(files: files) { _, _ in self.document }
        let peer = MachinePeerService(
            files: files, usage: usage,
            run: { selected, command, input, timeout in
                #expect(selected == machine); #expect(command == "printf test")
                #expect(input == Data("stdin".utf8)); #expect(timeout == 30)
                runs += 1; return "synthetic result"
            }, forward: { _, _ in true })
        let hosts = try object(
            await peer.execute("machines.companion.hosts", payload: payload([:])))
        let host = try #require((hosts["machines"] as? [[String: Any]])?.first)
        #expect(host["sshTarget"] as? String == "test@builder.invalid")
        let request: [String: Any] = [
            "machineID": machine.id.uuidString, "command": "printf test",
            "stdinbase64": Data("stdin".utf8).base64EncodedString(), "timeout": 30,
        ]
        let output = try object(
            await peer.execute("machines.companion.run", payload: payload(request)))
        #expect(output["output"] as? String == "synthetic result")
        for change in [
            ["timeout": 1801], ["timeout": 0], ["stdinbase64": "!"],
            ["machineID": UUID().uuidString], ["host": "other.invalid"], ["path": "/tmp/input"],
        ] as [[String: Any]] {
            let invalid = request.merging(change) { $1 }
            await #expect(throws: (any Error).self) {
                try await peer.execute("machines.companion.run", payload: payload(invalid))
            }
        }
        #expect(runs == 1)
        peer.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await peer.execute("machines.companion.hosts", payload: payload([:]))
        }
    }

    @Test func companionProjectsOnlyConcreteSavedSourceAliasesAcrossRenameAndReload() async throws {
        let (files, root, manual) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var imported = Machine(
            name: "Renamed build machine", host: "resolved.invalid",
            username: "fixture", source: .sshConfigAlias("original-build-alias"),
            createdAt: Date(timeIntervalSince1970: 1))
        MachineRegistry.add(imported, files)
        let wildcard = Machine(
            name: "Unsupported saved pattern", host: "pattern.invalid",
            source: .sshConfigAlias("build-*"), createdAt: Date(timeIntervalSince1970: 1))
        MachineRegistry.add(wildcard, files)
        let usage = MachineUsageCollectionService(files: files) { _, _ in self.document }
        let peer = MachinePeerService(
            files: files, usage: usage,
            run: { _, _, _, _ in throw ExtensionPeerError.unavailable },
            forward: { _, _ in throw ExtensionPeerError.unavailable })
        func hosts() async throws -> [[String: Any]] {
            let value = try object(
                await peer.execute("machines.companion.hosts", payload: payload([:])))
            return try #require(value["machines"] as? [[String: Any]])
        }
        let first = try await hosts()
        let saved = try #require(first.first { $0["id"] as? String == imported.id.uuidString })
        #expect(saved["aliases"] as? [String] == ["original-build-alias"])
        #expect(saved["name"] as? String == "Renamed build machine")
        #expect(saved["sshTarget"] as? String == "original-build-alias")
        #expect(first.first { $0["id"] as? String == manual.id.uuidString }?["aliases"] == nil)
        #expect(first.first { $0["id"] as? String == wildcard.id.uuidString }?["aliases"] == nil)
        imported.name = "Second saved name"
        MachineRegistry.update(imported, files)
        let updated = try await hosts()
        #expect(
            updated.first { $0["id"] as? String == imported.id.uuidString }?["aliases"] as? [String]
                == ["original-build-alias"])
        imported.source = .manual
        MachineRegistry.update(imported, files)
        let converted = try await hosts()
        #expect(
            converted.first { $0["id"] as? String == imported.id.uuidString }?["aliases"] == nil)
        await #expect(throws: ExtensionPeerError.self) {
            try await peer.execute(
                "machines.companion.hosts", payload: payload(["aliases": ["raw.invalid"]]))
        }
        peer.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await peer.execute("machines.companion.hosts", payload: payload([:]))
        }
    }

    @Test func databaseRequiresUniqueSavedLoopbackForwardsAndOneMachine() async throws {
        let (files, root, machine) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var forwarded: [PortForward] = []
        let usage = MachineUsageCollectionService(files: files) { _, _ in self.document }
        let peer = MachinePeerService(
            files: files, usage: usage, run: { _, _, _, _ in "" },
            forward: { target, saved in
                #expect(target == machine); forwarded.append(saved); return true
            })
        let first = PortForward(machineID: machine.id, localPort: 15432, remotePort: 5432)
        let second = PortForward(
            machineID: machine.id, localPort: 16379, remoteHost: "127.0.0.1", remotePort: 6379)
        MachineRegistry.addForward(first, files); MachineRegistry.addForward(second, files)
        let result = try object(
            await peer.execute(
                "machines.forward.prepare", payload: payload(["ports": [15432, 16379]])))
        #expect(result["prepared"] as? Bool == true);
        #expect(result["name"] as? String == machine.name)
        #expect(forwarded == [first, second])
        for ports in [[], [0], [65536], [15432, 15432], [9999], Array(1...9)] {
            await #expect(throws: (any Error).self) {
                try await peer.execute(
                    "machines.forward.prepare", payload: payload(["ports": ports]))
            }
        }
        MachineRegistry.addForward(first, files)
        await #expect(throws: (any Error).self) {
            try await peer.execute("machines.forward.prepare", payload: payload(["ports": [15432]]))
        }
        #expect(forwarded.count == 2)
        MachineRegistry.removeForward(id: first.id, files)
        MachineRegistry.addForward(
            PortForward(
                machineID: machine.id, localPort: 15432, remoteHost: "public.invalid",
                remotePort: 5432), files)
        await #expect(throws: (any Error).self) {
            try await peer.execute("machines.forward.prepare", payload: payload(["ports": [15432]]))
        }
        #expect(forwarded.count == 2)
    }

    @Test func usageRejectsArbitraryInputsAndPreservesCompletedDataAfterFailure() async throws {
        let (files, root, machine) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var collects = 0
        let usage = MachineUsageCollectionService(files: files) { selected, _ in
            #expect(selected == machine); collects += 1
            if collects == 2 { throw ExtensionPeerError.unavailable }
            return self.document
        }
        let request: [String: Any] = ["machineID": machine.id.uuidString, "force": true]
        for change in [
            ["command": "uname"], ["path": "/etc/passwd"], ["host": "other.invalid"],
            ["machineID": UUID().uuidString],
        ] {
            await #expect(throws: (any Error).self) {
                try await usage.execute(
                    "machines.usage.collect", payload: payload(request.merging(change) { $1 }))
            }
        }
        #expect(collects == 0)
        let descriptor = try object(
            await usage.execute("machines.usage.collect", payload: payload(request)))
        let id = try #require(descriptor["collectionID"] as? String)
        #expect(descriptor["byteCount"] as? Int == document.count)
        #expect(
            descriptor["sha256"] as? String
                == SHA256.hash(data: document).map { String(format: "%02x", $0) }.joined())
        await #expect(throws: ExtensionPeerError.self) {
            try await usage.execute("machines.usage.collect", payload: payload(request))
        }
        var result = Data()
        while result.count < document.count {
            let chunk = try object(
                await usage.execute(
                    "machines.usage.result",
                    payload: payload([
                        "collectionID": id, "offset": result.count, "maximumBytes": 13,
                    ])))
            #expect(chunk["offset"] as? Int == result.count)
            let encoded = try #require(chunk["data"] as? String)
            result.append(try #require(Data(base64Encoded: encoded)))
            #expect(chunk["finished"] as? Bool == (result.count == document.count))
        }
        #expect(result == document)
        for change in [
            ["offset": -1], ["offset": document.count + 1], ["maximumBytes": 262145],
            ["maximumBytes": 0], ["collectionID": UUID().uuidString],
        ] as [[String: Any]] {
            await #expect(throws: (any Error).self) {
                try await usage.execute(
                    "machines.usage.result",
                    payload: payload(
                        [
                            "collectionID": id, "offset": 0, "maximumBytes": 32,
                        ].merging(change) { $1 }))
            }
        }
        _ = try await usage.execute("machines.usage.cancel", payload: payload(["collectionID": id]))
        await #expect(throws: (any Error).self) {
            try await usage.execute(
                "machines.usage.result",
                payload: payload(["collectionID": id, "offset": 0, "maximumBytes": 32]))
        }
    }

    @Test func registryChangeAndExpirationInvalidateOpaqueCollections() async throws {
        let (files, root, machine) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var clock = Date(timeIntervalSince1970: 0)
        let usage = MachineUsageCollectionService(files: files, lifetime: 5, now: { clock }) {
            _, _ in self.document
        }
        let request: [String: Any] = ["machineID": machine.id.uuidString, "force": true]
        let descriptor = try object(
            await usage.execute("machines.usage.collect", payload: payload(request)))
        let id = try #require(descriptor["collectionID"] as? String)
        var changed = machine; changed.host = "replacement.invalid";
        MachineRegistry.update(changed, files)
        await #expect(throws: (any Error).self) {
            try await usage.execute(
                "machines.usage.result",
                payload: payload(["collectionID": id, "offset": 0, "maximumBytes": 32]))
        }
        let next = try object(
            await usage.execute("machines.usage.collect", payload: payload(request)))
        let nextID = try #require(next["collectionID"] as? String)
        clock = clock.addingTimeInterval(6)
        await #expect(throws: (any Error).self) {
            try await usage.execute(
                "machines.usage.result",
                payload: payload(["collectionID": nextID, "offset": 0, "maximumBytes": 32]))
        }
    }

    @Test func cancellationStopsOwnedCollectionAndPreventsPublication() async throws {
        let (files, root, machine) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var cancelled = false
        let usage = MachineUsageCollectionService(files: files) { _, _ in
            do { try await Task.sleep(for: .seconds(300)) } catch { cancelled = true; throw error }
            return self.document
        }
        let task = Task {
            try await usage.execute(
                "machines.usage.collect",
                payload: payload(["machineID": machine.id.uuidString, "force": true]))
        }
        for _ in 0..<20 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelled)
        usage.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await usage.execute(
                "machines.usage.collect",
                payload: payload(["machineID": machine.id.uuidString, "force": true]))
        }
    }
}
