import Foundation

public enum DatabaseStorageIdentity {
    public static func metadataFile(root: URL, applicationIdentifier: String?) -> URL {
        root.appendingPathComponent(
            applicationIdentifier == "com.pulkit.edith" ? "metadata.sqlite3" : "metadata.sqlite")
    }
}
