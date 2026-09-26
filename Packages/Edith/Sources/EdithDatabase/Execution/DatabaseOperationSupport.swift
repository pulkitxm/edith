import Foundation

enum DatabaseOperationSupport {
    static func check(
        _ context: DatabaseAdapterOperationContext,
        deadlineExceeded: DatabaseAdapterFailure,
        deadline: Date? = nil
    ) async throws(DatabaseAdapterFailure) {
        switch await context.cancellation.reason() {
        case .deadlineExceeded:
            throw deadlineExceeded
        case .userRequested, .sessionDisconnected:
            throw .cancelled
        case nil:
            break
        }
        if Task.isCancelled {
            throw .cancelled
        }
        let effectiveDeadline = [context.deadline, deadline].compactMap { $0 }.min()
        guard let effectiveDeadline else { return }
        guard effectiveDeadline.timeIntervalSinceReferenceDate.isFinite, effectiveDeadline > Date()
        else {
            throw deadlineExceeded
        }
    }

    static func deadlineTask(
        context: DatabaseAdapterOperationContext
    ) -> Task<Void, Never>? {
        context.deadline.map { deadline in
            Task {
                let delay = max(0, deadline.timeIntervalSinceNow)
                let nanoseconds = UInt64(min(delay * 1_000_000_000, Double(UInt64.max)))
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await context.cancellation.cancel(.deadlineExceeded)
            }
        }
    }

    static func remainingMilliseconds(
        configured: UInt64,
        deadline: Date?,
        deadlineExceeded: DatabaseAdapterFailure
    ) throws(DatabaseAdapterFailure) -> UInt64 {
        guard let deadline else { return configured }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining.isFinite, remaining > 0 else { throw deadlineExceeded }
        return min(configured, UInt64(max(1, floor(remaining * 1_000))))
    }

    static func validHost(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.whitespacesAndNewlines.contains($0)
            })
    }

    static func validCredential(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }
            )
    }

    static func numericPrefix(_ value: Substring) -> Int? {
        let digits = value.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    static func httpStatus(_ value: Int) -> Int {
        (100...599).contains(value) ? value : 500
    }

    static func reported(
        category: DatabaseErrorCategory,
        message: String,
        code: String,
        retry: DatabaseRetryAction = .none
    ) -> DatabaseAdapterFailure {
        .reported(
            DatabaseErrorEnvelope(
                category: category,
                message: message,
                productCode: code,
                retry: DatabaseRetryGuidance(action: retry)))
    }
}
