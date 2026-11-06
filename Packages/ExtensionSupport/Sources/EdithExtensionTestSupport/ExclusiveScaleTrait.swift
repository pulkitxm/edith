import Testing

public struct ExclusiveScaleTrait: TestTrait, SuiteTrait, TestScoping {
    public init() {}

    public var isRecursive: Bool { true }

    public func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await RenderCapture.withScale(1) { try await function() }
    }
}

extension Trait where Self == ExclusiveScaleTrait {
    public static var exclusiveScale: Self { Self() }
}
