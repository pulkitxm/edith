import Darwin
import EdithKit
import Foundation

@main
struct UsageSnapshotCrashDriver {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 4, let identifier = UUID(uuidString: arguments[2]) else {
            exit(64)
        }
        let dataDirectory = URL(fileURLWithPath: arguments[0])
        let root = URL(fileURLWithPath: arguments[1])
        let point = arguments[3]
        let hooks = UsageSnapshotHooks(
            afterStagingFile: { _ in
                if point == "staging" { crash() }
            },
            beforePointerPublication: {
                if point == "pointer" { crash() }
            })
        let store = UsageSnapshotStore(
            source: UsageSnapshotSource(dataDirectory: dataDirectory), root: root, hooks: hooks)
        _ = try await store.publish(generation: identifier)
    }

    private static func crash() {
        _ = kill(getpid(), SIGKILL)
    }
}
