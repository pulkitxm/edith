import Foundation
import Testing
@testable import VirtualCameraExtension

@Suite @MainActor struct CameraCLICatalogTests {
    @Test func catalogPreservesOriginalRoutesAndOnlyOwningOperations() throws {
        let value = try #require(
            JSONSerialization.jsonObject(with: CameraCLICatalog.data()) as? [String: Any])
        #expect(value["owner"] as? String == "virtualCamera" && value["version"] as? Int == 1)
        let help = try #require(value["parserHelp"] as? [[String: Any]])
        #expect(help.count == 1 && help[0]["serializationVersion"] as? Int == 0)
        let commands = try #require(value["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        #expect(routes.contains(["camera", "scene", "delete"]))
        #expect(routes.contains(["camera", "audio"]))
        #expect(routes.contains(["camera", "record"]))
        #expect(routes.contains(["camera", "on"]))
        #expect(Set(routes.map { $0.joined(separator: " ") }).count == commands.count)
        #expect(
            commands.allSatisfy {
                ($0["operation"] as? String)?.hasSuffix(".cli") == true
                    && $0["summary"] as? String != ""
            })
    }
}
