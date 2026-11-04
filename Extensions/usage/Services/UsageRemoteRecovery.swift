import AppKit
import EdithExtensionSupport
import Foundation
import Network

@MainActor public enum UsageRemoteRecovery {
    public static func machinesVersion() -> String? {
        guard let context = SurfaceHostContext.current, context.activeIDs.contains("machines")
        else { return nil }
        return context.activeVersions["machines"] ?? "active"
    }

    public static func machinesNeedRecovery(
        registry: [Machine] = MachineRegistry.machines(), directory: URL = Repo.dataDir,
        defaults: UserDefaults = SharedDefaults.store, now: Date = Date()
    ) -> Bool {
        let machines = UsageMachinesPeer.selectedRemoteMachines(
            registry: registry, directory: directory, defaults: defaults)
        guard !machines.isEmpty else { return false }
        return UsageMachineRefreshLedger.needsRecovery(machines.map(\.id), directory: directory)
            || machines.contains { UsageMachinesPeer.isDue($0, directory: directory, now: now) }
    }
}

@MainActor final class UsageRecoveryTriggers {
    private var wakeObserver: NSObjectProtocol?
    private var monitor: NWPathMonitor?

    init(
        woke: @escaping @MainActor () -> Void,
        networkReturned: @escaping @MainActor () -> Void
    ) {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { woke() }
        }
        let monitor = NWPathMonitor()
        let reachability = Reachability(returned: networkReturned)
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            MainActor.assumeIsolated { reachability.update(satisfied) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    @MainActor private final class Reachability {
        private var satisfied: Bool?
        private let returned: @MainActor () -> Void
        init(returned: @escaping @MainActor () -> Void) { self.returned = returned }
        func update(_ now: Bool) {
            defer { satisfied = now }
            if now, satisfied == false { returned() }
        }
    }

    func stop() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        monitor?.cancel()
        monitor = nil
    }
}
