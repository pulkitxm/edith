import Foundation

public enum UsageCollector {
    public static let scriptName = "refresh-usage"

    public static func scriptURL() -> URL? {
        BundledResources.locate(scriptName, in: BundledResources.kitBundleName)
    }

    public static func script() -> Data? {
        guard let url = scriptURL(),
            var source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        for (variable, name, delimiter) in [
            ("BILLING_ARCHIVE_SCRIPT", "usage-billing-archive.mjs", "EDITH_BILLING_RUNTIME"),
            ("SESSION_INPUT_SCRIPT", "usage-session-input.mjs", "EDITH_SESSION_RUNTIME"),
        ] {
            guard
                let runtimeURL = BundledResources.locate(name, in: BundledResources.kitBundleName),
                let runtime = try? String(contentsOf: runtimeURL, encoding: .utf8)
            else { return nil }
            let marker = "\(variable)=\"${BASH_SOURCE[0]%/*}/\(name)\""
            guard source.components(separatedBy: marker).count == 2, runtime.hasSuffix("\n") else {
                return nil
            }
            let embedded = """
                \(variable)="$TMP/\(name)"
                cat >"$\(variable)" <<'\(delimiter)'
                \(runtime.dropLast())
                \(delimiter)
                """
            source = source.replacingOccurrences(of: marker, with: embedded)
        }
        return Data(source.utf8)
    }

    public static var machinesDirectory: URL {
        Repo.dataDir.appendingPathComponent("machines")
    }

    public static func machineFile(id: UUID, in directory: URL = machinesDirectory) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
