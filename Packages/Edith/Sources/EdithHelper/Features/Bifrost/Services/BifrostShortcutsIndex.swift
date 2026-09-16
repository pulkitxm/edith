import EdithKit
import Foundation

enum BifrostShortcutsIndex {
    static let maximumShortcuts = 400

    static func names() async -> [String] {
        let outcome = await LocalMachineCommandExecution.run("shortcuts list", timeout: 10)
        guard case .success(let text) = outcome else { return [] }
        return names(from: text)
    }

    static func names(from text: String) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for line in text.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(name), names.count < maximumShortcuts else {
                continue
            }
            seen.insert(name)
            names.append(name)
        }
        return names
    }

    static func run(name: String) async -> Bool {
        let command = "shortcuts run \(BifrostRipgrep.shellQuoted(name))"
        let outcome = await LocalMachineCommandExecution.run(command, timeout: 120)
        switch outcome {
        case .success: return true
        case .failure: return false
        }
    }
}
