import CGTK
import EdithCore
import Foundation

private struct LinuxDiagnosticReport: Codable {
    let platform: AppPlatform
    let configurationDirectory: String
    let dataDirectory: String
    let cacheDirectory: String
    let runtimeDirectory: String
    let supportedCapabilities: [String]
    let integrationCapabilities: [String]
    let extensions: [String: String]
}

@main
struct EdithLinuxApplication {
    static func main() throws {
        let directories = AppDirectories.current
        try directories.prepare()
        if CommandLine.arguments.contains("--diagnose") {
            try printDiagnostics(directories: directories)
            return
        }
        let status = edith_gtk_run()
        guard status == 0 else { throw LinuxApplicationError.failed(status) }
    }

    private static func printDiagnostics(directories: AppDirectories) throws {
        let supported = PlatformCapability.allCases.filter {
            PlatformCapabilities.ubuntu.state(for: $0).isSupported
        }
        let integration = PlatformCapability.allCases.filter {
            if case .integrationRequired = PlatformCapabilities.ubuntu.state(for: $0) {
                return true
            }
            return false
        }
        let report = LinuxDiagnosticReport(
            platform: .current,
            configurationDirectory: directories.configuration.path,
            dataDirectory: directories.data.path,
            cacheDirectory: directories.cache.path,
            runtimeDirectory: directories.runtime.path,
            supportedCapabilities: supported.map(\.rawValue),
            integrationCapabilities: integration.map(\.rawValue),
            extensions: Dictionary(
                uniqueKeysWithValues: ExtensionRegistry.entries.map {
                    ($0.id, availabilityName($0.availability(on: .ubuntu)))
                }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(report)
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

private enum LinuxApplicationError: Error {
    case failed(Int32)
}
