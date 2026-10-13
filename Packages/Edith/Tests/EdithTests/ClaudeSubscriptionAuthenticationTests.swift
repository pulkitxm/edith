import EdithKit
import Foundation
import Testing

struct ClaudeSubscriptionAuthenticationTests {
    private static let validStatuses = [
        #"{"loggedIn":true,"authMethod":"claude.ai"}"#,
        #"{"authMethod":"claude.ai","loggedIn":true}"#,
        " \n\t{\"loggedIn\": true, \"authMethod\": \"claude.ai\"}\r\n",
        #"{"loggedIn":true,"authMethod":"clau\u0064e.ai"}"#,
        #"{"\u006coggedIn":true,"auth\u004dethod":"claude.ai"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":[null,false,true,{},[],0,-0,1.25,-2e+3,0E-5]}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":{"authMethod":"api_key","loggedIn":false}}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":"quote\" slash\/ backslash\\ \b\f\n\r\t"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":"\u0000\u007f\u0080\uD83D\uDE00"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":"é 日本 😀"}"#,
    ]

    private static let invalidStatuses = [
        "", "null", "true", "[]", "{}",
        #"{"loggedIn":true,"authMethod":"api_key","nested":{"authMethod":"claude.ai"}}"#,
        #"{"loggedIn":false,"authMethod":"claude.ai","nested":{"loggedIn":true}}"#,
        #"{"nested":{"loggedIn":true,"authMethod":"claude.ai"}}"#,
        #"{"loggedIn":true,"authMethod":"oauth_token"}"#,
        #"{"loggedIn":true,"authMethod":"CLAUDE.AI"}"#,
        #"{"loggedIn":"true","authMethod":"claude.ai"}"#,
        #"{"loggedIn":1,"authMethod":"claude.ai"}"#,
        #"{"loggedIn":null,"authMethod":"claude.ai"}"#,
        #"{"loggedIn":[],"authMethod":"claude.ai"}"#,
        #"{"loggedIn":{},"authMethod":"claude.ai"}"#,
        #"{"loggedIn":true,"authMethod":true}"#,
        #"{"loggedIn":true,"authMethod":["claude.ai"]}"#,
        #"{"loggedIn":true,"authMethod":{"value":"claude.ai"}}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","loggedIn":true}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","authMethod":"claude.ai"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","\u006coggedIn":true}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","auth\u004dethod":"claude.ai"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai",}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":[1,]}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai"}{}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai"} trailing"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":01}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":+1}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":.1}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":1.}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":1e}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":1e+}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":NaN}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":Infinity}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":"\x41"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":"\u123"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":"\uZZZZ"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":"\uD800"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":"\uDC00"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":"\uD800\u0041"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","extra":tru}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai""#,
        #"{"loggedIn":true,"authMethod":"claude.ai"}"# + "\nsubscription_exit:0\n",
    ]

