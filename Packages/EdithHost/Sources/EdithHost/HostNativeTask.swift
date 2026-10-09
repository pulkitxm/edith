import Darwin
import EdithHostCore
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

@MainActor enum HostNativeTask {
    static func run(encoded: String) throws -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard ExtensionCommandOwnership.isWorker,
            let parentText = environment["EDITH_EXTENSION_NATIVE_PARENT"],
            let parent = Int32(parentText), parent > 1,
            sameExecutable(parent), descended(from: parent),
            let context = environment["EDITH_EXTENSION_NATIVE_CONTEXT"],
            context.utf8.count <= 16_384,
            let configurationBytes = Data(base64Encoded: context),
            encoded.utf8.count <= 87_384, let payload = Data(base64Encoded: encoded),
            !payload.isEmpty, payload.count <= 65_536
        else { throw HostWorkerError.rejected }
        guard setpgid(0, 0) == 0 || getpgrp() == getpid() else { throw HostWorkerError.rejected }
        let supplied = try JSONDecoder().decode(
            HostWorkerConfiguration.self, from: configurationBytes)
        let authoritative = try ExtensionNativeTaskAuthorization.request(parent: parent)
        let next = try JSONDecoder().decode(HostWorkerConfiguration.self, from: authoritative)
        guard supplied.identifier == next.identifier, supplied.extensionID == next.extensionID,
            supplied.version == next.version, supplied.supportDirectory == next.supportDirectory
        else {
            throw HostWorkerError.rejected
        }
        guard next.identifier == Bundle.main.bundleIdentifier,
            environment["EDITH_EXTENSION_ID"] == next.extensionID,
            try HostIndex.bundled().contains(where: { $0.id == next.extensionID })
        else { throw HostWorkerError.rejected }
        let identity = try next.identity()
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        setenv("EDITH_APPLICATION_IDENTIFIER", identity.identifier, 1)
        setenv("EDITH_EXTENSION_DATA_ROOT", identity.extensionDirectory(next.extensionID).path, 1)
        setenv(
            "EDITH_EXTENSION_STATE_ROOT",
            identity.root.appendingPathComponent("ExtensionState").path, 1)
        setenv("EDITH_SHARED_DEFAULTS_SUITE", identity.extensionDefaultsSuite(next.extensionID), 1)
        setenv("EDITH_SURFACE_DEFAULTS_SUITE", identity.identifier, 1)
        let team = ExtensionCodeSignature.teamIdentifier()
        guard identity.development || team != nil else { throw MarketplaceError.invalidSignature }
        let runtime = ExtensionBundleRuntime(
            store: store, role: .app, hostABI: HostContract.compatibility,
            packageVersion: next.version,
            verify: { url in
                if identity.development {
                    try ExtensionCodeSignature.verifyDevelopment(url)
                } else {
                    guard let team else { throw MarketplaceError.invalidSignature }
                    try ExtensionCodeSignature.verify(url, teamIdentifier: team)
                }
            })
        let groups = ExtensionNativeTaskGroups()
        let terminate: @Sendable () -> Void = {
            groups.terminate()
            kill(-getpid(), SIGKILL)
        }
        var signals: [DispatchSourceSignal] = []
        for value in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
            source.setEventHandler(handler: terminate)
            source.activate()
            signals.append(source)
        }
        let watcher = DispatchSource.makeProcessSource(
            identifier: parent, eventMask: .exit, queue: .global())
        watcher.setEventHandler(handler: terminate)
        watcher.resume()
        let direct = DispatchSource.makeProcessSource(
            identifier: getppid(), eventMask: .exit, queue: .global())
        direct.setEventHandler(handler: terminate)
        direct.activate()
        defer {
            groups.terminate()
            watcher.cancel(); direct.cancel()
            for source in signals { source.cancel() }
        }
        guard sameExecutable(parent), descended(from: parent) else {
            throw HostWorkerError.rejected
        }
        return try runtime.nativeTask(id: next.extensionID, payload: payload)
    }

    static func sameExecutable(_ pid: Int32) -> Bool {
        func path(_ pid: Int32) -> String? {
            var bytes = [CChar](repeating: 0, count: 4_096)
            guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
            return String(cString: bytes)
        }
        guard let current = path(getpid()) else { return false }
        return path(pid) == current
    }

    private static func descended(from parent: Int32) -> Bool {
        var next = getppid()
        for _ in 0..<8 {
            if next == parent { return true }
            guard next > 1 else { return false }
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            guard proc_pidinfo(next, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else {
                return false
            }
            next = Int32(info.pbi_ppid)
        }
        return false
    }
}
