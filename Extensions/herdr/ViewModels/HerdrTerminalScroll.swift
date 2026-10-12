import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

typealias HerdrScrollChannelOpener =
    @Sendable (_ session: String, _ pane: String, _ machine: Machine?) async throws ->
    HerdrScrollChannel

protocol HerdrScrollChannel: AnyObject, Sendable {
    func updates() -> AsyncThrowingStream<HerdrScrollInfo, Error>
    @discardableResult func scroll(to offset: Int) async throws -> HerdrScrollInfo?
    func close()
}

extension HerdrPaneScrollChannel: HerdrScrollChannel {}

@MainActor
@Observable
final class HerdrTerminalScroll {
    var remoteScroll: (@MainActor (Int) async throws -> Void)?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    private(set) var info: HerdrScrollInfo?

    @ObservationIgnored private let open: HerdrScrollChannelOpener
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var channel: HerdrScrollChannel?
    @ObservationIgnored private var pending: Int?
    @ObservationIgnored private var sending = false

    init(
        retryDelay: Duration = .seconds(2),
        open: @escaping HerdrScrollChannelOpener = {
            try await HerdrPaneScrollChannel.open(session: $0, pane: $1, machine: $2)
        }
    ) {
        self.retryDelay = retryDelay
        self.open = open
    }

    func adoptUI(_ value: HerdrScrollInfo?) {
        if !sending { info = value }
    }

    func startWatch(session: String, pane: String, machine: Machine?) {
        guard watchTask == nil, remoteScroll == nil,
            Bundle.main.bundleURL.pathExtension != "appex"
        else { return }
        watchTask = Task { [weak self] in
            await self?.watch(session: session, pane: pane, machine: machine)
        }
    }

    func watch(session: String, pane: String, machine: Machine?) async {
        guard remoteScroll == nil, Bundle.main.bundleURL.pathExtension != "appex" else { return }
        while !Task.isCancelled {
            do {
                let channel = try await open(session, pane, machine)
                self.channel = channel
                for try await next in channel.updates() {
                    guard !Task.isCancelled else { break }
                    if !sending, info != next { info = next }
                }
            } catch {}
            channel?.close()
            channel = nil
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: retryDelay)
        }
    }

    func scroll(to offset: Int) {
        guard var current = info, current.scrollable else { return }
        let target = current.clamped(offset)
        guard target != current.offset else { return }
        current.offset = target
        info = current
        pending = target
        guard !sending else { return }
        sending = true
        sendTask = Task { [weak self] in await self?.flush() }
    }

    func shutdown() {
        watchTask?.cancel()
        sendTask?.cancel()
        remoteScroll = nil
        pending = nil
        channel?.close()
        channel = nil
        sending = false
    }

    func shutdownAndWait() async {
        let watcher = watchTask
        let sender = sendTask
        shutdown()
        await watcher?.value
        await sender?.value
        watchTask = nil
        sendTask = nil
    }

    private func flush() async {
        while let target = pending, !Task.isCancelled {
            pending = nil
            if let remoteScroll {
                try? await remoteScroll(target)
            } else if let channel {
                _ = try? await channel.scroll(to: target)
            } else {
                break
            }
        }
        pending = nil
        sending = false
    }
}

enum HerdrScrollbarGeometry {
    static let minimumThumb = 24.0

    static func thumbLength(for info: HerdrScrollInfo, track: Double) -> Double {
        guard info.scrollable, track > 0 else { return track }
        let rows = Double(info.viewportRows)
        let share = rows / (rows + Double(info.maximum))
        return min(track, max(minimumThumb, track * share))
    }

    static func thumbTop(for info: HerdrScrollInfo, track: Double) -> Double {
        guard info.scrollable else { return 0 }
        let travel = track - thumbLength(for: info, track: track)
        let fraction = Double(info.offset) / Double(info.maximum)
        return travel * (1 - fraction)
    }

    static func offset(forThumbTop top: Double, info: HerdrScrollInfo, track: Double) -> Int {
        let travel = track - thumbLength(for: info, track: track)
        guard info.scrollable, travel > 0 else { return info.offset }
        let fraction = 1 - min(1, max(0, top / travel))
        return info.clamped(Int((fraction * Double(info.maximum)).rounded()))
    }
}
