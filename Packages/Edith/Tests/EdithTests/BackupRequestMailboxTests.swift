import Testing

@testable import EdithKit

@Suite struct BackupRequestMailboxTests {
    @Test func aBurstRetainsEveryKindWithOnePendingWakeup() async {
        let mailbox = BackupRequestMailbox()
        for _ in 0..<10_000 {
            mailbox.send(.settings)
            mailbox.send(.usage)
            mailbox.send(.limits)
            mailbox.send(.clipboard)
            for kind in SettingsBackupDataClass.allCases { mailbox.send(.restore(kind)) }
        }
        let requests = mailbox.take()
        #expect(requests.settings && requests.usage && requests.limits && requests.clipboard)
        #expect(requests.restores == Set(SettingsBackupDataClass.allCases))
        #expect(mailbox.take().restores.isEmpty)
        mailbox.close()
        var wakeups = 0
        for await _ in mailbox.stream { wakeups += 1 }
        #expect(wakeups == 1)
    }

    @Test func closingRefusesLateRequests() async {
        let mailbox = BackupRequestMailbox()
        mailbox.close()
        mailbox.send(.settings)
        mailbox.send(.restore(.music))
        #expect(!mailbox.take().settings)
        #expect(mailbox.take().restores.isEmpty)
        var iterator = mailbox.stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}
