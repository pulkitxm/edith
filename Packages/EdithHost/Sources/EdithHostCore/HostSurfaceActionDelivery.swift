@MainActor
public enum HostSurfaceActionDelivery {
    public static func requiresWindow(providerID: String, actionID: String) -> Bool {
        providerID == "terminal" && (actionID == "new" || actionID.hasPrefix("focus/"))
    }

    public static func perform<Value>(
        validate: @MainActor () throws -> Void,
        command: @MainActor () async throws -> Value,
        deliver: @MainActor () async throws -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        try validate()
        let value = try await command()
        try Task.checkCancellation()
        try validate()
        try await deliver()
        try Task.checkCancellation()
        try validate()
        return value
    }
}
