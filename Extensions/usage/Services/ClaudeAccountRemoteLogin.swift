import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation

enum ClaudeAccountRemoteLogin {
    private struct Request: Encodable {
        let machineID: UUID
        let command: String
        let timeout: TimeInterval
    }
    private struct Reply: Decodable { let output: String }

    static func token(
        account: ClaudeAccount,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentPeer: @Sendable () async -> UsageMachinesPeer? = {
            await UsageMachinesPeer.current()
        }
    ) async throws -> String? {
        try Task.checkCancellation()
        try account.validate()
        guard !account.isLoggedOut, account.authentication == .browserLogin,
            let association = account.remoteMachineID,
            let machineID = UUID(uuidString: association)
        else { return nil }
        let command = try readCommand(accountID: account.id, environment: environment)
        try Task.checkCancellation()
        guard let peer = await currentPeer(), await peer.active() else {
            throw ExtensionPeerError.unavailable
        }
        try Task.checkCancellation()
        let data = try await peer.invoke(
            "machines.companion.run",
            JSONEncoder().encode(Request(machineID: machineID, command: command, timeout: 5)))
        try Task.checkCancellation()
        guard await peer.active(), data.count <= 400_000 else {
            throw ExtensionPeerError.unavailable
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.output.utf8.count <= 65_536 else { throw ExtensionPeerError.invalidRequest }
        return ClaudeSavedLogin.token(data: Data(reply.output.utf8))
    }

    static func readCommand(accountID: UUID, environment: [String: String]) throws -> String {
        guard let namespace = environment["EDITH_APPLICATION_IDENTIFIER"],
            namespace.range(
                of: "^com\\.pulkit\\.edith(?:\\.(?:dev|tests)\\.[A-Za-z0-9_-]{1,160})?$",
                options: .regularExpression) != nil
        else { throw ClaudeAccountError.invalidRequest }
        let components = [".local", "share", "edith", namespace, "accounts", accountID.uuidString]
        let source = """
            import os, stat, sys
            home = os.environ.get("HOME", "")
            if not home.startswith("/") or os.path.realpath(home) != home or os.path.normpath(home) != home:
                sys.exit(1)
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
            directory = os.open(home, flags)
            if os.fstat(directory).st_uid != os.getuid():
                sys.exit(1)
            for index, component in enumerate(sys.argv[1:]):
                child = os.open(component, flags, dir_fd=directory)
                os.close(directory)
                directory = child
                metadata = os.fstat(directory)
                if metadata.st_uid != os.getuid() or (index >= 4 and metadata.st_mode & 0o077):
                    sys.exit(1)
            descriptor = os.open(".credentials.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=directory)
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600 or not 0 <= metadata.st_size <= 65536:
                sys.exit(1)
            data = os.read(descriptor, 65537)
            if len(data) > 65536:
                sys.exit(1)
            os.close(descriptor)
            os.close(directory)
            sys.stdout.buffer.write(data)
            """
        return "python3 -c " + quote(source) + " " + components.map(quote).joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
