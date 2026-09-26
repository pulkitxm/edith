import Foundation
import Testing

@testable import EdithDatabase

@Suite struct DatabaseOperationSupportTests {
    private static let deadlineExceeded = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .timeout,
            message: "deadline",
            productCode: "test.deadline"))

    private static func context(
        deadline: Date? = nil,
        cancellation: DatabaseAdapterCancellationSignal = DatabaseAdapterCancellationSignal()
    ) -> DatabaseAdapterOperationContext {
        DatabaseAdapterOperationContext(
            operation: DatabaseOperationContext(deadline: deadline),
            cancellation: cancellation)
    }

    @Test func checkAllowsAnOpenOperation() async throws {
        try await DatabaseOperationSupport.check(
            Self.context(), deadlineExceeded: Self.deadlineExceeded)
    }

    @Test func checkRejectsADeadlineThatHasAlreadyPassed() async {
        let past = Date().addingTimeInterval(-5)
        await #expect(throws: Self.deadlineExceeded) {
            try await DatabaseOperationSupport.check(
                Self.context(deadline: past), deadlineExceeded: Self.deadlineExceeded)
        }
    }

    @Test func checkAllowsADeadlineThatIsStillAhead() async throws {
        let future = Date().addingTimeInterval(60)
        try await DatabaseOperationSupport.check(
            Self.context(deadline: future), deadlineExceeded: Self.deadlineExceeded)
    }

    @Test func checkUsesTheEarlierOfTwoDeadlines() async {
        let soon = Date().addingTimeInterval(-1)
        let later = Date().addingTimeInterval(60)
        await #expect(throws: Self.deadlineExceeded) {
            try await DatabaseOperationSupport.check(
                Self.context(deadline: later),
                deadlineExceeded: Self.deadlineExceeded,
                deadline: soon)
        }
    }

    @Test func checkTurnsAUserCancellationIntoACancelledFailure() async {
        let signal = DatabaseAdapterCancellationSignal()
        await signal.cancel(.userRequested)
        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await DatabaseOperationSupport.check(
                Self.context(cancellation: signal), deadlineExceeded: Self.deadlineExceeded)
        }
    }

    @Test func checkTurnsADisconnectIntoACancelledFailure() async {
        let signal = DatabaseAdapterCancellationSignal()
        await signal.cancel(.sessionDisconnected)
        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            try await DatabaseOperationSupport.check(
                Self.context(cancellation: signal), deadlineExceeded: Self.deadlineExceeded)
        }
    }

    @Test func remainingMillisecondsKeepsTheConfiguredBudgetWithoutADeadline() throws {
        let budget = try DatabaseOperationSupport.remainingMilliseconds(
            configured: 2_000, deadline: nil, deadlineExceeded: Self.deadlineExceeded)
        #expect(budget == 2_000)
    }

    @Test func remainingMillisecondsShrinksToTheTimeLeft() throws {
        let budget = try DatabaseOperationSupport.remainingMilliseconds(
            configured: 30_000,
            deadline: Date().addingTimeInterval(1.5),
            deadlineExceeded: Self.deadlineExceeded)
        #expect((1_000...1_500).contains(budget))
    }

    @Test func remainingMillisecondsKeepsAtLeastOneMillisecond() throws {
        let budget = try DatabaseOperationSupport.remainingMilliseconds(
            configured: 30_000,
            deadline: Date().addingTimeInterval(0.0001),
            deadlineExceeded: Self.deadlineExceeded)
        #expect(budget == 1)
    }

    @Test func remainingMillisecondsRejectsAnExpiredDeadline() {
        #expect(throws: Self.deadlineExceeded) {
            try DatabaseOperationSupport.remainingMilliseconds(
                configured: 2_000,
                deadline: Date().addingTimeInterval(-1),
                deadlineExceeded: Self.deadlineExceeded)
        }
    }

    @Test func validHostAcceptsAPlainNameAndRejectsControls() {
        #expect(DatabaseOperationSupport.validHost("db.example"))
        #expect(!DatabaseOperationSupport.validHost(""))
        #expect(!DatabaseOperationSupport.validHost("db example"))
        #expect(!DatabaseOperationSupport.validHost("db\nexample"))
        #expect(!DatabaseOperationSupport.validHost("db\u{0}example"))
        #expect(!DatabaseOperationSupport.validHost(String(repeating: "a", count: 1_025)))
    }

    @Test func validCredentialBoundsLengthAndRejectsControls() {
        #expect(DatabaseOperationSupport.validCredential("secret", maximumBytes: 16))
        #expect(!DatabaseOperationSupport.validCredential("", maximumBytes: 16))
        #expect(!DatabaseOperationSupport.validCredential("secret\n", maximumBytes: 16))
        #expect(
            !DatabaseOperationSupport.validCredential(
                String(repeating: "a", count: 17), maximumBytes: 16))
    }

    @Test func numericPrefixReadsLeadingDigits() {
        #expect(DatabaseOperationSupport.numericPrefix("15.2.1") == 15)
        #expect(DatabaseOperationSupport.numericPrefix("v2") == nil)
        #expect(DatabaseOperationSupport.numericPrefix("") == nil)
        #expect(DatabaseOperationSupport.numericPrefix("007") == 7)
    }

    @Test func httpStatusKeepsClientAndServerCodes() {
        #expect(DatabaseOperationSupport.httpStatus(200) == 200)
        #expect(DatabaseOperationSupport.httpStatus(404) == 404)
        #expect(DatabaseOperationSupport.httpStatus(599) == 599)
        #expect(DatabaseOperationSupport.httpStatus(99) == 500)
        #expect(DatabaseOperationSupport.httpStatus(600) == 500)
    }

    @Test func reportedBuildsAnEnvelope() {
        let failure = DatabaseOperationSupport.reported(
            category: .timeout,
            message: "too slow",
            code: "test.slow",
            retry: .retry)
        guard case .reported(let envelope) = failure else {
            Issue.record("expected a reported failure")
            return
        }
        #expect(envelope.category == .timeout)
        #expect(envelope.message == "too slow")
        #expect(envelope.productCode == "test.slow")
        #expect(envelope.retry.action == .retry)
    }

    @Test func deadlineTaskCancelsWhenTheDeadlinePasses() async {
        let signal = DatabaseAdapterCancellationSignal()
        let context = Self.context(deadline: Date().addingTimeInterval(0.05), cancellation: signal)
        let task = DatabaseOperationSupport.deadlineTask(context: context)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let reason = await signal.reason()
        task?.cancel()
        #expect(reason == .deadlineExceeded)
    }
}
