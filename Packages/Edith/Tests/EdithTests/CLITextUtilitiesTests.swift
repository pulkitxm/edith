import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite(.serialized) struct CLITextUtilitiesTests {
    @Test func statusIsTheSafeDefault() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.TextUtilities.enabled)
            let snippet = TextSnippet(name: "Signature", trigger: ";sig", replacement: "Thanks")
            world.shared.set(
                TextUtilitiesSupport.encode([snippet]),
                forKey: AppStorageKeys.TextUtilities.snippets)
            let explicit = await CLIProbe.capture(["text", "status", "--json"])
            let implicit = await CLIProbe.capture(["text", "--json"])

            #expect(explicit.code == 0)
            #expect(explicit.stdout == implicit.stdout)
            #expect(explicit.object?["enabled"] as? Bool == true)
            #expect(explicit.object?["snippetCount"] as? Int == 1)
        }
    }

    @Test func cleansTrackingParametersWithStableJSON() async {
        await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture([
                "text", "clean-url", "https://example.com/page?keep=1&utm_source=mail&ref=x",
                "--parameters", "ref", "--json",
            ])

            #expect(result.code == 0)
            #expect(result.object?["url"] as? String == "https://example.com/page?keep=1")
            #expect(result.object?["removed"] as? [String] == ["utm_source", "ref"])
            #expect(result.object?["changed"] as? Bool == true)
        }
    }

    @Test func snippetCommandsAddListAndUpdateSharedSettings() async {
        await CLIProbe.inWorld { world in
            let added = await CLIProbe.capture([
                "text", "snippets", "add", ";sig", "Thanks", "--name", "Signature",
                "--folder", "Work", "--ignore-case", "--json",
            ])
            let listed = await CLIProbe.capture(["text", "snippets", "ls", "--json"])
            let updated = await CLIProbe.capture([
                "text", "snippets", "set", "1", "--replacement", "Thank you",
                "--enabled", "false", "--json",
            ])

            #expect(added.code == 0)
            #expect(added.object?["name"] as? String == "Signature")
            #expect((listed.array?.first as? [String: Any])?["trigger"] as? String == ";sig")
            #expect(updated.object?["replacement"] as? String == "Thank you")
            #expect(updated.object?["enabled"] as? Bool == false)
            let saved = TextUtilitiesSupport.decode(
                world.shared.string(forKey: AppStorageKeys.TextUtilities.snippets))
            #expect(saved.count == 1)
            #expect(saved.first?.replacement == "Thank you")
            #expect(
                world.postedNames().filter { $0 == IPC.Name.settingsChanged.rawValue }.count == 2)
        }
    }

    @Test func snippetRemovalPreviewsBeforeApplying() async {
        await CLIProbe.inWorld { world in
            let snippet = TextSnippet(name: "Signature", trigger: ";sig", replacement: "Thanks")
            world.shared.set(
                TextUtilitiesSupport.encode([snippet]),
                forKey: AppStorageKeys.TextUtilities.snippets)

            let preview = await CLIProbe.capture(["text", "snippets", "rm", "1", "--json"])
            #expect(preview.object?["applied"] as? Bool == false)
            #expect(TextCLI.snippets.count == 1)

            let applied = await CLIProbe.capture([
                "text", "snippets", "rm", "1", "--yes", "--json",
            ])
            #expect(applied.code == 0)
            #expect(applied.object?["applied"] as? Bool == true)
            #expect(applied.object?["changed"] as? Bool == true)
            #expect(TextCLI.snippets.isEmpty)
        }
    }

    @Test func plainPasteRequiresTheExtensionAndDispatchesToTheHelper() async {
        await CLIProbe.inWorld { world in
            let disabled = await CLIProbe.capture(["text", "paste-plain", "--json"])
            #expect(disabled.code == ExitCodes.unavailable)

            world.shared.set(true, forKey: AppStorageKeys.TextUtilities.enabled)
            world.helperRunning(true)
            world.answers { name in
                guard name == IPC.Name.plainTextPasteResult,
                    let requestID = world.postedPayloads(for: IPC.Name.requestPlainTextPaste)
                        .last?[PlainTextPasteIPC.requestIDKey] as? String
                else { return nil }
                return PlainTextPasteIPC.payload(requestID: requestID, state: .pasted)
            }
            let enabled = await CLIProbe.capture(["text", "paste-plain", "--json"])
            #expect(enabled.code == 0)
            #expect(enabled.object?["requested"] as? Bool == true)
            #expect(enabled.object?["state"] as? String == PlainTextPasteState.pasted.rawValue)
            #expect(world.postedNames().contains(IPC.Name.requestPlainTextPaste.rawValue))
        }
    }

    @Test func plainPasteReportsTheHelpersActualOutcome() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.TextUtilities.enabled)
            world.helperRunning(true)
            world.answers { name in
                guard name == IPC.Name.plainTextPasteResult,
                    let requestID = world.postedPayloads(for: IPC.Name.requestPlainTextPaste)
                        .last?[PlainTextPasteIPC.requestIDKey] as? String
                else { return nil }
                return PlainTextPasteIPC.payload(requestID: requestID, state: .clipboardEmpty)
            }

            let result = await CLIProbe.capture(["text", "paste-plain", "--json"])

            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("clipboard does not contain text"))
        }
    }

    @Test func plainPasteDoesNotClaimSuccessWhenTheHelperDoesNotAnswer() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.TextUtilities.enabled)
            world.helperRunning(true)
            world.answers { _ in nil }

            let result = await CLIProbe.capture(["text", "paste-plain", "--json"])

            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("did not answer"))
        }
    }
}
