import Foundation
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct QuinjetOwnershipTests {
    @Test func shutdownCancelsAndDrainsOwnedWorkAndRejectsNewWork() async {
        QuinjetWorkOwnership.enable()
        var began = false
        var ended = false
        _ = QuinjetWorkOwnership.start {
            began = true
            defer { ended = true }
            try? await Task.sleep(for: .seconds(60))
        }
        while !began { await Task.yield() }
        await QuinjetWorkOwnership.shutdown()
        #expect(ended && QuinjetWorkOwnership.pendingCount == 0)
        let rejected = QuinjetWorkOwnership.start { Issue.record("Work admitted after shutdown") }
        await rejected.value
        QuinjetWorkOwnership.enable()
    }

    @Test func managedOscRequiresCompleteBoundedKnownActions() {
        var parser = QuinjetManagedOSC()
        #expect(parser.append(Data("text\u{1B}]6973;quinjet;open-".utf8)).isEmpty)
        #expect(parser.append(Data("new-tab\u{1B}".utf8)).isEmpty)
        #expect(parser.append(Data("\\".utf8)) == ["quinjet;open-new-tab"])
        #expect(parser.append(Data("\u{1B}]6973;arbitrary-command\u{7}".utf8)).isEmpty)
        #expect(
            parser.append(
                Data(("\u{1B}]6973;" + String(repeating: "x", count: 2048) + "\u{7}").utf8)
            ).isEmpty)
        #expect(
            parser.append(Data("\u{1B}]6973;quinjet;open-worktree\u{7}".utf8)) == [
                "quinjet;open-worktree"
            ])
    }
}
