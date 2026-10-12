import Foundation

public enum StudioWorkflowFile {
    public static let fileName = "workflows.json"

    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    public static func load(from directory: URL) -> [StudioWorkflow] {
        let file = url(in: directory)
        guard let data = try? Data(contentsOf: file) else { return StudioWorkflow.presets }
        return (try? JSONDecoder().decode([StudioWorkflow].self, from: data))
            ?? StudioWorkflow.presets
    }

    public static func save(_ workflows: [StudioWorkflow], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(workflows)
        try data.write(to: url(in: directory), options: .atomic)
    }
}
