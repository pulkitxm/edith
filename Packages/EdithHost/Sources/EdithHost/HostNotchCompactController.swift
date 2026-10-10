import AppKit
import EdithExtensionSupport
import EdithHostCore
import SwiftUI

@MainActor
final class HostNotchCompactController: NSViewController {
    let model: HostNotchCompactCardModel
    let layout: SurfaceLayout
    var measured: (@MainActor (Double) -> Void)?
    private var poll: Task<Void, Never>?
    private var visible = false
    private var stopped = false
    private let automatic: Bool

    init(model: HostNotchCompactCardModel, layout: SurfaceLayout, automatic: Bool = true) {
        self.model = model; self.layout = layout; self.automatic = automatic
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingController(
            rootView: HostNotchCompactCard(model: model, layout: layout) {
                [weak self] height in
                guard let self, !stopped, visible, height.isFinite, (1...1200).contains(height)
                else { return }
                measured?(height)
            })
        addChild(host)
        view = host.view
    }

    func apply(visible: Bool, width: Double) {
        guard !stopped else { return }
        self.visible = visible
        if width.isFinite, width > 0 {
            view.setFrameSize(.init(width: width, height: view.frame.height))
        }
        if !visible {
            poll?.cancel(); model.invalidate()
        } else if automatic, poll == nil {
            poll = Task { [weak self] in
                guard let self else { return }
                defer { poll = nil }
                repeat {
                    do { try await model.refresh() } catch {}
                    guard visible, !stopped, !Task.isCancelled else { return }
                    do {
                        try await Task.sleep(for: .seconds(Self.interval(model.origin.tile.widget)))
                    } catch { return }
                } while visible && !stopped && !Task.isCancelled
            }
        }
    }

    func stop() async {
        stopped = true; visible = false
        poll?.cancel()
        await model.stop()
        if let poll { await poll.value }
        poll = nil
    }

    static func interval(_ widget: SurfaceWidget) -> Double {
        switch widget {
        case .ability("systemStats"), .ability("system"): 2
        case .ability("downloads"), .ability("audioMixer"), .ability("timeLapse"): 5
        case .ability("clipboard"), .ability("notchShelf"), .desk: 10
        default: 30
        }
    }

    static func lease(
        request: HostExtensionContentRequest, model: HostNotchCompactCardModel,
        layout: SurfaceLayout, automatic: Bool = true
    ) -> HostNotchSceneLease {
        let controller = HostNotchCompactController(
            model: model, layout: layout, automatic: automatic)
        let lease = HostNotchSceneLease(
            request: request, controller: controller,
            update: { _, visible, width in controller.apply(visible: visible, width: width) },
            release: { await controller.stop() })
        controller.measured = { [weak lease] in lease?.measuredHeight?($0) }
        return lease
    }
}
