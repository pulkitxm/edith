import EdithExtensionSupport
import Foundation
public enum ForegroundProcess {
    public static func environment(
        assignments: [String], inheriting: Bool
    ) -> [String: String] {
        var base: [String: String] = [:]
        if inheriting {
            base = ProcessInfo.processInfo.environment.filter {
                !ExtensionEnvironment.isPrivate($0.key)
            }
        }
        return assignments.reduce(into: base) { partial, entry in
            guard let index = entry.firstIndex(of: "=") else { return }
            partial[String(entry[entry.startIndex..<index])] =
                String(entry[entry.index(after: index)...])
        }
    }

    public static func configured(
        executable: URL, arguments: [String], environment: [String: String]
    ) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        return process
    }
}
