import Foundation

public enum LocalFileListing {
    public static func entries(path: String) -> [RemoteFileEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard
            let urls = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
                options: [])
        else { return [] }
        let entries = urls.map { url -> RemoteFileEntry in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let kind: FileEntryKind =
                values?.isSymbolicLink == true
                ? .symlink : (values?.isDirectory == true ? .directory : .file)
            return RemoteFileEntry(
                name: url.lastPathComponent,
                path: FileListing.join(parent: path, name: url.lastPathComponent), kind: kind,
                sizeBytes: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate,
                linkTarget: kind == .symlink
                    ? try? fm.destinationOfSymbolicLink(atPath: url.path) : nil)
        }
        return FileListing.sorted(entries)
    }

    public static func search(root: String, query: String, limit: Int = 300) -> [RemoteFileEntry] {
        guard !query.isEmpty else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [RemoteFileEntry] = []
        for case let url as URL in walker {
            guard !Task.isCancelled, found.count < limit else { break }
            guard url.lastPathComponent.localizedCaseInsensitiveContains(query) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let path = FilePathKey.anchor(url.path, to: root)
            found.append(
                RemoteFileEntry(
                    name: url.lastPathComponent, path: path,
                    kind: values?.isDirectory == true ? .directory : .file,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate))
        }
        return found
    }
}
