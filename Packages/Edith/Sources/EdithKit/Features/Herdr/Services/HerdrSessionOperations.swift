import EdithCore

public enum HerdrSessionOperation: String, CaseIterable, Equatable, Sendable {
    case list

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "herdr.sessions.list"),
            summary: "List live Herdr sessions on this Mac and configured machines.",
            cli: ["herdr", "ls"], effect: .read)
    }
}

public enum HerdrSessionOperationExecution {
    public typealias Collect = @Sendable (HerdrCollectScope) async -> [HerdrHostSnapshot]

    public static func list(
        _ scope: HerdrCollectScope = .all,
        collect: Collect = { await HerdrCollector.collect($0) }
    ) async -> [HerdrHostSnapshot] {
        await collect(scope)
    }
}
