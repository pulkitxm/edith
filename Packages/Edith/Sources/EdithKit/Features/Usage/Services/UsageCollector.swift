import Foundation

public enum UsageCollector {
    public static let scriptName = "refresh-usage"

    public static func scriptURL() -> URL? {
        BundledResources.locate(scriptName, in: BundledResources.kitBundleName)
    }

    public static func script() -> Data? {
        guard let url = scriptURL(),
            let runtimeURL = BundledResources.locate(
                "usage-billing-archive.mjs", in: BundledResources.kitBundleName),
            let source = try? String(contentsOf: url, encoding: .utf8),
            let runtime = try? String(contentsOf: runtimeURL, encoding: .utf8)
        else { return nil }
        let marker = #"BILLING_ARCHIVE_SCRIPT="${BASH_SOURCE[0]%/*}/usage-billing-archive.mjs""#
        guard source.components(separatedBy: marker).count == 2, runtime.hasSuffix("\n") else {
            return nil
        }
        let embedded = """
            BILLING_ARCHIVE_SCRIPT="$TMP/usage-billing-archive.mjs"
            cat >"$BILLING_ARCHIVE_SCRIPT" <<'EDITH_BILLING_RUNTIME'
            \(runtime.dropLast())
            EDITH_BILLING_RUNTIME
            """
        return Data(source.replacingOccurrences(of: marker, with: embedded).utf8)
    }

    public static var machinesDirectory: URL {
        Repo.dataDir.appendingPathComponent("machines")
    }

    public static func machineFile(id: UUID, in directory: URL = machinesDirectory) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
