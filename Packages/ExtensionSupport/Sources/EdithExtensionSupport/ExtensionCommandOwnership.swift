import Darwin
import Foundation

public enum ExtensionCommandOwnership {
    public static let registerNotification = Notification.Name(
        "edith.extension.registerProcessGroup")
    public static let releaseNotification = Notification.Name("edith.extension.releaseProcessGroup")
    public static var isWorker: Bool {
        ProcessInfo.processInfo.environment["EDITH_EXTENSION_WORKER"] == "1"
    }

    public static func register(_ pid: Int32) throws {
        guard isWorker else { return }
        var accepted = false
        let accept: (Bool) -> Void = { accepted = $0 }
        NotificationCenter.default.post(
            name: registerNotification, object: nil, userInfo: ["pid": pid, "accept": accept])
        guard accepted else { throw CocoaError(.executableLoad) }
    }

    public static func release(_ pid: Int32) {
        guard isWorker else { return }
        NotificationCenter.default.post(
            name: releaseNotification, object: nil, userInfo: ["pid": pid])
    }
}

public struct ExtensionCommandSpecification: Codable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String?

    public init(
        executable: String, arguments: [String], environment: [String: String],
        directory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }

    public func write(to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 65_536 else { throw CocoaError(.fileWriteOutOfSpace) }
        var count = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &count) { try handle.write(contentsOf: Data($0)) }
        try handle.write(contentsOf: data)
    }

    public static func runWrapper() throws -> Never {
        guard ExtensionCommandOwnership.isWorker, getpgrp() == getppid() else {
            throw CocoaError(.executableLoad)
        }
        let handle = FileHandle(fileDescriptor: 3, closeOnDealloc: true)
        let header = try read(4, from: handle)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
        let command = try JSONDecoder().decode(Self.self, from: read(Int(count), from: handle))
        try handle.close()
        guard command.executable.hasPrefix("/"), !command.executable.utf8.contains(0),
            command.arguments.allSatisfy({ !$0.utf8.contains(0) }),
            command.environment.allSatisfy({
                !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0)
            }),
            command.directory.map({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) ?? true,
            setpgid(0, 0) == 0
        else { throw CocoaError(.executableLoad) }
        if let directory = command.directory, chdir(directory) != 0 {
            throw CocoaError(.fileReadNoPermission)
        }
        let arguments = ([command.executable] + command.arguments).map { strdup($0) }
        let environment = command.environment.map { strdup($0.key + "=" + $0.value) }
        defer { for item in arguments + environment { free(item) } }
        guard arguments.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else {
            throw CocoaError(.executableLoad)
        }
        var argv = arguments + [nil]
        var env = environment + [nil]
        for value in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] { signal(value, SIG_DFL) }
        _ = command.executable.withCString { path in
            argv.withUnsafeMutableBufferPointer { arguments in
                env.withUnsafeMutableBufferPointer { environment in
                    execve(path, arguments.baseAddress!, environment.baseAddress!)
                }
            }
        }
        throw CocoaError(.executableLoad)
    }

    private static func read(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            data.append(next)
        }
        return data
    }
}
