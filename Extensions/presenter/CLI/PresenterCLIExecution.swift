import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum PresenterCLIEnvironment {
    static var defaults = SharedDefaults.store
    static var perform: (PresenterRuntimeOperation) -> PresenterRuntimeSnapshot = { operation in
        PresenterRuntimeOperationExecution.perform(operation, post: { _ in })
    }
}

@MainActor enum PresenterCLIExecution {
    static func run(
        _ request: ExtensionCLIRequest, defaults: UserDefaults,
        perform: @escaping (PresenterRuntimeOperation) -> PresenterRuntimeSnapshot
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        let oldDefaults = PresenterCLIEnvironment.defaults
        let oldPerform = PresenterCLIEnvironment.perform
        PresenterCLIEnvironment.defaults = defaults
        PresenterCLIEnvironment.perform = perform
        defer {
            PresenterCLIEnvironment.defaults = oldDefaults
            PresenterCLIEnvironment.perform = oldPerform
        }
        return try await ExtensionCLIExecution.run(
            PresenterCommand.self, arguments: request.arguments)
    }
}
