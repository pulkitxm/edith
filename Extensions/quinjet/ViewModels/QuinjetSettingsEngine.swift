import EdithExtensionSupport
import Foundation

@MainActor enum QuinjetSettingsEngine {
    static func execute(_ operation: String, object: [String: Any], worker: QuinjetWorker)
        async throws -> Data
    {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        if operation == "quinjet.settings.read" {
            guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
            await worker.model.refreshThemes()
            try Task.checkCancellation()
            guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        }
        return try QuinjetSettingsStore(defaults: worker.defaults).execute(
            operation, object: object, themes: worker.model.themes.map(\.rawValue),
            cmuxAvailable: QuinjetTerminal.cmux.isAvailable)
    }
}
