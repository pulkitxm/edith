import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor enum TerminalLifecycleFixture {
    struct Session: Codable, Equatable {
        let id: UUID
        let generation: UUID
        let title: String
        let directory: String
        let running: Bool
        let selected: Bool
        let error: String?
    }

    struct Snapshot: Codable {
        let sessions: [Session]
        let broadcast: Bool
    }

    struct Output: Codable {
        let bytes: Data
        let nextOffset: UInt64
        let exitCode: Int32?
        let canonical: Bool
        let echo: Bool
    }

    static func verify(
        invoke: (String, Data) async throws -> Data,
        children: () -> [Int32]
    ) async throws -> [Int32] {
        func call(_ command: String, _ input: [String: Any] = [:]) async throws -> Data {
            try await invoke(command, JSONSerialization.data(withJSONObject: input))
        }
        func snapshot(_ command: String, _ input: [String: Any] = [:]) async throws -> Snapshot {
            let result = try decodeSnapshot(try await call(command, input))
            guard !result.broadcast else { throw HostWorkerError.invalidResponse }
            return result
        }
        func settled(_ expected: [Session]) async throws -> [Int32] {
            let deadline = Date().addingTimeInterval(20)
            while true {
                let current = try await snapshot("terminal.snapshot")
                let descendants = children()
                if current.sessions.count == expected.count,
                    expected.allSatisfy({ wanted in
                        current.sessions.contains {
                            $0.id == wanted.id && $0.generation == wanted.generation
                                && $0.running && $0.error == nil
                        }
                    }), descendants.count >= expected.count
                {
                    return descendants
                }
                guard Date() < deadline else { throw HostWorkerError.invalidResponse }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        let opened = try await snapshot("terminal.open")
        guard opened.sessions.count == 1, let first = opened.sessions.first, first.selected else {
            throw HostWorkerError.invalidResponse
        }
        _ = try await settled([first])
        let selected = try await snapshot("terminal.select", session(first))
        guard selected.sessions.count == 1, selected.sessions.first == first else {
            throw HostWorkerError.invalidResponse
        }
        let next = try await snapshot("terminal.open")
        guard next.sessions.count == 2,
            let second = next.sessions.first(where: { $0.id != first.id }), second.selected,
            next.sessions.contains(where: {
                $0.id == first.id && $0.generation == first.generation && !$0.selected
            })
        else { throw HostWorkerError.invalidResponse }
        let descendants = try await settled([first, second])
        var tile = SurfaceTile(.ability("terminal"))
        tile.itemLimit = 20
        let surface = try SurfaceSnapshot.decode(
            try await invoke(
                "surface.snapshot",
                SurfaceSnapshotRequest(target: .home, tile: tile).encoded(providerID: "terminal")),
            providerID: "terminal")
        guard Set(surface.rows.map(\.id)) == Set(next.sessions.map { $0.id.uuidString }),
            surface.rows.allSatisfy({ $0.title.utf8.count <= 512 && $0.value == "Running" }),
            surface.metrics.first(where: { $0.id == "sessions" })?.value == "2",
            surface.metrics.first(where: { $0.id == "running" })?.value == "2"
        else { throw HostWorkerError.invalidResponse }
        _ = try await snapshot(
            "terminal.resize",
            [
                "session": session(first), "columns": 90, "rows": 30,
                "widthPixels": 0, "heightPixels": 0,
            ])
        let suffix = UUID().uuidString
        let marker = "terminal-fixture-" + suffix
        let command = "printf '%s%s\\n' 'terminal-fixture-' '" + suffix + "'\n"
        _ = try await snapshot(
            "terminal.input",
            ["session": session(first), "bytes": Data(command.utf8).base64EncodedString()])
        var offset: UInt64 = 0
        var bytes = Data()
        let deadline = Date().addingTimeInterval(10)
        while !String(decoding: bytes, as: UTF8.self).contains(marker) {
            let output = try JSONDecoder().decode(
                Output.self,
                from: try await call(
                    "terminal.read", ["session": session(first), "offset": offset]))
            guard output.bytes.count <= 32_768,
                output.nextOffset == offset + UInt64(output.bytes.count),
                output.exitCode == nil, !output.canonical, !output.echo,
                bytes.count + output.bytes.count <= 262_144
            else { throw HostWorkerError.invalidResponse }
            bytes.append(output.bytes)
            offset = output.nextOffset
            guard Date() < deadline else { throw HostWorkerError.invalidResponse }
        }
        let broadcast =
            try JSONSerialization.jsonObject(
                with: try await call("terminal.broadcast", ["command": "true"])) as? [String: Any]
        guard broadcast?["sent"] as? Int == 2, broadcast?["unavailable"] as? Int == 0 else {
            throw HostWorkerError.invalidResponse
        }
        for (command, input) in [
            ("terminal.broadcast", ["command": " "]),
            ("terminal.select", ["id": first.id.uuidString, "generation": UUID().uuidString]),
            ("terminal.snapshot", ["unexpected": true]), ("terminal.unknown", [:]),
        ] as [(String, [String: Any])] {
            do {
                _ = try await call(command, input)
                throw HostWorkerError.invalidResponse
            } catch ExtensionPeerError.invalidRequest {
            } catch let ExtensionPeerError.rejected(message)
                where message == ExtensionPeerError.invalidRequest.localizedDescription
            {}
        }
        return descendants
    }

    static func decodeSnapshot(_ data: Data) throws -> Snapshot {
        guard data.count <= 262_144 else { throw HostWorkerError.invalidResponse }
        let result = try JSONDecoder().decode(Snapshot.self, from: data)
        guard !result.sessions.isEmpty, result.sessions.count <= 32,
            Set(result.sessions.map(\.id)).count == result.sessions.count,
            result.sessions.filter(\.selected).count == 1,
            result.sessions.allSatisfy({
                $0.title.utf8.count <= 512 && $0.directory.utf8.count <= 4_096
                    && !$0.title.utf8.contains(0) && !$0.directory.utf8.contains(0)
            })
        else { throw HostWorkerError.invalidResponse }
        return result
    }

    private static func session(_ value: Session) -> [String: Any] {
        ["id": value.id.uuidString, "generation": value.generation.uuidString]
    }
}
