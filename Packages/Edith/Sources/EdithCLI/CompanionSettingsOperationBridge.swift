import EdithKit

enum CompanionSettingsOperationBridge {
    static func request<T>(
        endpoint: String?,
        operation: (CompanionSettingsOperationExecution) async throws -> T
    ) async throws -> T {
        do {
            return try await CompanionBridge.request(endpoint: endpoint) { client in
                try await operation(CompanionSettingsOperationExecution(client: client))
            }
        } catch let error as CompanionSettingsOperationError {
            throw CLIFailure.usage(error.localizedDescription)
        }
    }

    static func connectorUpdate(
        github: String?, notion: String?
    ) throws -> CompanionConnectorTokenUpdate {
        do {
            return try CompanionConnectorTokenUpdate(github: github, notion: notion)
        } catch let error as CompanionSettingsOperationError {
            throw CLIFailure.usage(error.localizedDescription)
        }
    }

    static func reasonUpdate(
        provider: String?, url: String?, model: String?, apiKey: String?
    ) throws -> CompanionReasonConfigurationUpdate {
        do {
            return try CompanionReasonConfigurationUpdate(
                provider: provider, url: url, model: model, apiKey: apiKey)
        } catch let error as CompanionSettingsOperationError {
            throw CLIFailure.usage(error.localizedDescription)
        }
    }
}
