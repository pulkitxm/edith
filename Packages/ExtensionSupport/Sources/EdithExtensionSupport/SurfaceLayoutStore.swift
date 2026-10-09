import Foundation
import Observation

@MainActor
@Observable
public final class SurfaceLayoutStore {
    public private(set) var home: SurfaceLayout
    public private(set) var notch: SurfaceLayout
    public private(set) var profiles: [SurfaceLayoutProfile] = []
    private var profilesByTarget: [SurfaceTarget: [SurfaceLayoutProfile]] = [:]
    private var deletedProfiles: [SurfaceTarget: SurfaceLayoutProfile] = [:]
    private let defaults: UserDefaults
    private let changed: () -> Void
    private var undoHistory: [SurfaceTarget: [SurfaceLayout]] = [:]
    private var redoHistory: [SurfaceTarget: [SurfaceLayout]] = [:]

    public init(defaults: UserDefaults, changed: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.changed = changed
        let loadedProfiles = Self.loadProfiles(defaults)
        profiles = loadedProfiles
        profilesByTarget = Self.groupProfiles(loadedProfiles)
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

    public func profiles(_ target: SurfaceTarget) -> [SurfaceLayoutProfile] {
        profilesByTarget[target] ?? []
    }
    public func canRestoreProfile(_ target: SurfaceTarget) -> Bool {
        deletedProfiles[target] != nil
    }
    @discardableResult
    public func saveProfile(_ name: String, target: SurfaceTarget, replacing id: UUID? = nil)
        -> Bool
    {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        guard !clean.isEmpty,
            !profiles(target).contains(where: {
                $0.id != id && $0.name.caseInsensitiveCompare(clean) == .orderedSame
            }),
            id != nil || profiles(target).count < 20
        else { return false }
        var next = profiles
        if let id {
            guard let index = next.firstIndex(where: { $0.id == id && $0.target == target }) else {
                return false
            }
            next[index].name = clean
            next[index].layout = layout(target)
        } else {
            next.append(.init(name: clean, target: target, layout: layout(target)))
        }
        return writeProfiles(next)
    }
    @discardableResult
    public func renameProfile(_ id: UUID, name: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        guard !clean.isEmpty,
            !profiles(profiles[index].target).contains(where: {
                $0.id != id && $0.name.caseInsensitiveCompare(clean) == .orderedSame
            })
        else { return false }
        var next = profiles
        next[index].name = clean
        return writeProfiles(next)
    }
    public func applyProfile(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        update(profile.target) { $0 = profile.layout }
    }
    public func removeProfile(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        if writeProfiles(profiles.filter { $0.id != id }) {
            deletedProfiles[profile.target] = profile
        }
    }
    @discardableResult
    public func restoreProfile(_ target: SurfaceTarget) -> Bool {
        guard let profile = deletedProfiles[target], profiles(target).count < 20,
            !profiles.contains(where: {
                $0.id == profile.id
                    || ($0.target == target
                        && $0.name.caseInsensitiveCompare(profile.name) == .orderedSame)
            })
        else { return false }
        guard writeProfiles(profiles + [profile]) else { return false }
        deletedProfiles[target] = nil
        return true
    }
    private func writeProfiles(_ next: [SurfaceLayoutProfile]) -> Bool {
        guard let data = try? JSONEncoder().encode(next), data.count <= 1_048_576,
            let raw = String(data: data, encoding: .utf8)
        else { return false }
        defaults.set(raw, forKey: "surfaceLayoutProfiles")
        profiles = next
        profilesByTarget = Self.groupProfiles(next)
        changed()
        return true
    }
    private nonisolated static func groupProfiles(_ profiles: [SurfaceLayoutProfile])
        -> [SurfaceTarget: [SurfaceLayoutProfile]]
    {
        var grouped = Dictionary(grouping: profiles.prefix(40), by: \.target)
        for target in SurfaceTarget.allCases {
            grouped[target]?.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return grouped
    }
    private static func loadProfiles(_ defaults: UserDefaults) -> [SurfaceLayoutProfile] {
        guard let raw = defaults.string(forKey: "surfaceLayoutProfiles"),
            let data = raw.data(using: .utf8), data.count <= 1_048_576,
            let values = try? JSONDecoder().decode([SurfaceLayoutProfile].self, from: data)
        else { return [] }
        var seen = Set<UUID>()
        var counts: [SurfaceTarget: Int] = [:]
        return values.prefix(40).compactMap {
            guard seen.insert($0.id).inserted, counts[$0.target, default: 0] < 20 else {
                return nil
            }
            let value = SurfaceLayoutProfile(
                id: $0.id, name: $0.name, target: $0.target, layout: $0.layout)
            guard !value.name.isEmpty else { return nil }
            counts[$0.target, default: 0] += 1
            return value
        }
    }

    public func reload() {
        let nextProfiles = Self.loadProfiles(defaults)
        if profiles != nextProfiles {
            profiles = nextProfiles
            profilesByTarget = Self.groupProfiles(nextProfiles)
        }

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
        changed()
    }
}
