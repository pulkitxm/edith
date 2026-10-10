import Foundation
import Testing
@testable import EdithHostCore

@Suite struct HostCLIRequestTests {
    @Test func helpAndVersionNeverNeedAnApp() throws {
        #expect(try HostCLICommand.parse([]) == .help)
        #expect(try HostCLICommand.parse(["extensions", "--help"]) == .help)
        #expect(try HostCLICommand.parse(["--version"]) == .version)
    }
    @Test func marketplaceCommandsAreStrictAndTyped() throws {
        for action in ["info", "install", "update", "enable", "disable", "remove"] {
            guard
                case .request(let request) = try HostCLICommand.parse([
                    "extensions", action, "sample", "--json",
                ])
            else {
                Issue.record("The marketplace action was not parsed"); return
            }
            #expect(request.action.rawValue == action)
            #expect(request.id == "sample")
        }
        #expect(throws: HostCLIError.self) {
            try HostCLICommand.parse(["extensions", "catalog", "--json"])
        }
        #expect(throws: HostCLIError.self) {
            try HostCLICommand.parse(["extensions", "remove", "sample", "extra"])
        }
        #expect(throws: HostCLIError.self) { try HostCLICommand.parse(["machines", "ls"]) }
    }
    @Test func invokeReadsBoundedJSONAndRejectsPrivateOperations() throws {
        guard
            case .request(let request) = try HostCLICommand.parse(
                ["invoke", "database", "database.execute", "--json", "-", "--timeout", "12"],
                readInput: { Data("{\"synthetic\":true}".utf8) })
        else {
            Issue.record("The worker invocation was not parsed"); return
        }
        #expect(request.timeout == 12)
        #expect(request.payload == Data("{\"synthetic\":true}".utf8))
        for args in [
            ["invoke", "sample", "extension.native.authorize"],
            ["invoke", "../sample", "echo"], ["invoke", "sample", "echo", "--timeout", "61"],
            ["invoke", "sample", "echo", "--json", "invalid"],
            ["invoke", "sample", "echo", "--json", "{}", "--json", "{}"],
        ] { #expect(throws: HostCLIError.self) { try HostCLICommand.parse(args) } }
        #expect(throws: HostCLIError.self) {
            try HostCLICommand.parse(
                ["invoke", "sample", "echo", "--json", "-"],
                readInput: { Data(repeating: 32, count: HostCLIRequest.maximumPayload + 1) })
        }
    }
    @Test func decodedRequestsCannotBypassValidation() throws {
        let request = try HostCLIRequest(action: .ls)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object["timeout"] = 999
        let decoded = try JSONDecoder().decode(
            HostCLIRequest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: HostCLIError.self) { try decoded.validate() }
    }
}
