import Darwin
import EdithExtensionSupport
import Foundation

public enum HostCLI {
    public static func run(_ arguments: [String]) -> Int32 {
        run(arguments, invoke: invokeRunningHost) { data, error in
            (error ? FileHandle.standardError : FileHandle.standardOutput).write(data)
        }
    }

    static func run(
        _ arguments: [String], invoke: (HostCLIRequest) throws -> Data,
        write: (Data, Bool) -> Void
    ) -> Int32 {
        do {
            switch try HostCLICommand.parse(arguments, readInput: readInput) {
            case .help: print(HostCLICommand.usageText)
            case .version:
                let version =
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "development"
                print(
                    String(
                        decoding: try JSONSerialization.data(withJSONObject: ["version": version]),
                        as: UTF8.self))
            case .request(let request):
                let data = try invoke(request)
                write(try output(data, raw: request.raw), false)
                write(Data([10]), false)
            case .terminal(let request):
                let reply = try JSONDecoder().decode(ExtensionCLIReply.self, from: invoke(request))
                try reply.validate()
                write(Data(reply.stdout.utf8), false)
                write(Data(reply.stderr.utf8), true)
                return reply.exitCode
            }
            return 0
        } catch {
            let failure = error as? HostCLIError ?? .rejected(error.localizedDescription)
            if arguments.first == "calendar" {
                let code: Int32
                if case .unavailable = failure { code = 4 } else { code = failure.exitCode }
                write(Data("error: \(failure.localizedDescription)\n".utf8), true)
                return code
            }
            let data = try? JSONSerialization.data(
                withJSONObject: [
                    "error": failure.localizedDescription,
                    "exitCode": failure.exitCode,
                ], options: .sortedKeys)
            write(data ?? Data("The command failed.".utf8), true)
            write(Data([10]), true)
            return failure.exitCode
        }
    }

    private static func invokeRunningHost(_ request: HostCLIRequest) throws -> Data {
        guard let identifier = Bundle.main.bundleIdentifier else { throw HostCLIError.unavailable }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        let identity = try HostIdentity(identifier: identifier, supportDirectory: support)
        return try HostCLITransport.invoke(request, identity: identity)
    }

    public static func output(_ data: Data, raw: Bool) throws -> Data {
        guard raw else { return data }
        guard
            let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
                as? String
        else {
            throw HostCLIError.rejected("--raw requires a JSON string response from the worker.")
        }
        return Data(value.utf8)
    }

    private static func readInput() throws -> Data {
        guard isatty(STDIN_FILENO) == 0 else {
            throw HostCLIError.usage("Pipe JSON into stdin with --json -.")
        }
        var result = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw HostCLIError.timedOut }
            var event = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, Int32(remaining * 1000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw HostCLIError.timedOut }
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw HostCLIError.usage("Could not read JSON from stdin.") }
            if count == 0 { return result }
            result.append(contentsOf: bytes.prefix(count))
            guard result.count <= HostCLIRequest.maximumPayload else {
                throw HostCLIError.usage("The JSON payload exceeds 512 KiB.")
            }
        }
    }
}
