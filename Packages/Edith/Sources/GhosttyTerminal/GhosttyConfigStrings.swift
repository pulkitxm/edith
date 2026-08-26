import Darwin
import GhosttyKit

final class GhosttyConfigStrings {
    let command: UnsafePointer<CChar>?
    let workingDirectory: UnsafePointer<CChar>?
    let environment: [ghostty_env_var_s]

    private let owned: [UnsafeMutablePointer<CChar>]

    init(launch: GhosttyLaunch) {
        var allocated: [UnsafeMutablePointer<CChar>] = []

        func copy(_ value: String) -> UnsafePointer<CChar> {
            let pointer = strdup(value)!
            allocated.append(pointer)
            return UnsafePointer(pointer)
        }

        command = copy(launch.command)
        workingDirectory = launch.workingDirectory.map(copy)
        environment = launch.environment.compactMap { entry in
            guard let split = entry.firstIndex(of: "=") else { return nil }
            return ghostty_env_var_s(
                key: copy(String(entry[entry.startIndex..<split])),
                value: copy(String(entry[entry.index(after: split)...])))
        }
        owned = allocated
    }

    deinit {
        for pointer in owned { free(pointer) }
    }
}
