import EdithCore
import Foundation

public enum HomebrewOperation: String, CaseIterable, Sendable {
    case status
    case list
    case search
    case install
    case upgrade
    case uninstall

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "homebrew.\(rawValue)"), summary: summary,
            cli: ["brew", rawValue == "list" ? "ls" : rawValue], effect: effect,
            requiresPreview: self == .uninstall)
    }

    private var summary: String {
        switch self {
        case .status: "Inspect the local Homebrew installation."
        case .list: "List installed Homebrew formulae and casks."
        case .search: "Search available Homebrew formulae and casks."
        case .install: "Install a Homebrew package."
        case .upgrade: "Upgrade a Homebrew package."
        case .uninstall: "Uninstall a Homebrew package."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .status, .list, .search: .read
        case .install, .upgrade: .write
        case .uninstall: .destructive
        }
    }
}

public struct HomebrewClient: Sendable {
    public typealias RunCommand =
        @Sendable (CLICommandRequest, @escaping @Sendable (String) -> Void) async throws ->
        CLICommandResult

    public let executableURL: URL?
    private let runCommand: RunCommand

    public init(
        executableURL: URL? = CLIToolEnvironment.executable(named: "brew"),
        runCommand: @escaping RunCommand = { try await CLICommandRunner.run($0, onLine: $1) }
    ) {
        self.executableURL = executableURL
        self.runCommand = runCommand
    }

    public func status() async -> HomebrewStatus {
        guard let executableURL else {
            return HomebrewStatus(available: false, executable: nil, version: nil)
        }
        let result = try? await run(
            arguments: ["--version"], timeout: 10, maximumOutputBytes: 32_768)
        let version = result?.output.split(whereSeparator: \.isNewline).first.map(String.init)
        return HomebrewStatus(
            available: result?.terminationStatus == 0, executable: executableURL.path,
            version: version)
    }

    public func installed(kind: HomebrewPackageKind? = nil, outdatedOnly: Bool = false) async throws
        -> [HomebrewPackage]
    {
        let installed = try await packages(arguments: ["info", "--json=v2", "--installed"])
        let outdatedResult = try await run(
            arguments: ["outdated", "--json=v2"], timeout: 60,
            maximumOutputBytes: 2_000_000, acceptsStatus: [0, 1])
        let updates = try HomebrewParser.packages(from: outdatedResult.output, outdated: true)
        let updatesByID = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
        return
            installed
            .map { updatesByID[$0.id].map($0.merging) ?? $0 }
            .filter { kind == nil || $0.kind == kind }
            .filter { !outdatedOnly || $0.outdated }
            .sorted(by: HomebrewPackageOrdering.areInIncreasingOrder)
    }

    public func search(_ query: String, kind: HomebrewPackageKind) async throws
        -> [HomebrewPackage]
    {
        let query = try HomebrewValidation.query(query)
        let flag = kind == .formula ? "--formula" : "--cask"
        let result = try await run(
            arguments: ["search", flag, query], timeout: 60, maximumOutputBytes: 500_000)
        let names = Array(HomebrewParser.searchNames(from: result.output).prefix(40))
        guard !names.isEmpty else { return [] }
        return try await packages(arguments: ["info", "--json=v2", flag] + names)
            .sorted(by: HomebrewPackageOrdering.areInIncreasingOrder)
    }

    public func mutate(
        _ action: HomebrewMutation, kind: HomebrewPackageKind, name: String,
        onActivity: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> HomebrewMutationResult {
        let name = try HomebrewValidation.token(name)
        var arguments = [action.rawValue]
        if kind == .cask { arguments.append("--cask") }
        arguments.append(name)
        let result = try await run(
            arguments: arguments, timeout: 1_800, maximumOutputBytes: 2_000_000,
            terminatesProcessGroup: true, onActivity: onActivity)
        return HomebrewMutationResult(
            action: action, kind: kind, name: name,
            output: HomebrewOutput.visibleTail(result.output))
    }

    private func packages(arguments: [String]) async throws -> [HomebrewPackage] {
        let result = try await run(
            arguments: arguments, timeout: 60, maximumOutputBytes: 2_000_000)
        return try HomebrewParser.packages(from: result.output)
    }

    private func run(
        arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int,
        acceptsStatus: Set<Int32> = [0], terminatesProcessGroup: Bool = false,
        onActivity: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> CLICommandResult {
        guard let executableURL else { throw HomebrewFailure.unavailable }
        var environment = CLIToolEnvironment.sanitized()
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NONINTERACTIVE"] = "1"
        do {
            let result = try await runCommand(
                CLICommandRequest(
                    executableURL: executableURL, arguments: arguments, environment: environment,
                    timeout: timeout, maximumOutputBytes: maximumOutputBytes,
                    terminatesProcessGroup: terminatesProcessGroup), onActivity)
            guard acceptsStatus.contains(result.terminationStatus) else {
                throw HomebrewFailure.commandFailed(
                    result.terminationStatus, HomebrewOutput.visibleTail(result.output))
            }
            return result
        } catch CLICommandRunnerError.timedOut {
            throw HomebrewFailure.timedOut
        } catch CLICommandRunnerError.outputLimitExceeded {
            throw HomebrewFailure.outputLimitExceeded
        }
    }
}

public enum HomebrewValidation {
    public static func token(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 180, !value.isEmpty, !value.hasPrefix("-"),
            !value.contains(".."), !value.contains("//"),
            value.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._+@/-]*$"#,
                options: .regularExpression) != nil
        else { throw HomebrewFailure.invalidToken(raw) }
        return value
    }

