import Foundation

public enum ArgumentRewriting {
    public static let reserved: Set<String> = Set(
        CommandTree.topLevelNames + ["__complete", "help"])

    public static let machinesGroup = "machines"

    public static var machinesNode: CommandNode? {
        CommandTree.root.child(machinesGroup)
    }

    public static var machineSubcommands: Set<String> {
        Set(machinesNode?.children.flatMap(\.names) ?? [])
    }

    public static func rewrite(_ arguments: [String], machines: [String]) -> [String] {
        guard let first = arguments.first, !first.hasPrefix("-") else { return arguments }
        guard first != machinesGroup else { return machineFirst(arguments) }
        guard !reserved.contains(first) else { return arguments }
        guard machines.contains(where: { $0.lowercased() == first.lowercased() }) else {
            return arguments
        }
        let tail = Array(arguments.dropFirst())
        guard tail.contains(where: { !$0.hasPrefix("-") }) else {
            return [machinesGroup, "show", first] + tail
        }
        return [machinesGroup, "exec", first, "--"] + tail
    }

    public static func machineFirst(_ arguments: [String]) -> [String] {
        let rest = Array(arguments.dropFirst())
        guard let candidate = rest.first, !candidate.hasPrefix("-"),
            !machineSubcommands.contains(candidate)
        else { return arguments }
        return [machinesGroup] + place(machine: candidate, before: Array(rest.dropFirst()))
    }

    public static func completionOrder(_ leading: [String]) -> [String] {
        guard leading.first == machinesGroup else { return leading }
        let rest = Array(leading.dropFirst())
        guard let candidate = rest.first, !candidate.hasPrefix("-"),
            !machineSubcommands.contains(candidate)
        else { return leading }
        var node = machinesNode
        var consumed: [String] = []
        for word in rest.dropFirst() {
            guard !word.hasPrefix("-"), let next = node?.child(word) else { break }
            node = next
            consumed.append(word)
        }
        let remainder = Array(rest.dropFirst(1 + consumed.count))
        return [machinesGroup] + consumed + [candidate] + remainder
    }

    static func place(machine: String, before tail: [String]) -> [String] {
        guard !tail.isEmpty else { return ["show", machine] }
        var node = machinesNode
        var consumed: [String] = []
        for word in tail {
            guard !word.hasPrefix("-"), let next = node?.child(word) else { break }
            node = next
            consumed.append(word)
        }
        let remainder = Array(tail.dropFirst(consumed.count))
        guard !consumed.isEmpty else {
            guard tail.contains(where: { !$0.hasPrefix("-") }) else {
                return ["show", machine] + tail
            }
            return ["exec", machine, "--"] + tail
        }
        guard node?.name == "exec" else { return consumed + [machine] + remainder }
        return consumed + [machine, "--"] + remainder
    }
}
