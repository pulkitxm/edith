import Foundation

public struct SSHConfigHost: Identifiable, Equatable, Sendable {
    public let alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?

    public var id: String { alias }

    public init(
        alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil,
        identityFile: String? = nil
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }

    public var displayTarget: String {
        let host = hostName ?? alias
        let base = user.map { "\($0)@\(host)" } ?? host
        guard let port, port != 22 else { return base }
        return "\(base):\(port)"
    }
}

public enum SSHConfigFile {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path
    }

    public static func concreteHosts(atPath path: String = defaultPath) -> [SSHConfigHost] {
        var visited = Set<String>()
        guard let lines = loadLines(path: path, visited: &visited) else { return [] }
        return concreteHosts(configLines: lines)
    }

    public static func concreteHosts(configLines lines: [ConfigLine]) -> [SSHConfigHost] {
        var order: [String] = []
        var hosts: [String: SSHConfigHost] = [:]
        var activePatterns: [String] = []
        var inMatchBlock = false
        for line in lines {
            switch line.keyword.lowercased() {
            case "host":
                inMatchBlock = false
                activePatterns = line.arguments
                for pattern in line.arguments where isConcreteAlias(pattern) {
                    if hosts[pattern] == nil {
                        hosts[pattern] = SSHConfigHost(alias: pattern)
                        order.append(pattern)
                    }
                }
            case "match":
                inMatchBlock = true
            default:
                guard !inMatchBlock, let value = line.arguments.first else { continue }
                for pattern in activePatterns where isConcreteAlias(pattern) {
                    guard var host = hosts[pattern] else { continue }
                    switch line.keyword.lowercased() {
                    case "hostname": if host.hostName == nil { host.hostName = value }
                    case "user": if host.user == nil { host.user = value }
                    case "port": if host.port == nil { host.port = Int(value) }
                    case "identityfile":
                        if host.identityFile == nil { host.identityFile = expandTilde(value) }
                    default: break
                    }
                    hosts[pattern] = host
                }
            }
        }
        return order.compactMap { hosts[$0] }
    }

    public struct ConfigLine: Equatable, Sendable {
        public let keyword: String
        public let arguments: [String]

        public init(keyword: String, arguments: [String]) {
            self.keyword = keyword
            self.arguments = arguments
        }
    }

    public static func parseLines(_ content: String) -> [ConfigLine] {
        content.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            var tokens = tokenize(String(rawLine))
            guard !tokens.isEmpty else { return nil }
            var keyword = tokens.removeFirst()
            if let equals = keyword.firstIndex(of: "=") {
                let value = String(keyword[keyword.index(after: equals)...])
                keyword = String(keyword[..<equals])
                if !value.isEmpty { tokens.insert(value, at: 0) }
            } else if tokens.first == "=" {
                tokens.removeFirst()
            }
            guard !keyword.isEmpty, !tokens.isEmpty else { return nil }
            return ConfigLine(keyword: keyword, arguments: tokens)
        }
    }

    public static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst()
    }

    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character == "#", !inQuotes {
                break
            }
            if character.isWhitespace, !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func isConcreteAlias(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.contains("*") && !pattern.contains("?")
            && !pattern.hasPrefix("!")
    }

    private static func loadLines(path: String, visited: inout Set<String>) -> [ConfigLine]? {
        let standardized = URL(fileURLWithPath: expandTilde(path)).standardizedFileURL.path
        guard visited.insert(standardized).inserted,
            let content = try? String(contentsOfFile: standardized, encoding: .utf8)
        else { return nil }
        var lines: [ConfigLine] = []
        for line in parseLines(content) {
            if line.keyword.lowercased() == "include" {
                for pattern in line.arguments {
                    for includePath in resolveIncludePaths(pattern) {
                        if let included = loadLines(path: includePath, visited: &visited) {
                            lines.append(contentsOf: included)
                        }
                    }
                }
            } else {
                lines.append(line)
            }
        }
        return lines
    }

    private static func resolveIncludePaths(_ pattern: String) -> [String] {
        let sshDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        let expanded = expandTilde(pattern)
        let base = expanded.hasPrefix("/") ? expanded : sshDir.appendingPathComponent(expanded).path
        guard base.contains("*") else { return [base] }
        let directory = (base as NSString).deletingLastPathComponent
        let filePattern = (base as NSString).lastPathComponent
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory)
        else { return [] }
        return names.filter { fnmatch(filePattern, $0, 0) == 0 }
            .sorted()
            .map { directory + "/" + $0 }
    }
}
