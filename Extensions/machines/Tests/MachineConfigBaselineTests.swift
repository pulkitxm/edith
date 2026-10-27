import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

@Suite struct MachineConfigBaselineTests {
    private static let groups: Set<String> = ["machines", "finder"]
    private static let hostOwned: Set<String> = []

    @Test func everyOriginalKeyOfTheOwnedGroupsKeepsItsTypeAndDefault() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(
                "Packages/EdithHost/Tests/EdithHostCoreTests/Fixtures/config-baseline-v0.0.350.json")
        let rows = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [[String: Any]])
        let owned = rows.filter {
            Self.groups.contains($0["group"] as? String ?? "")
                && !Self.hostOwned.contains($0["key"] as? String ?? "")
        }
        #expect(owned.count > 0)
        var problems: [String] = []
        for row in owned {
            let key = row["key"] as? String ?? ""
            guard let setting = ConfigCatalog.definition(for: key) else {
                problems.append("missing \(key)")
                continue
            }
            let expectedDefault = row["default"] is NSNull ? nil : row["default"]
            let actual = try? JSONSerialization.jsonObject(
                with: Data(JSONSerializer.string(setting.fallback).utf8), options: .fragmentsAllowed)
            let sameDefault =
                (actual == nil || actual is NSNull) && expectedDefault == nil
                || ((actual as? NSObject)?.isEqual(expectedDefault) ?? false)
            let range = (row["minimum"] as? Int).flatMap { low in
                (row["maximum"] as? Int).map { low...$0 }
            }
            let matches =
                setting.type.rawValue == row["type"] as? String
                && setting.scope.rawValue == row["scope"] as? String
                && setting.group == row["group"] as? String
                && setting.allowed == (row["allowed"] as? [String] ?? [])
                && setting.integerRange == range && sameDefault
            if !matches { problems.append("different \(key)") }
        }
        #expect(problems.isEmpty, "\(problems)")
    }
}
