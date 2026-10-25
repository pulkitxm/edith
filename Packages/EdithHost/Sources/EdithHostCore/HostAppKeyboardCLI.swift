import Foundation

public enum HostAppKeyboardCLI {
    public static func response(_ data: Data) throws -> HostCLIJSON {
        guard data.count <= 65536,
            let value = try JSONDecoder().decode(HostCLIJSON.self, from: data).object,
            let result = value["result"]?.string, let status = value["status"]?.object,
            status["hasInputMonitoring"]?.bool != nil, status["hasAccessibility"]?.bool != nil
        else { throw HostCLIError.rejected("Invalid keyboard cleaning response.") }
        switch result {
        case "arming", "cleaning":
            guard status["phase"] == .string(result), status["hasInputMonitoring"] == .bool(true),
                status["hasAccessibility"] == .bool(true)
            else {
                throw HostCLIError.rejected("Keyboard cleaning returned an inconsistent state.")
            }
            return .object([
                "action": .string("clean-keys"), "requested": .bool(true), "state": .string(result),
            ])
        case "inputMonitoringRequired":
            throw HostAppCLIUnavailable(
                message: "keyboard cleaning needs Input Monitoring",
                hint:
                    "run `ed permissions request inputMonitoring`, enable this Edith installation, then relaunch it"
            )
        case "accessibilityRequired":
            throw HostAppCLIUnavailable(
                message: "keyboard cleaning needs Accessibility",
                hint:
                    "run `ed permissions request accessibility`, enable this Edith installation, then relaunch it"
            )
        case "unavailable":
            throw HostAppCLIUnavailable(
                message: "keyboard cleaning is not available",
                hint: "run `ed extensions enable system`, then relaunch this Edith installation")
        default: throw HostCLIError.rejected("Unknown keyboard cleaning state.")
        }
    }
}
