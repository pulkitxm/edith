#if canImport(WorkerFixtureSupport)
import Darwin
import Foundation
import EdithExtensionSupport
import WorkerFixtureSupport

@MainActor
final class BlitzTreeFixtureFiles {
    private let lease: WorkerFixtureCooperativeNamespaceLease
    private let root: String
    private let victim: String
    private let device: Int32
    private let inode: UInt64
    private var action: WorkerFixtureNamespaceAction?
    private var moved = false

    init(_ admission: WorkerFixtureEngineAdmission) throws {
        try admission.requireCurrent()
        guard admission.descriptor.owner == "blitztree", admission.descriptor.role == "app",
            Set(admission.descriptor.operations) == [
                "blitztree.ui.scan", "blitztree.ui.snapshot", "blitztree.ui.trash",
            ], admission.descriptor.inputs.isEmpty,
            Set(admission.descriptor.outputs.map(\.name)) == ["victim", "private-trash"]
        else { throw WorkerFixtureError.invalid }
        let victim = try admission.outputURL(named: "victim")
        let trash = try admission.outputURL(named: "private-trash")
        guard let phase = WorkerFixtureFilePhase(rawValue: admission.descriptor.phase),
            victim.lastPathComponent == "victim.bin", trash.lastPathComponent == "victim.bin",
            victim.deletingLastPathComponent().lastPathComponent == "scan",
            trash.deletingLastPathComponent().lastPathComponent == "trash",
            victim.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                == phase.rawValue,
            victim.deletingLastPathComponent().deletingLastPathComponent()
                == trash.deletingLastPathComponent().deletingLastPathComponent()
        else { throw WorkerFixtureError.invalid }
        let descriptor = open(victim.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw WorkerFixtureError.invalid }
        defer { close(descriptor) }
        var state = stat()
        guard fstat(descriptor, &state) == 0, state.st_mode & S_IFMT == S_IFREG,
            state.st_mode & 0o777 == 0o600, state.st_uid == getuid(), state.st_nlink == 1,
            state.st_size == 4096
        else { throw WorkerFixtureError.invalid }
        var bytes = Data(count: 4096)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == bytes.count, bytes == Data(repeating: 42, count: 4096) else {
            throw WorkerFixtureError.invalid
        }
        try admission.requireCurrent()
        self.lease = try admission.blitzTreeNamespaceLease();
        root = victim.deletingLastPathComponent().path
        self.victim = victim.path; device = state.st_dev; inode = state.st_ino
    }

    func withAction<Value>(_ body: () async throws -> Value) async throws -> Value {
        try await lease.withAction { value in
            action = value
            defer { action = nil }
            return try await body()
        }
    }

    func validateCommand(_ command: String, payload: Data) throws {
        try requireCurrentAction()
        if command == "blitztree.ui.snapshot" {
            guard payload == Data("{}".utf8) else { throw WorkerFixtureError.invalid }
            return
        }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw WorkerFixtureError.invalid }
        if command == "blitztree.ui.scan" {
            guard Set(object.keys) == ["path"], object["path"] as? String == root else {
                throw WorkerFixtureError.invalid
            }
        } else {
            guard command == "blitztree.ui.trash", !moved,
                Set(object.keys) == ["confirmed", "previewToken", "path"],
                object["path"] as? String == victim
            else { throw WorkerFixtureError.invalid }
        }
    }

    func scan(_ path: String, progress: @escaping BlitzTreeClient.Progress) async throws
        -> BlitzTreeReport
    {
        guard path == root else { throw WorkerFixtureError.invalid }
        try requireCurrentAction()
        let cancellation = Progress(totalUnitCount: 0)
        let report = try await withTaskCancellationHandler {
            try await BlockingWork.perform {
                try BlitzTreeScanner.scan(
                    root: path, isCancelled: { cancellation.isCancelled }, progress: progress)
            }
        } onCancel: {
            cancellation.cancel()
        }
        try requireCurrentAction()
        try Task.checkCancellation()
        guard report.root == root, report.coverage.complete, report.coverage.errors == 0,
            report.summary.fileCount == (moved ? 0 : 1), report.summary.directoryCount == 1,
            moved
                || report.report.inventory.largestChildren.contains(where: {
                    $0.path == victim && $0.device == device && $0.inode == inode
                        && $0.kind == "file" && $0.logicalBytes == 4096
                })
        else { throw WorkerFixtureError.invalid }
        return report
    }

    func trash(_ entry: BlitzTreeReport.Entry, root: String, cancellation: Progress) throws {
        guard root == self.root, entry.path == victim, entry.device == device,
            entry.inode == inode, entry.kind == "file", entry.logicalBytes == 4096,
            let action, !moved
        else { throw WorkerFixtureError.invalid }
        try requireCurrentAction()
        try BlitzTreeActions.trash(entry, root: root, isCancelled: { cancellation.isCancelled }) {
            _ = try lease.moveToPrivateTrash($0, action: action)
            moved = true
        }
        try requireCurrentAction()
    }

    func closeAdmission() { lease.closeAdmission() }
    func closeAndWait() async { await lease.closeAndWait() }

    private func requireCurrentAction() throws {
        guard let action else { throw WorkerFixtureError.invalid }
        try lease.requireCurrent(action)
    }
}
#endif