    public static func query(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(value.count), !value.hasPrefix("-"),
            !value.contains("\n"), !value.contains("\r")
        else { throw HomebrewFailure.invalidQuery }
        return value
    }
}

public enum HomebrewPackageOrdering {
    public static func areInIncreasingOrder(_ lhs: HomebrewPackage, _ rhs: HomebrewPackage) -> Bool
    {
        if lhs.outdated != rhs.outdated { return lhs.outdated }
        if lhs.kind != rhs.kind { return lhs.kind == .cask }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            == .orderedAscending
    }
}

public enum HomebrewOutput {
    public static func visibleTail(_ output: String) -> String {
        let lines =
            output
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.suffix(8).joined(separator: "\n")
    }
}

public enum HomebrewParser {
    public static func packages(from output: String, outdated: Bool = false) throws
        -> [HomebrewPackage]
    {
        var root: [String: Any]?
        for data in jsonObjects(in: output) {
            guard let candidate = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                candidate["formulae"] != nil || candidate["casks"] != nil
            else { continue }
            root = candidate
            break
        }
        guard let root else {
            throw HomebrewFailure.commandFailed(1, HomebrewOutput.visibleTail(output))
        }
        let formulae = (root["formulae"] as? [[String: Any]] ?? []).compactMap {
            formula($0, outdated: outdated)
        }
        let casks = (root["casks"] as? [[String: Any]] ?? []).compactMap {
            cask($0, outdated: outdated)
        }
        return formulae + casks
    }

    public static func searchNames(from output: String) -> [String] {
        var seen: Set<String> = []
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let name = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let validated = try? HomebrewValidation.token(name),
                seen.insert(validated).inserted
            else { return nil }
            return validated
        }
    }

    private static func jsonObjects(in output: String) -> [Data] {
        var objects: [Data] = []
        var start: String.Index?
        var depth = 0
        var quoted = false
        var escaped = false
        var index = output.startIndex
        while index < output.endIndex {
            let character = output[index]
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let objectStart = start {
                    objects.append(Data(output[objectStart...index].utf8))
                    start = nil
                }
                if depth < 0 { depth = 0 }
            }
            index = output.index(after: index)
        }
        return objects
    }

    private static func formula(_ item: [String: Any], outdated: Bool) -> HomebrewPackage? {
        guard let rawName = item["name"] as? String,
            let name = try? HomebrewValidation.token(rawName)
        else { return nil }
        let versions = item["versions"] as? [String: Any]
        let fullName = item["full_name"] as? String
        let identifier = fullName.flatMap { try? HomebrewValidation.token($0) } ?? name
        let installed = (item["installed"] as? [[String: Any]] ?? []).compactMap {
            $0["version"] as? String
        }
        let outdatedInstalled = item["installed_versions"] as? [String] ?? []
        return HomebrewPackage(
            kind: .formula, name: identifier,
            displayName: item["full_name"] as? String ?? name,
            description: item["desc"] as? String, homepage: item["homepage"] as? String,
            installedVersions: installed.isEmpty ? outdatedInstalled : installed,
            currentVersion: item["current_version"] as? String ?? versions?["stable"] as? String,
            outdated: outdated)
    }

    private static func cask(_ item: [String: Any], outdated: Bool) -> HomebrewPackage? {
        guard let rawName = (item["token"] as? String) ?? (item["name"] as? String),
            let name = try? HomebrewValidation.token(rawName)
        else { return nil }
        let installed: [String]
        if let value = item["installed"] as? String, !value.isEmpty {
            installed = [value]
        } else {
            installed = item["installed_versions"] as? [String] ?? []
        }
        let names = item["name"] as? [String] ?? []
        return HomebrewPackage(
            kind: .cask, name: name, displayName: names.first ?? name,
            description: item["desc"] as? String, homepage: item["homepage"] as? String,
            installedVersions: installed,
            currentVersion: item["current_version"] as? String ?? item["version"] as? String,
            outdated: outdated)
    }
}
