import Foundation

struct WorkerFixtureBlitzTreeNamespace {
    let source: WorkerFixtureResolvedFileScope
    let destination: WorkerFixtureResolvedFileScope

    init(
        owner: String, source: WorkerFixtureResolvedFileScope,
        destination: WorkerFixtureResolvedFileScope
    ) throws {
        guard owner == "blitztree" else { throw WorkerFixtureError.invalid }
        for (value, name, directory, present) in [
            (source, "scan-directory", "scan", WorkerFixtureFilePresence.present),
            (destination, "trash-directory", "trash", WorkerFixtureFilePresence.absent),
        ] {
            let scope = value.scope
            guard scope.name == name, scope.kind == .directory,
                scope.purpose == .mutableState, scope.root == .ownerOutputs,
                scope.components == [.phase, .literal(directory)], scope.maximumBytes == 4096,
                scope.maximumEntries == 1, scope.initialState == .present,
                scope.allowedStates == [.present], scope.immutableFiles.isEmpty,
                scope.mutableFiles.count == 1,
                let file = scope.mutableFiles.first, file.components == ["victim.bin"],
                file.maximumBytes == 4096, file.initialState == present,
                Set(file.allowedStates) == [.present, .absent]
            else { throw WorkerFixtureError.invalid }
        }
        self.source = source; self.destination = destination
    }
}
