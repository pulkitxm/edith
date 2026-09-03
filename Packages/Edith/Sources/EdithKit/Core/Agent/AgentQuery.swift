import Foundation

public enum AgentQuery {
    public static func value<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async -> Result<T, Error> {
        await Task.detached(priority: .utility) { Result(catching: body) }.value
    }

    public static func optional<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async -> T? {
        try? await value(body).get()
    }

    public static func run(_ body: @escaping @Sendable () throws -> Void) async {
        _ = await value(body)
    }
}
