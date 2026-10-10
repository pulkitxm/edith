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
            ["invoke", "../sample", "echo"], ["invoke", "sample", "echo", "--timeout", "121"],
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
            JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        object["timeout"] = 999
        #expect(throws: HostCLIError.self) {
            try HostCLIRequest.decoded(JSONSerialization.data(withJSONObject: object))
        }
    }
    @Test func rawOutputDecodesOnlyJSONStringResponses() throws {
        for value in ["", "synthetic ☀️", "first\nsecond\n"] {
            let encoded = try JSONSerialization.data(
                withJSONObject: value, options: .fragmentsAllowed)
            #expect(try HostCLI.output(encoded, raw: true) == Data(value.utf8))
            #expect(try HostCLI.output(encoded, raw: false) == encoded)
        }
        for value in ["{}", "[]", "null", "true", "123"] {
            #expect(throws: HostCLIError.self) { try HostCLI.output(Data(value.utf8), raw: true) }
        }
        guard
            case .request(let request) = try HostCLICommand.parse([
                "invoke", "usage", "usage.statusline.hook", "--raw", "--timeout", "120",
            ])
        else {
            Issue.record("The raw hook was not parsed"); return
        }
        #expect(request.raw)
        #expect(request.timeout == 120)
        #expect(throws: HostCLIError.self) {
            try HostCLICommand.parse(["invoke", "usage", "echo", "--raw", "--raw"])
        }
    }

}
