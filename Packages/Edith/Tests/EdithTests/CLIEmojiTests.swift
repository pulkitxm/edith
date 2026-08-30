import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIEmojiTests {
    @Test func insertionWaitsForTheHelperAcknowledgement() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Emoji.enabled)
            world.helperRunning(true)
            world.answers { name in
                guard name == IPC.Name.emojiInsertResult,
                    let requestID = world.postedPayloads(for: IPC.Name.requestEmojiInsert)
                        .last?[EmojiInsertIPC.requestIDKey] as? String
                else { return nil }
                return EmojiInsertIPC.resultPayload(requestID: requestID, inserted: true)
            }

            let result = await CLIProbe.capture(["emoji", "insert", "1F600", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["emoji"] as? String == "😀")
            #expect(result.object?["operation"] as? String == "emoji.insert")
            #expect(world.postedNames() == [IPC.Name.requestEmojiInsert.rawValue])
            #expect(
                world.postedPayloads(for: IPC.Name.requestEmojiInsert)
                    .first?[EmojiInsertIPC.requestIDKey] as? String != nil)
        }
    }

    @Test func rejectedInsertionReportsAccessibilityAndPrintsNoJSON() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Emoji.enabled)
            world.helperRunning(true)
            world.answers { name in
                guard name == IPC.Name.emojiInsertResult,
                    let requestID = world.postedPayloads(for: IPC.Name.requestEmojiInsert)
                        .last?[EmojiInsertIPC.requestIDKey] as? String
                else { return nil }
                return EmojiInsertIPC.resultPayload(requestID: requestID, inserted: false)
            }

            let result = await CLIProbe.capture(["emoji", "insert", "rocket", "--json"])

            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("Accessibility"))
        }
    }

    @Test func payloadsKeepConcurrentInsertionRepliesCorrelated() {
        let request = EmojiInsertIPC.requestPayload(requestID: "one", character: "🚀")
        let result = EmojiInsertIPC.resultPayload(requestID: "two", inserted: true)
        #expect(request[EmojiInsertIPC.requestIDKey] as? String == "one")
        #expect(request[EmojiInsertIPC.characterKey] as? String == "🚀")
        #expect(result[EmojiInsertIPC.requestIDKey] as? String == "two")
        #expect(result[EmojiInsertIPC.insertedKey] as? Bool == true)
    }
}
