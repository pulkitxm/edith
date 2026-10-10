import AVFoundation
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor
final class VideoEditorLiveSync {
    private weak var model: VideoEditorModel?
    private var url: URL?
    private var watcher: FileSystemWatcher?
    private var task: Task<Void, Never>?
    private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private var generation = 0
    private var needsRefresh = false

    init(model: VideoEditorModel) {
        self.model = model
    }

    func watch(_ next: URL?) {
        let next = next?.resolvingSymlinksInPath().standardizedFileURL
        guard next != url else { return }
        stop()
        url = next
        model?.externalSyncMessage = nil
        guard let next else { return }
        watcher = FileSystemWatcher(
            paths: [next.deletingLastPathComponent()], debounce: 0.05, eventLatency: 0.05
        ) { [weak self] in
            Task { @MainActor [weak self] in self?.schedule() }
        }
        watcher?.start()
        schedule()
    }

    @discardableResult
    func stop() -> [Task<Void, Never>] {
        let owned = Array(ownedTasks.values)
        generation += 1
        for task in owned { task.cancel() }
        needsRefresh = false
        task = nil
        watcher?.stop()
        watcher = nil
        url = nil
        return owned
    }

    func stopAndWait() async {
        let owned = stop()
        for task in owned { await task.value }
    }

    func refresh() {
        schedule()
    }

    private func schedule() {
        task?.cancel()
        generation += 1
        let version = generation
        let token = UUID()
        guard ownedTasks.count < 8 else { needsRefresh = true; return }
        let next = Task { [weak self] in
            defer {
                self?.ownedTasks[token] = nil
                if let self, self.needsRefresh {
                    self.needsRefresh = false
                    self.schedule()
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(75))
                while let self, version == self.generation {
                    guard await self.reload(version: version) else { return }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch {}
        }
        task = next
        ownedTasks[token] = next
    }

    private func reload(version: Int) async -> Bool {
        guard let model, let url, let current = model.project,
            let fileURL = current.fileURL,
            VideoProjectFileAccess.identity(fileURL) == VideoProjectFileAccess.identity(url),
            let baseline = current.fileRevision?.value
        else { return false }
        do {
            if try baseline.matches(url) {
                model.externalSyncMessage = nil
                return false
            }
            guard !model.blocksCommandOpen else {
                model.externalSyncMessage =
                    "External edits are saved. Finish or discard your current edits to refresh."
                return true
            }
            let snapshot = try VideoEditorService.readProject(url)
            guard snapshot.project.id == current.id else {
                model.externalSyncMessage =
                    "This file now contains a different project. Reopen it to continue."
                return false
            }
            try await VideoEditorService.validateMedia(snapshot.project)
            let prepared =
                snapshot.project.clips.isEmpty
                ? nil
                : try await VideoRenderPipeline.make(project: snapshot.project, previewOnly: true)
            let item: AVPlayerItem?
            let loadingPlayer: AVPlayer?
            if let prepared {
                let next = AVPlayerItem(asset: prepared.composition)
                next.videoComposition = prepared.videoComposition
                next.audioMix = prepared.audioMix
                item = next
                loadingPlayer = AVPlayer(playerItem: next)
            } else {
                item = nil
                loadingPlayer = nil
            }
            let deadline = ContinuousClock.now + .seconds(30)
            while let item, item.status != .readyToPlay {
                try Task.checkCancellation()
                guard item.status != .failed, ContinuousClock.now < deadline else {
                    throw VideoEditorService.Failure(
                        "reload_failed",
                        item.error?.localizedDescription ?? "The updated preview could not load.")
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            try Task.checkCancellation()
            guard version == generation,
                model.project?.fileRevision?.value.hexDigest == baseline.hexDigest
            else { return false }
            guard !model.blocksCommandOpen,
                try snapshot.revision.fingerprint.matches(url)
            else { return true }
            model.acceptExternalProject(
                snapshot.project, prepared: prepared, playbackPlayer: loadingPlayer)
            return false
        } catch is CancellationError {
            return false
        } catch {
            guard version == generation else { return false }
            model.externalSyncMessage =
                "Could not refresh external edits: \(error.localizedDescription)"
            return false
        }
    }
}
