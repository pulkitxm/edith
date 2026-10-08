import Foundation
import Observation

@MainActor
@Observable
public final class SurfaceLayoutStore {
    public static let shared = SurfaceLayoutStore()
    public private(set) var home: SurfaceLayout
    public private(set) var notch: SurfaceLayout
    private let defaults: UserDefaults
    private var undoHistory: [SurfaceTarget: [SurfaceLayout]] = [:]
    private var redoHistory: [SurfaceTarget: [SurfaceLayout]] = [:]

    public init(defaults: UserDefaults = SharedDefaults.store) {
        self.defaults = defaults
        home = SurfaceLayout.decode(defaults.string(forKey: SurfaceTarget.home.key), target: .home)
        notch = SurfaceLayout.decode(
            defaults.string(forKey: SurfaceTarget.notch.key), target: .notch)
    }

    public func layout(_ target: SurfaceTarget) -> SurfaceLayout { target == .home ? home : notch }
    public func canUndo(_ target: SurfaceTarget) -> Bool { !(undoHistory[target] ?? []).isEmpty }
    public func canRedo(_ target: SurfaceTarget) -> Bool { !(redoHistory[target] ?? []).isEmpty }

    public func update(_ target: SurfaceTarget, _ edit: (inout SurfaceLayout) -> Void) {
        let previous = layout(target)
        var next = previous
        edit(&next)
        next = next.normalized()
        guard next != previous else { return }
        undoHistory[target] = Array(((undoHistory[target] ?? []) + [previous]).suffix(50))
        redoHistory[target] = []
        save(next, target: target)
    }

    public func undo(_ target: SurfaceTarget) {
        guard let previous = undoHistory[target]?.popLast() else { return }
        redoHistory[target, default: []].append(layout(target))
        save(previous, target: target)
    }

    public func redo(_ target: SurfaceTarget) {
        guard let next = redoHistory[target]?.popLast() else { return }
        undoHistory[target, default: []].append(layout(target))
        save(next, target: target)
    }

    public func reload() {
        for target in SurfaceTarget.allCases {
            let next = SurfaceLayout.decode(defaults.string(forKey: target.key), target: target)
            if next != layout(target) {
                assign(next, target: target)
                undoHistory[target] = []
                redoHistory[target] = []
            }
        }
    }

    private func assign(_ layout: SurfaceLayout, target: SurfaceTarget) {
        if target == .home { home = layout } else { notch = layout }
    }

    private func save(_ layout: SurfaceLayout, target: SurfaceTarget) {
        defaults.set(layout.encoded, forKey: target.key)
        assign(layout, target: target)
        IPC.post(IPC.Name.settingsChanged)
    }
}
