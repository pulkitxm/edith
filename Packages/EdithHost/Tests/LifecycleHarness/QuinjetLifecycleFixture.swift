import Darwin
import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor enum QuinjetLifecycleFixture {
    struct Handle: Codable, Equatable {
        let owner: String
        let id: UUID
        let generation: UUID
    }
    struct Terminal: Codable { let handle: Handle }
    struct Tab: Codable { let id: UUID; let terminal: Terminal? }
    struct State: Codable {
        let owner: String
        let generation: UUID
        let sequence: UInt64
        let tabs: [Tab]
        let selected: UUID
    }
    struct Output: Codable {
        let bytes: Data
        let nextOffset: UInt64
        let exitCode: Int32?
        let canonical: Bool
        let echo: Bool
    }
    struct Receipt: Codable {
        let pid: Int32
        let birth: String
        let parent: Int32
        let group: Int32
        let inputTerminal: Bool
        let executable: String
        let script: String
        let scriptSHA256: String
        let tabID: UUID
    }
    struct Process: Equatable {
        let pid: Int32
        let birth: String
        let parent: Int32
        let group: Int32
        let executable: String
        let inputTerminal: Bool
        let arguments: [String]
    }

    static func verify(
        invoke: (String, Data) async throws -> Data, workerPID: Int32,
        script: String, scriptSHA256: String, receipt: () throws -> Data?,
        process: (Int32, Int32) throws -> Process,
        timeout: Duration = .seconds(10)
    ) async throws -> Int32 {
        func call(_ operation: String, _ object: [String: Any] = [:]) async throws -> Data {
            try await invoke(operation, JSONSerialization.data(withJSONObject: object))
        }
        func state() async throws -> State {
            let state = try JSONDecoder().decode(State.self, from: await call("quinjet.ui.read"))
            guard state.owner == "quinjet", !state.tabs.isEmpty, state.tabs.count <= 32,
                Set(state.tabs.map(\.id)).count == state.tabs.count,
                state.tabs.contains(where: { $0.id == state.selected }),
                state.tabs.allSatisfy({
                    $0.terminal?.handle.owner == "quinjet" || $0.terminal == nil
                })
            else { throw failure("Invalid current terminal descriptors") }
            return state
        }
        let deadline = ContinuousClock.now + timeout
        var initial: State?
        var owned: Receipt?
        while initial == nil || owned == nil {
            let current = try await state()
            if let data = try receipt() {
                guard data.count <= 8192 else { throw failure("Oversized direct-tool receipt") }
                let value = try JSONDecoder().decode(Receipt.self, from: data)
                guard current.tabs.count == 1, current.tabs.first?.id == value.tabID,
                    current.tabs.first?.terminal != nil,
                    value.pid > 1, value.pid != workerPID, value.parent == workerPID,
                    value.group == value.pid, value.inputTerminal,
                    value.script == script, value.scriptSHA256 == scriptSHA256,
                    value.executable.hasPrefix("/"), !value.executable.contains("\0")
                else { throw failure("Rejected direct-tool receipt ownership or script identity") }
                let live = try process(value.pid, workerPID)
                try validate(value, live: live)
                initial = current
                owned = value
            }
            guard ContinuousClock.now < deadline else {
                throw failure("Missing direct-tool receipt")
            }
            if owned == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        guard let initial, let owned, let tab = initial.tabs.first, let terminal = tab.terminal
        else {
            throw failure("Missing current terminal descriptor")
        }
        let handle = terminal.handle
        func session(_ handle: Handle) -> [String: String] {
            [
                "owner": handle.owner, "id": handle.id.uuidString,
                "generation": handle.generation.uuidString,
            ]
        }
        let stale = Handle(owner: handle.owner, id: handle.id, generation: UUID())
        do {
            _ = try await call("quinjet.terminal.read", ["session": session(stale), "offset": 0])
            throw failure("Stale terminal generation accepted")
        } catch ExtensionPeerError.invalidRequest {
        } catch let ExtensionPeerError.rejected(message)
            where message == ExtensionPeerError.invalidRequest.localizedDescription
        {
        }
        _ = try await call(
            "quinjet.terminal.resize",
            [
                "session": session(handle), "columns": 90, "rows": 30,
                "pixelWidth": 0, "pixelHeight": 0,
            ])
        let marker = "quinjet-fixture-" + UUID().uuidString
        _ = try await call(
            "quinjet.terminal.input",
            [
                "session": session(handle),
                "bytes": Data((marker + "\n").utf8).base64EncodedString(),
            ])
        var bytes = Data()
        var offset: UInt64 = 0
        let action = Data("\u{1B}]6973;quinjet;open-new-tab\u{7}".utf8)
        while bytes.range(of: action) == nil
            || !String(decoding: bytes, as: UTF8.self).contains("synthetic-input:" + marker)
        {
            try validate(owned, live: process(owned.pid, workerPID))
            let output = try JSONDecoder().decode(
                Output.self,
                from: await call(
                    "quinjet.terminal.read", ["session": session(handle), "offset": offset]))
            guard output.bytes.count <= 32_768,
                output.nextOffset == offset + UInt64(output.bytes.count),
                output.exitCode == nil, output.canonical, output.echo,
                bytes.count + output.bytes.count <= 65_536
            else { throw failure("Invalid owned terminal stream") }
            bytes.append(output.bytes)
            offset = output.nextOffset
            guard ContinuousClock.now < deadline else {
                throw failure("Missing synthetic PTY output")
            }
        }
        let accepted =
            try JSONSerialization.jsonObject(
                with: await call(
                    "quinjet.native.action",
                    ["tabID": tab.id.uuidString, "action": "quinjet;open-new-tab"]))
            as? [String: Bool]
        guard accepted == ["accepted": true] else { throw failure("Managed action rejected") }
        while true {
            try validate(owned, live: process(owned.pid, workerPID))
            let current = try await state()
            guard current.generation == initial.generation, current.sequence > initial.sequence,
                current.tabs.first(where: { $0.id == tab.id })?.terminal?.handle == handle
            else { throw failure("Terminal generation changed during managed action") }
            if current.tabs.count == 2 { return owned.pid }
            guard ContinuousClock.now < deadline else {
                throw failure("Managed action did not create a tab")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func validate(_ receipt: Receipt, live: Process) throws {
        guard live.pid == receipt.pid, live.birth == receipt.birth,
            live.parent == receipt.parent, live.group == receipt.group,
            live.inputTerminal, live.executable == receipt.executable,
            live.arguments.contains(receipt.script)
        else { throw failure("Direct-tool process identity changed or script was substituted") }
    }

    static func process(_ pid: Int32, parent: Int32) throws -> Process {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
            info.pbi_pid == UInt32(pid), info.pbi_ppid == UInt32(parent), info.pbi_uid == getuid()
        else { throw failure("Direct-tool process is not owned by the selected worker") }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            throw failure("Missing direct-tool executable identity")
        }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 4, length <= 65_536 else {
            throw failure("Missing bounded direct-tool arguments")
        }
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 3, &bytes, &length, nil, 0) == 0 else {
            throw failure("Missing direct-tool arguments")
        }
        let birth = "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
        guard ExtensionProcessIdentity.read(pid)?.generation == birth else {
            throw failure("Direct-tool birth identity changed while reading arguments")
        }
        return Process(
            pid: pid, birth: birth, parent: Int32(info.pbi_ppid), group: Int32(info.pbi_pgid),
            executable: URL(
                fileURLWithPath: String(
                    decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                    as: UTF8.self)
            ).resolvingSymlinksInPath().path,
            inputTerminal: info.e_tdev != UInt32.max && info.e_tdev != 0,
            arguments: try arguments(Data(bytes.prefix(length))))
    }

    static func arguments(_ data: Data) throws -> [String] {
        guard data.count > 4, data.count <= 65_536 else {
            throw failure("Invalid process argument bytes")
        }
        let bytes = [UInt8](data)
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 256, let executableEnd = bytes[4...].firstIndex(of: 0) else {
            throw failure("Invalid process argument header")
        }
        var offset = executableEnd + 1
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        var result: [String] = []
        for _ in 0..<count {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0),
                let value = String(bytes: bytes[offset..<end], encoding: .utf8)
            else { throw failure("Truncated process arguments") }
            result.append(value)
            offset = end + 1
        }
        return result
    }

    private static func failure(_ reason: String) -> NSError {
        NSError(domain: "QuinjetFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}
