import EdithDatabase

public enum DatabaseCLIEnvironment {
    nonisolated(unsafe) public static var makeSender:
        @Sendable () -> any DatabaseBrokerCommandSending = {
            DatabaseBrokerCommandClient()
        }

    public static func reset() {
        makeSender = { DatabaseBrokerCommandClient() }
    }
}
