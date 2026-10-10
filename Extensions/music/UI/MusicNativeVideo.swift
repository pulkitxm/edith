import AVKit
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

@MainActor
final class EmbeddedMusicAssetLoader: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    let lease: EmbeddedMusicVideoLease
    let url: URL
    private let invoke: (String, Data) async throws -> Data
    private var pending: [ObjectIdentifier: (AVAssetResourceLoadingRequest, Task<Void, Never>)] =
        [:]
    private var retired: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var sequence: UInt64 = 0
    private(set) var stopped = false

    init(lease: EmbeddedMusicVideoLease, invoke: @escaping (String, Data) async throws -> Data)
        throws
    {
        guard lease.length > 0, lease.length <= 1_099_511_627_776,
            ["mov", "mp4", "m4v"].contains(lease.fileExtension),
            ["com.apple.quicktime-movie", "public.mpeg-4"].contains(lease.contentType),
            lease.position.isFinite, lease.position >= 0, lease.volume.isFinite,
            (0...1).contains(lease.volume)
        else { throw ExtensionPeerError.invalidRequest }
        self.lease = lease; self.invoke = invoke
        url = URL(
            string: "edith-music-video://" + lease.id.uuidString.lowercased() + "/media."
                + lease.fileExtension)!
    }

    func asset() -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)
        return asset
    }

    func read(offset: Int64, count: Int) async throws -> Data {
        guard !stopped, offset >= 0, offset < lease.length, (1...262_144).contains(count) else {
            throw ExtensionPeerError.invalidRequest
        }
        sequence &+= 1
        let request = EmbeddedMusicVideoRange(
            id: lease.id, revision: lease.revision, sequence: sequence, offset: offset, count: count
        )
        let data = try await invoke("music.ui.video.range", JSONEncoder().encode(request))
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let reply = try JSONDecoder().decode(EmbeddedMusicVideoBytes.self, from: data)
        guard reply.id == lease.id, reply.revision == lease.revision,
            reply.sequence == request.sequence, reply.offset == offset,
            reply.data.count == min(count, Int(lease.length - offset))
        else { throw ExtensionPeerError.invalidRequest }
        return reply.data
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !stopped, request.request.url == url, pending.count < 4 else { return false }
        let id = ObjectIdentifier(request)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.pending[id] = nil; self.retired[id] = nil }
            do {
                if let information = request.contentInformationRequest {
                    information.contentType = self.lease.contentType
                    information.contentLength = self.lease.length
                    information.isByteRangeAccessSupported = true
                }
                if let data = request.dataRequest {
                    var offset = max(data.requestedOffset, data.currentOffset)
                    guard offset >= 0, offset <= self.lease.length, data.requestedLength >= 0,
                        data.requestedOffset <= Int64.max - Int64(data.requestedLength)
                    else { throw ExtensionPeerError.invalidRequest }
                    let end =
                        data.requestsAllDataToEndOfResource
                        ? self.lease.length
                        : min(self.lease.length, data.requestedOffset + Int64(data.requestedLength))
                    while offset < end {
                        let bytes = try await self.read(
                            offset: offset, count: min(262_144, Int(end - offset)))
                        try Task.checkCancellation()
                        guard !self.stopped, !request.isCancelled else { throw CancellationError() }
                        data.respond(with: bytes)
                        offset += Int64(bytes.count)
                    }
                }
                guard !request.isCancelled, !request.isFinished else { return }
                request.finishLoading()
            } catch {
                if !request.isCancelled, !request.isFinished { request.finishLoading(with: error) }
            }
        }
        pending[id] = (request, task)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest
    ) {
        guard let (_, task) = pending.removeValue(forKey: ObjectIdentifier(request)) else { return }
        task.cancel(); retired[ObjectIdentifier(request)] = task
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for (request, task) in pending.values {
            task.cancel(); retired[ObjectIdentifier(request)] = task
            if !request.isFinished, !request.isCancelled {
                request.finishLoading(with: CancellationError())
            }
        }
        pending.removeAll()
    }

    func drain() async { for task in Array(retired.values) { await task.value } }
}

@MainActor @Observable final class EmbeddedMusicVideoSession {
    static private var sessions: [UUID: EmbeddedMusicVideoSession] = [:]
    static private var closing: [UUID: Task<Void, Never>] = [:]
    let lease: EmbeddedMusicVideoLease
    let player: AVPlayer
    let loader: EmbeddedMusicAssetLoader
    private let invoke: (String, Data) async throws -> Data
    private(set) var stopped = false
    private var controlRevision: UInt64 = 0
    private var observation: NSKeyValueObservation?
    private(set) var duration = 0.0
    private(set) var playing = false

