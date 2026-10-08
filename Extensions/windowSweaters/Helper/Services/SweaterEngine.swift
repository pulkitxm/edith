import AppKit
import EdithKit
import Foundation

@MainActor
final class SweaterEngine: FeatureModule {
    private let renderer = KnitRenderer()
    private var tracker: SweaterWindowTracker?
    private var reconciler: SweaterReconciler?
    private var current = SweaterSettings()

    init() {
        guard SkyLight.isAvailable else { return }
        current = SweaterState.settings()
        let renderer = renderer
        let tracker = SweaterWindowTracker(settings: { [weak self] in
            guard let self else {
                return SweaterRuntimeSettings(SweaterSettings(active: false), renderer: renderer)
            }
            return SweaterRuntimeSettings(self.current, renderer: renderer)
        })
        self.tracker = tracker
        let reconciler = SweaterReconciler(tracker: tracker)
        self.reconciler = reconciler
        tracker.onActivity = { [weak reconciler] in reconciler?.wake() }
        tracker.addExistingWindows()
        tracker.determineAndFocusActiveWindow()
        reconciler.start()
    }

    func shutdown() {
        reconciler?.stop()
        reconciler = nil
        tracker?.shutDown()
        tracker = nil
        renderer.flushCache()
    }

    func applySettings() {
        guard let tracker else { return }
        let updated = SweaterState.settings()
        guard updated != current else { return }
        let wasActive = current.active
        let repaints =
            updated.pattern != current.pattern || updated.stitch != current.stitch
            || updated.basket != current.basket || updated.gauge != current.gauge
            || updated.borderWidth != current.borderWidth || updated.anchor != current.anchor
            || updated.unfocusedDim != current.unfocusedDim
            || updated.appTheme != current.appTheme
        let recreates =
            updated.excludedApps != current.excludedApps || updated.order != current.order
        current = updated
        reconciler?.wake()

        if repaints { renderer.flushCache() }
        if !updated.active {
            for border in tracker.borders.values { border.hide() }
            return
        }
        if recreates {
            tracker.recreateAll()
            tracker.determineAndFocusActiveWindow()
            return
        }
        if repaints || !wasActive {
            tracker.redrawAll()
            tracker.determineAndFocusActiveWindow()
        }
    }
}
