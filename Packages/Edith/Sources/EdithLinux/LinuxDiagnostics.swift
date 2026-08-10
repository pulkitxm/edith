import EdithCore
import Foundation

struct LinuxDiagnosticReport: Codable {
    let platform: AppPlatform
    let configurationDirectory: String
    let dataDirectory: String
    let cacheDirectory: String
    let runtimeDirectory: String
    let supportedCapabilities: [String]
    let integrationCapabilities: [String]
    let extensions: [String: String]
}

enum LinuxDiagnostics {
    static func report(directories: AppDirectories) -> LinuxDiagnosticReport {
        let capabilities = PlatformCapabilities.ubuntu
        let supported = PlatformCapability.allCases.filter {
            capabilities.state(for: $0).isSupported
        }
        let integration = PlatformCapability.allCases.filter {
            if case .integrationRequired = capabilities.state(for: $0) { return true }
            return false
        }
        return LinuxDiagnosticReport(
            platform: .current,
            configurationDirectory: directories.configuration.path,
            dataDirectory: directories.data.path,
            cacheDirectory: directories.cache.path,
            runtimeDirectory: directories.runtime.path,
            supportedCapabilities: supported.map(\.rawValue),
            integrationCapabilities: integration.map(\.rawValue),
            extensions: Dictionary(
                uniqueKeysWithValues: ExtensionRegistry.entries.map {
                    ($0.id, availabilityName($0.availability(on: capabilities)))
                }))
    }

    static func write(directories: AppDirectories) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(report(directories: directories))
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func availabilityName(_ availability: ExtensionPlatformAvailability) -> String {
        switch availability {
        case .available: "available"
        case .degraded: "degraded"
        case .unavailable: "unavailable"
        }
    }
}
