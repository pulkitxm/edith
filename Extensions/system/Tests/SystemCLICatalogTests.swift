import Foundation
import Testing
@testable import SystemExtension

@Suite @MainActor struct SystemCLICatalogTests {
    @Test func catalogPreservesOriginalRoutesAndOnlyOwningOperations() throws {
        let value = try #require(
            JSONSerialization.jsonObject(with: SystemCLICatalog.data()) as? [String: Any])
        #expect(value["owner"] as? String == "system" && value["version"] as? Int == 1)
        let help = try #require(value["parserHelp"] as? [[String: Any]])
        #expect(help.count == 1 && help[0]["serializationVersion"] as? Int == 0)
        let commands = try #require(value["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        #expect(routes.contains(["apps", "ls"]))
        #expect(routes.contains(["apps", "quit"]))
        #expect(Set(routes.map { $0.joined(separator: " ") }).count == commands.count)
        #expect(
            commands.allSatisfy {
                ($0["operation"] as? String)?.hasSuffix(".cli") == true
                    && $0["summary"] as? String != ""
            })
    }
}
