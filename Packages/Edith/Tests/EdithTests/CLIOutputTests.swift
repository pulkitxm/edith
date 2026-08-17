import Foundation
import Testing

@testable import EdithCLI

@Suite struct CLIOutputTests {
    @Test func jsonObjectKeysAreSortedSoOutputIsStable() {
        let value = JSONValue.object([
            "zeta": .int(1), "alpha": .bool(true), "mid": .string("x"),
        ])
        #expect(
            JSONSerializer.string(value, pretty: false)
                == #"{"alpha":true,"mid":"x","zeta":1}"#)
    }

    @Test func jsonEscapesControlCharactersAndQuotes() {
        let value = JSONValue.string("a\"b\\c\nd\te")
        #expect(JSONSerializer.string(value, pretty: false) == #""a\"b\\c\nd\te""#)
    }

    @Test func wholeDoublesRenderWithoutAFractionalPart() {
        #expect(JSONSerializer.string(.double(42), pretty: false) == "42")
        #expect(JSONSerializer.string(.double(0.5), pretty: false) == "0.5")
    }

    @Test func emptyCollectionsStayOnOneLine() {
        #expect(JSONSerializer.string(.array([])) == "[]")
        #expect(JSONSerializer.string(.object([:])) == "{}")
    }

    @Test func prettyOutputIsOneDocumentWithNestedIndentation() {
        let value = JSONValue.object(["items": .array([.int(1), .int(2)])])
        #expect(
            JSONSerializer.string(value)
                == """
                {
                  "items": [
                    1,
                    2
                  ]
                }
                """)
    }

    @Test func optionalHelpersMapNilToNull() {
        #expect(JSONValue.optional(nil as String?) == .null)
        #expect(JSONValue.optional("x") == .string("x"))
        #expect(JSONValue.date(nil) == .null)
    }

    @Test func tablesPadEveryColumnButTheLast() {
        let table = TextTable.render(
            headers: ["A", "BB"], rows: [["1", "2"], ["longer", "3"]])
        #expect(
            table
                == """
                A       BB
                1       2
                longer  3
                """)
    }

    @Test func failureKindsMapOntoTheDocumentedExitCodes() {
        #expect(CLIFailure("x").kind.rawValue == 1)
        #expect(CLIFailure.notFound("x").kind.rawValue == 3)
        #expect(CLIFailure.unavailable("x").kind.rawValue == 4)
    }

    @Test func oneLineTextKeepsItsLabelAndNothingElse() {
        #expect(CLIOut.labelled("error: ", "nope") == "error: nope")
        #expect(CLIOut.labelled("hint: ", "") == "hint:")
    }

    @Test func continuationLinesLineUpUnderTheLabelWithoutBlanks() {
        #expect(
            CLIOut.labelled("error: ", "first\n\n   second   \n")
                == """
                error: first
                       second
                """)
    }

    @Test func aFailureCarryingRemoteOutputLabelsEveryLineItPrints() async {
        let run = await CLIProbe.isolate {
            throw CLIFailure(
                "Asus TUF 7 did not reboot: sudo: a password is required\n"
                    + "Call to Reboot failed: Interactive authentication required.",
                hint: "give this account passwordless sudo for systemctl on Asus TUF 7")
        }
        #expect(
            run.stderr == """
                error: Asus TUF 7 did not reboot: sudo: a password is required
                       Call to Reboot failed: Interactive authentication required.
                hint: give this account passwordless sudo for systemctl on Asus TUF 7

                """)
        #expect(run.code == 1)
    }
}
