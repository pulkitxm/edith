import EdithExtensionSupport
import EdithHostCore
import Foundation
import Observation

struct HostUtilityConfirmation: Identifiable {
    let id = UUID()
    let utility: HostSidebarUtility
    let action: SurfaceAction
    let snapshot: SurfaceSnapshot
    let version: String
}

@MainActor @Observable final class HostUtilityActions {
    var snapshots: [String: SurfaceSnapshot] = [:]
    var pendingKeepAwake: Bool?
    var lidAwakeError: String?
    var confirmation: HostUtilityConfirmation?
    var refreshTick = 0
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var actionToken: UUID?

    func isOn(_ utility: HostSidebarUtility, preventSleep: Bool) -> Bool {
        if utility == .keepAwake { return pendingKeepAwake ?? preventSleep }
        return utility.isOn(snapshots[utility.id])
    }

    func clear() {
        actionTask?.cancel(); actionTask = nil; actionToken = nil
        snapshots.removeAll(); pendingKeepAwake = nil; confirmation = nil
    }

    func poll(
        utilities: [HostSidebarUtility], marketplace: HostMarketplace, tile: SurfaceTile,
        versions: @MainActor () -> [String: String]
    ) async {
        repeat {
            for utility in utilities {
                let version = versions()[utility.id]
                do {
                    let snapshot = try await marketplace.surfaces.requests.snapshot(
                        providerID: utility.id, target: .home, tile: tile)
                    guard !Task.isCancelled, versions()[utility.id] == version else { return }
                    snapshots[utility.id] = snapshot
                } catch {
                    guard !Task.isCancelled else { return }
                    snapshots[utility.id] = nil
                }
            }
            let tick = refreshTick
            for _ in 0..<20 where refreshTick == tick {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        } while !Task.isCancelled
    }

    func perform(
        _ utility: HostSidebarUtility, marketplace: HostMarketplace, tile: SurfaceTile,
        version: String, preventSleep: Bool, current: @escaping @MainActor () -> String?
    ) {
        guard actionTask == nil else { return }
        if utility == .keepAwake {
            let wanted = !preventSleep
            pendingKeepAwake = wanted
            let snapshot = SurfaceSnapshot(
                providerID: utility.id,
                actions: [.init(wanted ? "enable" : "disable", utility.title, utility.icon)])
            run(
                utility, action: snapshot.actions[0], snapshot: snapshot,
                marketplace: marketplace, tile: tile, version: version, current: current)
            return
        }
        let token = UUID(); actionToken = token
        actionTask = Task {
            defer { if actionToken == token { actionTask = nil; actionToken = nil } }
            do {
                let snapshot = try await marketplace.surfaces.requests.snapshot(
                    providerID: utility.id, target: .home, tile: tile)
                guard !Task.isCancelled, actionToken == token, current() == version,
                    let action = utility.action(in: snapshot)
                else { return }
                if action.confirmation != nil {
                    confirmation = HostUtilityConfirmation(
                        utility: utility, action: action, snapshot: snapshot, version: version)
                    return
                }
                actionTask = nil; actionToken = nil
                run(
                    utility, action: action, snapshot: snapshot, marketplace: marketplace,
                    tile: tile, version: version, current: current)
            } catch {
                guard !Task.isCancelled, actionToken == token else { return }
                report(utility, error)
            }
        }
    }

    func run(
        _ utility: HostSidebarUtility, action: SurfaceAction, snapshot: SurfaceSnapshot,
        marketplace: HostMarketplace, tile: SurfaceTile, version: String,
        current: @escaping @MainActor () -> String?
    ) {
        guard actionTask == nil, current() == version else {
            pendingKeepAwake = nil
            return
        }
        let token = UUID(); actionToken = token
        actionTask = Task {
            defer {
                if actionToken == token { actionTask = nil; actionToken = nil }
                if utility == .keepAwake { pendingKeepAwake = nil }
            }
            do {
                let result = try await marketplace.surfaces.requests.perform(
                    providerID: utility.id, target: .home, tile: tile, snapshot: snapshot,
                    actionID: action.id)
                guard !Task.isCancelled, actionToken == token, current() == version else {
                    return
                }
                snapshots[utility.id] = result
                if utility == .lidAwake, let message = result.message { lidAwakeError = message }
            } catch {
                guard !Task.isCancelled, actionToken == token else { return }
                report(utility, error)
            }
        }
    }

    private func report(_ utility: HostSidebarUtility, _ error: Error) {
        guard utility == .lidAwake else { return }
        lidAwakeError = error.localizedDescription
    }
}
