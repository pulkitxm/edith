import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostConfigurationBaselineTests {
    private struct Row: Decodable {
        let key: String
        let type: String
        let group: String
        let scope: String
        let allowed: [String]
        let minimum: Int64?
        let maximum: Int64?
        let `default`: HostCLIJSON?
    }

    private static let providerGroups: Set<String> = [
        "alerts", "budget", "dashboard", "limits", "menubar", "usage", "machines", "finder",
    ]
    private static let hostOwnedInProviderGroups: Set<String> = [
        "menuBarStatsColorHex", "menuBarStatsColorMode", "menuBarSystemStats", "tabUsageEnabled",
    ]

    private static func baseline() throws -> [Row] {
        let url = try #require(
            Bundle.module.url(
                forResource: "config-baseline-v0.0.350", withExtension: "json",
                subdirectory: "Fixtures"))
        return try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
    }

    private static func normalized(_ value: HostCLIJSON?) -> HostCLIJSON? {
        switch value {
        case .integer(let number): .number(Double(number))
        case .some(.null): nil
        default: value
        }
    }

    @Test func theBaselineFixtureIsTheCompleteOriginalCatalog() throws {
        let rows = try Self.baseline()
        #expect(rows.count == 349)
        #expect(Set(rows.map(\.key)).count == rows.count)
    }

    @Test func everyOriginalKeyExistsWithTheSameTypeDefaultAndConstraints() throws {
        let current = Dictionary(
            uniqueKeysWithValues: HostConfigurationCLI.applicationSettings.map { ($0.key, $0) })
        var missing: [String] = []
        var different: [String] = []
        for row in try Self.baseline() {
            guard let setting = current[row.key] else {
                if !Self.providerGroups.contains(row.group) { missing.append(row.key) }
                continue
            }
            let fallback = setting.fallback == .null ? nil : Optional(setting.fallback)
            let matches =
                setting.type.rawValue == row.type && setting.group == row.group
                && setting.scope == row.scope && setting.allowed == row.allowed
                && setting.minimum == row.minimum && setting.maximum == row.maximum
                && Self.normalized(fallback) == Self.normalized(row.default)
            if !matches { different.append(row.key) }
        }
        #expect(missing.isEmpty, "missing \(missing)")
        #expect(different.isEmpty, "different \(different)")
    }

    @Test func providerOwnedOriginalGroupsAreNotDuplicatedByTheHost() throws {
        let hostKeys = Set(HostConfigurationCLI.applicationSettings.map(\.key))
        let inGroups = try Self.baseline().filter { Self.providerGroups.contains($0.group) }
            .map(\.key)
        #expect(Set(inGroups).intersection(hostKeys) == Self.hostOwnedInProviderGroups)
    }

    @Test func everyExtensionOwnerIsARealExtension() throws {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/manifest.json")
        let entries = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]])
        let known = Set(entries.compactMap { $0["id"] as? String })
        let owners = Set(HostConfigurationCLI.applicationSettings.compactMap(\.owner))
        #expect(
            !owners.isEmpty && owners.subtracting(known).isEmpty, "\(owners.subtracting(known))")
    }
}
