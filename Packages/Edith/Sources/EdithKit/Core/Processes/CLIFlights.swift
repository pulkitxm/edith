import Darwin
import Foundation

public struct CLIFlight: Codable, Equatable, Sendable {
    public var id: String
    public var pid: Int32
    public var kind: String
    public var action: String
    public var target: String

    public init(id: String, pid: Int32, kind: String, action: String, target: String) {
        self.id = id
        self.pid = pid
        self.kind = kind
        self.action = action
        self.target = target
    }
}

public enum CLIFlights {
    public static var directoryOverride: URL?
    public static var directory: URL {
        (directoryOverride ?? DataRoot.support).appendingPathComponent(
            "cli-flights", isDirectory: true)
    }

    public static var alive: (Int32) -> Bool = { kill($0, 0) == 0 }
    public static var signal: (Int32) -> Bool = { kill($0, SIGINT) == 0 }

    public static func begin(
        kind: String, action: String, target: String, pid: Int32? = nil, onlyCLI: Bool = true
    ) -> CLIFlight? {
        if onlyCLI, ProcessInfo.processInfo.processName != "ed" { return nil }
        let flight = CLIFlight(
            id: UUID().uuidString, pid: pid ?? ProcessInfo.processInfo.processIdentifier,
            kind: kind, action: action, target: target)
        let url = directory.appendingPathComponent("\(flight.id).json")
        guard let data = try? JSONEncoder().encode(flight) else { return nil }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return flight
    }

    public static func end(_ id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }

    public static func list(kind: String) -> [CLIFlight] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                let flight = try? JSONDecoder().decode(CLIFlight.self, from: data),
                flight.kind == kind
            else { return nil }
            return flight
        }.sorted { $0.pid < $1.pid }
    }

    public static func signal(
        kind: String, excluding pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [CLIFlight] {
        var stopped: [CLIFlight] = []
        for flight in list(kind: kind) {
            guard flight.pid != pid else { continue }
            guard alive(flight.pid) else {
                end(flight.id)
                continue
            }
            if signal(flight.pid) { stopped.append(flight) }
            end(flight.id)
        }
        return stopped
    }
}
