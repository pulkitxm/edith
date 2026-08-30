import Foundation

public enum HomebrewPackageKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case formula
    case cask

    public var id: String { rawValue }
    public var title: String { self == .formula ? "Formula" : "Cask" }
    public var pluralTitle: String { self == .formula ? "Formulae" : "Casks" }
}

public struct HomebrewPackage: Codable, Equatable, Identifiable, Sendable {
    public let kind: HomebrewPackageKind
    public let name: String
    public let displayName: String
    public let description: String?
    public let homepage: String?
    public let installedVersions: [String]
    public let currentVersion: String?
    public let outdated: Bool

    public init(
        kind: HomebrewPackageKind, name: String, displayName: String,
        description: String? = nil, homepage: String? = nil,
        installedVersions: [String] = [], currentVersion: String? = nil,
        outdated: Bool = false
    ) {
        self.kind = kind
        self.name = name
        self.displayName = displayName
        self.description = description
        self.homepage = homepage
        self.installedVersions = installedVersions
        self.currentVersion = currentVersion
        self.outdated = outdated
    }

    public var id: String { "\(kind.rawValue):\(name)" }
    public var installed: Bool { !installedVersions.isEmpty }
    public var installedVersion: String? { installedVersions.last }
    public var versionSummary: String {
        guard let installedVersion else { return currentVersion ?? "Available" }
        guard outdated, let currentVersion else { return installedVersion }
        return "\(installedVersion) to \(currentVersion)"
    }

    public func merging(update: HomebrewPackage) -> HomebrewPackage {
        HomebrewPackage(
            kind: kind, name: name, displayName: displayName,
            description: description, homepage: homepage,
            installedVersions: installedVersions,
            currentVersion: update.currentVersion ?? currentVersion, outdated: update.outdated)
    }
}

public struct HomebrewStatus: Equatable, Sendable {
    public let available: Bool
    public let executable: String?
    public let version: String?

    public init(available: Bool, executable: String?, version: String?) {
        self.available = available
        self.executable = executable
        self.version = version
    }
}

public enum HomebrewMutation: String, CaseIterable, Codable, Sendable {
    case install
    case upgrade
    case uninstall
}

public struct HomebrewMutationResult: Equatable, Sendable {
    public let action: HomebrewMutation
    public let kind: HomebrewPackageKind
    public let name: String
    public let output: String

    public init(
        action: HomebrewMutation, kind: HomebrewPackageKind, name: String, output: String
    ) {
        self.action = action
        self.kind = kind
        self.name = name
        self.output = output
    }
}

public enum HomebrewFailure: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case invalidQuery
    case invalidToken(String)
    case commandFailed(Int32, String)
    case timedOut
    case outputLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Homebrew is not installed. Install it from brew.sh, then check again."
        case .invalidQuery:
            "Search text must be between 1 and 120 characters and cannot begin with a dash."
        case let .invalidToken(token):
            "\(token) is not a valid Homebrew package name."
        case let .commandFailed(status, detail):
            detail.isEmpty ? "Homebrew exited with status \(status)." : detail
        case .timedOut:
            "Homebrew did not finish within the allowed time."
        case .outputLimitExceeded:
            "Homebrew produced more output than Edith can safely retain."
        }
    }
}
