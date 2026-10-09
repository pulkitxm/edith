import Foundation

@MainActor final class LidAwakePrivilegedController {
    private let read: @Sendable () async throws -> Bool
    private let apply: @MainActor @Sendable (Bool) async throws -> Void
    private let save: @Sendable (Bool?) throws -> Void
    private var original: Bool?
    private var tail: Task<Void, Never>?

    init(
        original: Bool? = nil, read: @escaping @Sendable () async throws -> Bool,
        apply: @escaping @MainActor @Sendable (Bool) async throws -> Void,
        save: @escaping @Sendable (Bool?) throws -> Void = { _ in }
    ) {
        self.original = original; self.read = read; self.apply = apply; self.save = save
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        try await sequence { [self] in
            try Task.checkCancellation()
            if disabled, original == nil {
                let value = try await read()
                try Task.checkCancellation()
                try save(value)
                original = value
            }
            try await apply(disabled)
            if !disabled { try save(nil); original = nil }
        }
    }

    func restore() async throws {
        try await sequence { [self] in
            guard let original else { return }
            try await apply(original)
            try save(nil)
            self.original = nil
        }
    }

    private func sequence(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let prior = tail
        let task = Task { @MainActor in
            await prior?.value; try await operation()
        }
        tail = Task { _ = try? await task.value }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
