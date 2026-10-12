import Foundation
import Testing
@testable import CleanerExtension

@Suite @MainActor struct CleanerCLICatalogTests {
    @Test func catalogPreservesOriginalRoutesAndOnlyOwningOperations() throws {
        let value = try #require(
            JSONSerialization.jsonObject(with: CleanerCLICatalog.data()) as? [String: Any])
        #expect(value["owner"] as? String == "cleaner" && value["version"] as? Int == 1)
        let help = try #require(value["parserHelp"] as? [[String: Any]])
        #expect(help.count == 1 && help[0]["serializationVersion"] as? Int == 0)
        let commands = try #require(value["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        #expect(routes.contains(["cleaner", "categories"]))
        #expect(routes.contains(["cleaner", "clean"]))
        #expect(routes.contains(["cleaner", "drives"]))
        #expect(Set(routes.map { $0.joined(separator: " ") }).count == commands.count)
        #expect(
            commands.allSatisfy {
                ($0["operation"] as? String)?.hasSuffix(".cli") == true
                    && $0["summary"] as? String != ""
            })
    }
}
