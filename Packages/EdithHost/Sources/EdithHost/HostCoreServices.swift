import AppKit
import EdithExtensionSupport
import EdithHostCore
import Observation
import SwiftUI

@MainActor @Observable final class HostCoreServices {
    let identity: HostIdentity
    let marketplace: HostMarketplace
    let defaults: UserDefaults
    private(set) var snapshot: HostCoreSnapshot?
    private(set) var failure: String?
    private(set) var panelFailure: String?
    private(set) var starting = false
    private(set) var inspecting = false
    private(set) var cpuPercent = 0.0
    @ObservationIgnored private var process: HostCoreProcess?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private let executable: URL
    @ObservationIgnored private let panel: HostPanelService

    init(
        identity: HostIdentity, marketplace: HostMarketplace,
        executable: URL? = Bundle.main.executableURL, togglePanel: @escaping @MainActor () -> Void
    ) throws {
        guard let executable else { throw CocoaError(.fileNoSuchFile) }
        self.identity = identity
        self.marketplace = marketplace
        defaults = marketplace.surfaces.preferences
        self.executable = executable
        panel = HostPanelService(defaults: defaults, action: togglePanel)
    }

    var online: Bool { process?.ready == true && process?.processIdentifier == snapshot?.pid }
    var activeTaskCount: Int { snapshot?.tasks.filter { $0.phase == .running }.count ?? 0 }
    var activityLabel: String {
        if failure != nil { return "Unavailable" }
        if starting { return "Starting" }
        guard online else { return "Offline" }
        return activeTaskCount > 0 ? "\(activeTaskCount) active" : "Idle"
    }

    func start() async {
        guard !starting, process == nil else { return }
        starting = true
        defer { starting = false }
        NSApp.setActivationPolicy(
            defaults.object(forKey: AppStorageKeys.General.showDockIcon) as? Bool ?? true
                ? .regular : .accessory)
        panelShortcutChanged()
        let process = HostCoreProcess(identity: identity, executable: executable)
        self.process = process
        do {
            update(try await process.start())
            failure = nil
            observation = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self else { return }
                    await self.refresh()
                }
            }
        } catch {
            await process.stop()
            self.process = nil
            failure = "The background service could not start. Try restarting it."
        }
    }

    func refresh() async {
        guard let process, process.ready else { return }
        do { update(try await process.perform(.status)); failure = nil } catch is CancellationError
        {} catch { failure = "The background service could not be reached. Try restarting it." }
    }

    func inspectStorage() async {
        guard !inspecting, let process, process.ready else { return }
        inspecting = true
        defer { inspecting = false }
        do { update(try await process.perform(.inspect)); failure = nil } catch is CancellationError
        {} catch { failure = "Storage could not be inspected. Reload to try again." }
    }

    func cancelTask(_ id: UUID) {
        guard snapshot?.tasks.contains(where: { $0.id == id && $0.phase == .running }) == true
        else { return }
        process?.cancelCurrentTask()
    }

    func restart() async { await shutdown(); await start() }

    func shutdown() async {
        observation?.cancel()
        await observation?.value
        observation = nil
        panel.shutdown()
        await process?.stop()
        process = nil
        snapshot = nil
        cpuPercent = 0
    }

    func panelShortcutChanged() {
        do { try panel.install(); panelFailure = nil } catch {
            panelFailure = "The panel shortcut could not be registered. Choose another shortcut."
        }
    }

    func copyLogCommand() {
        let value =
            "/usr/bin/log show --last 10m --predicate 'subsystem == \"\(identity.identifier)\"'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func settings(_ category: String) -> AnyView? {
        switch category {
        case "agent": AnyView(HostBackgroundPage(services: self))
        case "data": AnyView(HostDataPage(services: self))
        default: nil
        }
    }

    private func update(_ next: HostCoreSnapshot) {
        if let previous = snapshot, previous.pid == next.pid {
            let elapsed = next.collectedAt.timeIntervalSince(previous.collectedAt)
            if elapsed > 0 {
                cpuPercent = max(0, (next.cpuSeconds - previous.cpuSeconds) / elapsed * 100)
            }
        } else {
            cpuPercent = 0
        }
        snapshot = next
    }
}
