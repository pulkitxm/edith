import Foundation
import Testing
@testable import JevExtension

@Suite @MainActor struct JevCLICatalogTests {
    @Test func catalogPreservesOriginalRoutesAndOnlyOwningOperations() throws {
        let value = try #require(
            JSONSerialization.jsonObject(with: JevCLICatalog.data()) as? [String: Any])
        #expect(value["owner"] as? String == "jev" && value["version"] as? Int == 1)
        let help = try #require(value["parserHelp"] as? [[String: Any]])
        #expect(help.count == 1 && help[0]["serializationVersion"] as? Int == 0)
        let commands = try #require(value["commands"] as? [[String: Any]])
        #expect(
            commands.filter { $0["readsInput"] as? Bool == true }.compactMap {
                $0["route"] as? [String]
            } == [["jev", "key", "set"], ["jev", "ask"]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        #expect(routes.contains(["jev", "key", "clear"]))
        #expect(routes.contains(["jev", "ask"]))
        #expect(Set(routes.map { $0.joined(separator: " ") }).count == commands.count)
        #expect(
            commands.allSatisfy {
                ($0["operation"] as? String)?.hasSuffix(".cli") == true
                    && $0["summary"] as? String != ""
            })
    }
}
