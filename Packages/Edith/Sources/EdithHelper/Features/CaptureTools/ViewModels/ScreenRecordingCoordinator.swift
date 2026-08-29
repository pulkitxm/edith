import AppKit
import AVFoundation
import EdithKit
import Observation

@MainActor
@Observable
final class ScreenRecordingCoordinator {
    private(set) var status = ScreenRecordingStatus()
    private let selector = ScreenRecordingSourceSelector()
    private var session: ScreenRecordingSession?
    private var controls: ScreenRecordingControlsController?
    private var editors: [ScreenRecordingEditorController] = []
    private var library: ScreenRecordingLibraryController?
    private var task: Task<Void, Never>?
    private var generation = 0

    init() {
        ScreenRecordingLibrary.prune()
        publish(ScreenRecordingStatus())
    }

    func start(_ source: ScreenRecordingSource) {
        guard status.state == .idle || status.state == .editing || status.state == .failed else {
            NSSound.beep()
            return
        }
        generation &+= 1
        let token = generation
        publish(ScreenRecordingStatus(state: .selecting, source: source))
        task = Task { [weak self] in await self?.prepare(source, token: token) }
    }

    func pauseOrResume() {
        guard let session else { return }
        if session.isPaused {
            guard session.resume() else { return }
            publish(ScreenRecordingStatus(
                state: .recording, source: status.source,
                elapsedSeconds: session.elapsedSeconds, takeID: status.takeID))
        } else {
            guard session.pause() else { return }
            publish(ScreenRecordingStatus(
                state: .paused, source: status.source,
                elapsedSeconds: session.elapsedSeconds, takeID: status.takeID))
        }
    }

    func pause() {
        guard session?.isPaused == false else { return }
        pauseOrResume()
    }

    func resume() {
        guard session?.isPaused == true else { return }
        pauseOrResume()
    }

    func stop() {
        guard let session else { return }
        generation &+= 1
        publish(ScreenRecordingStatus(
            state: .finishing, source: status.source,
            elapsedSeconds: session.elapsedSeconds, takeID: status.takeID))
        controls?.close()
        controls = nil
        task = Task { [weak self] in await self?.finish(session, discard: false) }
    }

    func cancel() {
        generation &+= 1
        selector.cancel()
        task?.cancel()
        task = nil
        controls?.close()
        controls = nil
        guard let session else {
            publish(ScreenRecordingStatus())
            return
        }
        self.session = nil
        Task { [weak self] in
            await session.cancel()
            await MainActor.run { self?.publish(ScreenRecordingStatus()) }
        }
    }

    func showLibrary() {
        if library == nil {
            library = ScreenRecordingLibraryController(
                open: { [weak self] in self?.openEditor($0) })
        }
        library?.show()
    }

    func shutdown() {
        generation &+= 1
        selector.cancel()
        task?.cancel()
        task = nil
        controls?.close()
        controls = nil
        library?.close()
        library = nil
        editors.forEach { $0.close() }
        editors = []
        if let session {
            self.session = nil
            Task { await session.stop() }
        }
        publish(ScreenRecordingStatus())
    }

    private func prepare(_ source: ScreenRecordingSource, token: Int) async {
        do {
            let region = try await selector.select(source)
            guard token == generation, !Task.isCancelled else { return }
            let take = try ScreenRecordingLibrary.makeTake(source: source)
            let capturesSystemAudio =
                SharedDefaults.store.object(forKey: AppStorageKeys.Capture.recordingSystemAudio)
                    as? Bool ?? true
            let capturesMicrophone =
                SharedDefaults.store.object(forKey: AppStorageKeys.Capture.recordingMicrophone)
                    as? Bool ?? false
            if capturesMicrophone {
                let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
                let granted: Bool
                if authorization == .notDetermined {
                    granted = await AVCaptureDevice.requestAccess(for: .audio)
                } else {
                    granted = authorization == .authorized
                }
                guard granted else { throw ScreenRecordingError.microphoneUnavailable }
            }
            let frameRate =
                SharedDefaults.store.object(forKey: AppStorageKeys.Capture.recordingFrameRate)
                    as? Int ?? 30
            let session = ScreenRecordingSession(
                take: take, region: region, capturesSystemAudio: capturesSystemAudio,
                capturesMicrophone: capturesMicrophone, frameRate: frameRate)
            session.onElapsedTime = { [weak self] seconds in
                Task { @MainActor in
                    guard let self, self.session === session else { return }
                    self.publish(ScreenRecordingStatus(
                        state: session.isPaused ? .paused : .recording,
                        source: source, elapsedSeconds: seconds, takeID: take.id))
                }
            }
            session.onUnexpectedStop = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.session === session else { return }
                    self.publish(ScreenRecordingStatus(
                        state: .failed, source: source,
                        elapsedSeconds: session.elapsedSeconds, takeID: take.id,
                        message: error.localizedDescription))
                    self.stop()
                }
            }
            self.session = session
            try await session.start()
            guard token == generation, !Task.isCancelled else {
                await session.cancel()
                return
            }
            publish(ScreenRecordingStatus(
                state: .recording, source: source, takeID: take.id))
            controls = ScreenRecordingControlsController(
                source: source, pause: { [weak self] in self?.pauseOrResume() },
                stop: { [weak self] in self?.stop() },
                cancel: { [weak self] in self?.cancel() })
            controls?.show()
        } catch ScreenRecordingError.cancelled {
            publish(ScreenRecordingStatus())
        } catch is CancellationError {
            publish(ScreenRecordingStatus())
        } catch {
            if let session { await session.cancel() }
            session = nil
            publish(ScreenRecordingStatus(state: .failed, source: source, message: error.localizedDescription))
            NSSound.beep()
        }
    }

    private func finish(_ session: ScreenRecordingSession, discard: Bool) async {
        await session.stop(discarding: discard)
        guard self.session === session else { return }
        self.session = nil
        task = nil
        guard !discard, let id = status.takeID,
            let take = ScreenRecordingLibrary.load().first(where: { $0.id == id })
        else { publish(ScreenRecordingStatus()); return }
        openEditor(take)
        publish(ScreenRecordingStatus(
            state: .editing, source: take.source,
            elapsedSeconds: take.duration, takeID: take.id))
        library?.reload()
    }

    private func openEditor(_ take: ScreenRecordingTake) {
        editors.removeAll { !$0.isVisible }
        let editor = ScreenRecordingEditorController(take: take) { [weak self] in
            self?.library?.reload()
            if self?.status.takeID == take.id { self?.publish(ScreenRecordingStatus()) }
        }
        editors.append(editor)
        editor.show()
    }

    private func publish(_ status: ScreenRecordingStatus) {
        self.status = status
        if let data = try? JSONEncoder().encode(status) {
            SharedDefaults.store.set(data, forKey: AppStorageKeys.Capture.recordingStatus)
        }
        IPC.post(IPC.Name.recordingStatusChanged)
    }
}
