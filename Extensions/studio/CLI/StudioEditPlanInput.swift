import EdithExtensionSupport
import EdithExtensionCommands
import Foundation

enum StudioEditPlanInput {
    static let maximumBytes = 4 * 1024 * 1024

    static func read(_ path: String, mediaDirectory: String?) throws -> (data: Data, directory: URL)
    {
        let handle: FileHandle
        let directory: URL
        if path == "-" {
            let data = StudioCLIEnvironment.standardInput
            let base =
                mediaDirectory.map(StudioEditBridge.url) ?? StudioCLIEnvironment.workingDirectory
            let properties = try base.resourceValues(forKeys: [.isDirectoryKey])
            guard properties.isDirectory == true else {
                throw VideoEditorService.Failure(
                    "invalid_plan", "Media directory must be a local directory.")
            }
            return (data, base)
        } else {
            let url = StudioEditBridge.url(path)
            let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard properties.isRegularFile == true, let size = properties.fileSize,
                size <= maximumBytes
            else {
                throw VideoEditorService.Failure(
                    "invalid_plan", "Expected a regular edit-plan file of at most 4 MiB.")
            }
            handle = try FileHandle(forReadingFrom: url)
            directory = url.deletingLastPathComponent()
        }
        defer { if path != "-" { try? handle.close() } }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, maximumBytes + 1 - data.count)),
            !chunk.isEmpty
        {
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw VideoEditorService.Failure(
                    "invalid_plan", "Edit plans must be at most 4 MiB.")
            }
        }
        let base = mediaDirectory.map(StudioEditBridge.url) ?? directory
        let properties = try base.resourceValues(forKeys: [.isDirectoryKey])
        guard properties.isDirectory == true else {
            throw VideoEditorService.Failure(
                "invalid_plan", "Media directory must be a local directory.")
        }
        return (data, base)
    }
}
