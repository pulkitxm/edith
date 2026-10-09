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
        let next = try JSONDecoder().decode(HostWorkerConfiguration.self, from: configurationBytes)
        guard next.identifier == Bundle.main.bundleIdentifier,
            environment["EDITH_EXTENSION_ID"] == next.extensionID,
            try HostIndex.bundled().contains(where: { $0.id == next.extensionID })
        else { throw HostWorkerError.rejected }
        let identity = try next.identity()
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
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
        let watcher = DispatchSource.makeProcessSource(
            identifier: parent, eventMask: .exit, queue: .global())
        watcher.setEventHandler { kill(getpid(), SIGTERM) }
        watcher.resume()
        defer { watcher.cancel() }
        return try runtime.nativeTask(id: next.extensionID, payload: payload)
    }

    private static func sameExecutable(_ pid: Int32) -> Bool {
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
