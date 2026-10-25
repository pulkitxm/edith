import EdithExtensionSupport
import Foundation

public struct HostCameraLifecycleCLI: Sendable {
    private let invoke: HostCLIProviderRegistry.Invoke
    private let missingPermissions: @Sendable () async throws -> [String]

    public init(
        invoke: @escaping HostCLIProviderRegistry.Invoke,
        missingPermissions: @escaping @Sendable () async throws -> [String]
    ) {
        self.invoke = invoke; self.missingPermissions = missingPermissions
    }

    public func execute(_ arguments: [String]) async throws -> ExtensionCLIReply {
        let args = try HostCLIArguments(arguments, flags: ["--json"])
        try args.require(words: 1...1, flags: ["--json"])
        guard let action = args.words.first, ["on", "off"].contains(action) else {
            throw HostCLIError.usage("Use camera on or camera off.")
        }
        let enabled = action == "on"
        let info = try await state(.info)
        if enabled {
            if !info.installed { _ = try await state(.install) }
            let result = try await state(.enable)
            guard result.enabled, result.compatible, !result.disablePending,
                !result.removalPending
            else { throw HostCLIError.rejected("The virtual camera could not be enabled.") }
        } else {
            let result = try await state(.disable)
            guard !result.enabled, !result.running, !result.disablePending else {
                throw HostCLIError.rejected("The virtual camera did not finish stopping.")
            }
        }
        try Task.checkCancellation()
        let missing = enabled ? try await missingPermissions() : []
        guard missing.count <= 32, missing.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 80 }) else {
            throw HostCLIError.rejected("Invalid camera permission result.")
        }
        try Task.checkCancellation()
        if args.flags.contains("--json") {
            return try HostCLIOutput.json(
                .object(["enabled": .bool(enabled), "missingPermissions": .strings(missing)]))
        }
        return try ExtensionCLIReply(
            stdout: "virtual camera \(enabled ? "on" : "off")\n",
            stderr: missing.map {
                "note: Virtual Camera needs \($0); run `ed permissions request \($0)`\n"
            }.joined(), exitCode: 0)
    }

    private func state(_ action: HostCLIRequest.Action) async throws -> HostCLIProviderState {
        try Task.checkCancellation()
        let data = try await invoke(
            HostCLIRequest(action: action, id: "virtualCamera", timeout: 120))
        try Task.checkCancellation()
        let result = try JSONDecoder().decode(HostCLIProviderState.self, from: data)
        guard result.id == "virtualCamera" else {
            throw HostCLIError.rejected("The camera lifecycle returned the wrong owner.")
        }
        return result
    }
}