    init(lease: EmbeddedMusicVideoLease, invoke: @escaping (String, Data) async throws -> Data)
        throws
    {
        self.lease = lease; self.invoke = invoke
        loader = try EmbeddedMusicAssetLoader(lease: lease, invoke: invoke)
        player = AVPlayer(playerItem: AVPlayerItem(asset: loader.asset()))
        player.volume = Float(lease.volume)
        Self.sessions[lease.id] = self
        observation = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] player, _ in
            let value = player.timeControlStatus != .paused
            Task { @MainActor [weak self] in if self?.stopped == false { self?.playing = value } }
        }
    }

    func prepare(autoplay: Bool) async throws {
        guard !stopped, let asset = player.currentItem?.asset else { throw CancellationError() }
        let value = try await asset.load(.duration)
        try Task.checkCancellation()
        guard !stopped, value.seconds.isFinite, value.seconds >= 0 else {
            throw CancellationError()
        }
        duration = value.seconds
        if lease.position > 0 {
            await player.seek(to: CMTime(seconds: lease.position, preferredTimescale: 600))
        }
        try Task.checkCancellation()
        if autoplay, !stopped { player.play() }
    }

    func apply(_ control: EmbeddedMusicVideoControl) {
        guard !stopped, control.id == lease.id, control.revision > controlRevision,
            control.volume.isFinite, (0...1).contains(control.volume),
            control.seek.map({ $0.isFinite && $0 >= 0 && $0 <= duration }) ?? true
        else { return }
        controlRevision = control.revision
        player.volume = Float(control.volume)
        if let seek = control.seek {
            player.seek(to: CMTime(seconds: seek, preferredTimescale: 600))
        }
        control.playing ? player.play() : player.pause()
    }

    func report() async throws {
        guard !stopped else { throw CancellationError() }
        let elapsed = player.currentTime().seconds
        let report = EmbeddedMusicVideoReport(
            id: lease.id, revision: lease.revision,
            elapsed: elapsed.isFinite ? max(0, elapsed) : 0, duration: duration,
            playing: playing, volume: Double(player.volume), controlRevision: controlRevision)
        _ = try await invoke("music.ui.video.update", JSONEncoder().encode(report))
    }

    func nativeView() -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player; view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true; view.allowsPictureInPicturePlayback = true
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; observation = nil
        player.currentItem?.asset.cancelLoading()
        player.pause(); player.replaceCurrentItem(with: nil); loader.stop()
        Self.sessions[lease.id] = nil
        let loader = loader; let invoke = invoke; let lease = lease
        Self.closing[lease.id] = Task {
            await loader.drain()
            _ = try? await invoke("music.ui.video.close", JSONEncoder().encode(lease))
            Self.closing[lease.id] = nil
        }
    }

    static func apply(_ control: EmbeddedMusicVideoControl?) {
        if let control { sessions[control.id]?.apply(control) }
    }
    static func stopAll() { for session in Array(sessions.values) { session.stop() } }
    static func drainAll() async { for task in Array(closing.values) { await task.value } }
}

private struct EmbeddedMusicNativeVideoPlayer: NSViewRepresentable {
    let session: EmbeddedMusicVideoSession
    func makeNSView(context: Context) -> AVPlayerView { session.nativeView() }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== session.player { view.player = session.player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

struct EmbeddedMusicVideoArtwork: View {
    let track: EmbeddedTrack
    @State private var session: EmbeddedMusicVideoSession?
    @State private var error: String?
    var body: some View {
        Group {
            if let session {
                EmbeddedMusicNativeVideoPlayer(session: session)
            } else if let error {
                PageNotice(error, tone: .error)
            } else {
                LoadingIndicator()
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .shadow(color: .black.opacity(0.3), radius: UIScale.pt(16), y: UIScale.pt(8))
        .pageTask(id: track.id) {
            do {
                let remote = EmbeddedMusicRemote.shared
                let data = try await remote.request(
                    "music.ui.video.open", action: .init(kind: .videoOpen, path: track.relativePath)
                )
                let lease = try JSONDecoder().decode(EmbeddedMusicVideoLease.self, from: data)
                let next = try EmbeddedMusicVideoSession(lease: lease) {
                    [weak remote] operation, payload in
                    guard let remote else { throw CancellationError() }
                    return try await remote.dataRequest(operation, payload: payload)
                }
                session = next
                do { try await next.prepare(autoplay: lease.playing) } catch {
                    next.stop(); session = nil; throw error
                }
                try await next.report()
                remote.rescan(force: true)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .pageRefresh(interval: { .milliseconds(250) }) { try? await session?.report() }
        .onDisappear {
            session?.stop(); session = nil
        }
    }
}