    @Test(arguments: validStatuses)
    func acceptsRootSubscriptionWithCompleteJSON(status: String) throws {
        let result = try run(
            ClaudeSubscriptionAuthentication.posixStatus("cat"), input: Data(status.utf8))
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test(arguments: invalidStatuses)
    func rejectsMalformedOrNonSubscriptionJSON(status: String) throws {
        let result = try run(
            ClaudeSubscriptionAuthentication.posixStatus("cat"), input: Data(status.utf8))
        #expect(result.status != 0)
        #expect(result.output.isEmpty)
    }

    @Test(arguments: [1, 2, 126, 127, 255])
    func rejectsUnsuccessfulStatusEvenWithValidJSON(exit: Int) throws {
        let result = try run(
            ClaudeSubscriptionAuthentication.posixStatus("(cat; exit \(exit))"),
            input: Data(Self.validStatuses[0].utf8))
        #expect(result.status != 0)
    }

    @Test
    func rejectsRawNULControlAndInvalidUTF8Bytes() throws {
        let prefix = Data(#"{"loggedIn":true,"authMethod":"claude.ai","extra":""#.utf8)
        let suffix = Data(#""}"#.utf8)
        let invalidBytes: [[UInt8]] = [
            [0], [1], [10], [31], [128], [192, 175], [193, 191], [224, 159, 128],
            [237, 160, 128], [240, 143, 128, 128], [244, 144, 128, 128],
            [245, 128, 128, 128], [226, 130], [226, 65, 172],
        ]
        for bytes in invalidBytes {
            let result = try run(
                ClaudeSubscriptionAuthentication.posixStatus("cat"),
                input: prefix + Data(bytes) + suffix)
            #expect(result.status != 0)
        }
        let trailingNUL = try run(
            ClaudeSubscriptionAuthentication.posixStatus("cat"),
            input: Data(Self.validStatuses[0].utf8) + Data([0]))
        #expect(trailingNUL.status != 0)
    }

    @Test
    func enforcesExactByteAndNestingBounds() throws {
        let base = Self.validStatuses[0]
        let limit = 16_384
        let exact = base + String(repeating: " ", count: limit - base.utf8.count)
        let accepted = try run(
            ClaudeSubscriptionAuthentication.posixStatus("cat"), input: Data(exact.utf8))
        #expect(accepted.status == 0)
        let rejected = try run(
            ClaudeSubscriptionAuthentication.posixStatus("cat"), input: Data((exact + " ").utf8))
        #expect(rejected.status != 0)
        let prefix = #"{"loggedIn":true,"authMethod":"claude.ai","extra":"#
        for (depth, allowed) in [(62, true), (63, false)] {
            let status =
                prefix + String(repeating: "[", count: depth) + "0"
                + String(repeating: "]", count: depth) + "}"
            let result = try run(
                ClaudeSubscriptionAuthentication.posixStatus("cat"), input: Data(status.utf8))
            #expect((result.status == 0) == allowed)
        }
    }

    @Test
    func loginRetryLaunchesOnlyAfterActualSuccessfulStatus() throws {
        let accepted = Self.validStatuses[0]
        let rejected = Self.invalidStatuses[5]
        for (first, second, code, expected) in [
            (accepted, accepted, 0, "launch\n"),
            (rejected, accepted, 0, "login\nlaunch\n"),
            (rejected, rejected, 0, "login\nrejected\n"),
            (accepted, accepted, 1, "login\nrejected\n"),
        ] {
            let prefix =
                "subscription_calls=0; synthetic_status() { subscription_calls=$((subscription_calls + 1)); "
                + "if [ \"$subscription_calls\" -eq 1 ]; then printf '%s' " + quote(first)
                + "; else printf '%s' " + quote(second) + "; fi; return \(code); }; "
            let command =
                prefix
                + ClaudeSubscriptionAuthentication.posix(
                    status: "synthetic_status",
                    login: "printf 'login\\n'; synthetic_status() { printf '%s' "
                        + quote(second) + "; return \(code); }", launch: "printf 'launch\\n'",
                    failure: "rejected")
            let result = try run(command)
            #expect(result.output == expected)
            #expect((result.status == 0) == expected.hasSuffix("launch\n"))
        }
    }

    @Test
    func powerShellRequiresExactBooleanStringAndSuccessfulNativeExit() {
        let result = ClaudeSubscriptionAuthentication.powerShell(
            status: "synthetic-status", login: "synthetic-login --claudeai",
            launch: "synthetic-launch", failure: "rejected")
        #expect(result.contains("$LASTEXITCODE = $null"))
        #expect(result.contains("$subscriptionStatusExit = $LASTEXITCODE"))
        #expect(result.contains("$subscriptionStatusExit -eq 0"))
        #expect(result.contains("$subscriptionLogin.loggedIn -is [bool]"))
        #expect(result.contains("$subscriptionLogin.loggedIn -eq $true"))
        #expect(result.contains("$subscriptionLogin.authMethod -is [string]"))
        #expect(result.contains("$subscriptionLogin.authMethod -ceq 'claude.ai'"))
        #expect(result.contains("ConvertFrom-Json -ErrorAction Stop"))
        #expect(result.contains("-ccontains 'loggedIn'"))
        #expect(result.contains("-ccontains 'authMethod'"))
        #expect(result.contains("synthetic-login --claudeai"))
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func run(_ command: String, input: Data = Data()) throws -> (
        status: Int32, output: String
    ) {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardOutput
        try process.run()
        do {
            try standardInput.fileHandleForWriting.write(contentsOf: input)
            try standardInput.fileHandleForWriting.close()
        } catch {
            try? standardInput.fileHandleForWriting.close()
            process.waitUntilExit()
            throw error
        }
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
