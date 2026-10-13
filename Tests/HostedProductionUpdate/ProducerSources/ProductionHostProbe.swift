import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import IOKit.pwr_mgt
import Security

enum HostWorkerError: Error { case rejected }

@main
struct ProductionHostProbe {
    static let issuer = Data(base64Encoded: "__PRODUCTION_COHORT_ISSUER__")!
    static let sourceCommit = "__PRODUCTION_COHORT_SOURCE__"
    static let hostPath = "/Applications/Edith.app/Contents/MacOS/Edith"

    struct Role: Codable {
        let role: String
        let executable: String
        let codeHash: String
        let requirement: String
    }

    struct Scope: Codable {
        let sourceCommit: String
        let producerPID: Int32
        let producerGeneration: String
        let producerExecutable: String
        let producerCodeHash: String
        let uid: UInt32
        let accountHome: String
        let roles: [Role]
    }

    struct Envelope: Codable {
        let payload: String
        let signature: String
    }

    struct Identity: Codable, Equatable {
        let role: String
        let pid: Int32
        let generation: String
        let executable: String
        let codeHash: String
        let running: Bool
    }

    struct Request: Codable {
        let operation: String
        let scope: Envelope
        let observed: [Identity]
    }

    struct ActionResult: Codable {
        let performedAction: String
        let postActionOwners: [Identity]
    }

    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    @MainActor
    static func main() throws {
        if CommandLine.arguments == [CommandLine.arguments[0], "producer"] {
            let kernel = try HostRemoteKernelIdentity.read(getppid())
            let code = try HostRemoteProcessIdentity.read(getppid())
            guard try HostRemoteKernelIdentity.read(getppid()) == kernel else {
                throw HostWorkerError.rejected
            }
            let values: [String: String] = [
                "pid": String(kernel.pid), "generation": kernel.generation,
                "executable": kernel.executable.path,
                "codeHash": code.codeHash.map { String(format: "%02x", $0) }.joined(),
            ]
            FileHandle.standardOutput.write(try canonical(values))
            return
        }
        guard CommandLine.arguments.count == 1,
            let bytes = try FileHandle.standardInput.read(upToCount: 65_537),
            !bytes.isEmpty, bytes.count <= 65_536
        else { throw HostWorkerError.rejected }
        let request = try JSONDecoder().decode(Request.self, from: bytes)
        guard try canonical(request) == bytes,
            let payload = Data(base64Encoded: request.scope.payload), payload.count <= 32_768,
            let signature = Data(base64Encoded: request.scope.signature), signature.count == 64,
            try Curve25519.Signing.PublicKey(rawRepresentation: issuer).isValidSignature(
                signature, for: payload)
        else { throw HostWorkerError.rejected }
        let scope = try JSONDecoder().decode(Scope.self, from: payload)
        guard try canonical(scope) == payload, scope.sourceCommit == sourceCommit,
            scope.uid == getuid(), getuid() == getruid(), scope.roles.count <= 14,
            !scope.roles.isEmpty, scope.producerPID == getppid(),
            try HostRemoteKernelIdentity.read(scope.producerPID).generation
                == scope.producerGeneration,
            try HostRemoteProcessIdentity.read(scope.producerPID).executable.path
                == scope.producerExecutable,
            try HostRemoteProcessIdentity.read(scope.producerPID).codeHash.map({
                String(format: "%02x", $0)
            }).joined() == scope.producerCodeHash,
            let account = getpwuid(getuid()), let directory = account.pointee.pw_dir,
            scope.accountHome == String(cString: directory),
            ProcessInfo.processInfo.environment["HOME"] == scope.accountHome,
            scope.accountHome
                == URL(fileURLWithPath: scope.accountHome).resolvingSymlinksInPath().path,
            !ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("EDITH_") })
        else { throw HostWorkerError.rejected }
        let sparklePaths = [
            "sparkleAutoupdate": "Autoupdate",
            "sparkleUpdater": "Updater.app/Contents/MacOS/Updater",
            "sparkleDownloader": "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
            "sparkleInstaller": "XPCServices/Installer.xpc/Contents/MacOS/Installer",
        ]
        for role in scope.roles {
            let allowed: Bool
            if role.role == "host" || role.role == "engine" {
                allowed = role.executable == hostPath
            } else if role.role == "managedUI" {
                allowed = role.executable.hasPrefix(
                    scope.accountHome
                        + "/Library/Application Support/Edith/Extensions/keepAwake/edith-host-2/arm64/"
                )
            } else if let relative = sparklePaths[role.role] {
                allowed =
                    role.executable
                    == "/Applications/Edith.app/Contents/Frameworks/Sparkle.framework/"
                    + relative
            } else {
                allowed = false
            }
            guard allowed,
                role.executable
                    == URL(fileURLWithPath: role.executable).resolvingSymlinksInPath().path,
                role.codeHash.range(of: "^[a-f0-9]{40}$", options: .regularExpression) == role
                    .codeHash
                    .startIndex..<role.codeHash.endIndex
            else { throw HostWorkerError.rejected }
        }
        guard request.observed.count <= 12 else { throw HostWorkerError.rejected }
        let result: Data
        switch request.operation {
        case "snapshot":
            guard request.observed.isEmpty else { throw HostWorkerError.rejected }
            result = try canonical(snapshot(scope))
        case "observe":
            result = try canonical(request.observed.map { try observe($0, scope) })
        case "quit":
            guard request.observed.count == 1, request.observed[0].role == "host" else {
                throw HostWorkerError.rejected
            }
            let actual = try observe(request.observed[0], scope)
            guard actual.running,
                let application = NSRunningApplication(processIdentifier: actual.pid),
                application.bundleURL?.path == "/Applications/Edith.app",
                application.bundleIdentifier == "com.pulkit.edith", application.terminate()
            else { throw HostWorkerError.rejected }
            result = try canonical(actual)
        case "state":
            let host = try requireHost(request.observed, scope)
            var values: [String: String] = [:]
            for suite in ["com.pulkit.edith.host", "com.pulkit.edith.shared"] {
                let defaults = try savedDomain(suite, scope)
                for key in [
                    "surfaceGrid.home", "surfaceGrid.notch", "surfaceEditorTarget",
                    "surfaceEditorWidget",
                ] {
                    if let value = defaults[key] as? String {
                        guard value.utf8.count <= 1_048_576 else { throw HostWorkerError.rejected }
                        values[suite + ":" + key] = SHA256.hash(data: Data(value.utf8))
                            .map { String(format: "%02x", $0) }.joined()
                    }
                }
            }
            guard try observe(host, scope).running else { throw HostWorkerError.rejected }
            result = try canonical(values)
        case "assertions":
            let engine = try requireRole("engine", request.observed, scope)
            var processes: Unmanaged<CFDictionary>?
            guard IOPMCopyAssertionsByProcess(&processes) == kIOReturnSuccess,
                let dictionary = processes?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
            else { throw HostWorkerError.rejected }
            let rows = dictionary[NSNumber(value: engine.pid)] ?? []
            let count = rows.filter {
                $0[kIOPMAssertionNameKey as String] as? String == "Edith: Keep Awake is on"
                    && $0[kIOPMAssertionLevelKey as String] as? Int == kIOPMAssertionLevelOn
            }.count
            guard try observe(engine, scope).running else { throw HostWorkerError.rejected }
            result = try canonical(["engineAssertions": count])
        case "finishWelcome", "goHome", "widgetEditor", "home", "notch", "addKeep", "openEdithMenu",
            "checkUpdates", "installUpdate", "installRelaunch", "pressKeep":
            let host = try requireHost(request.observed, scope)
            let fixed: [String: (String, String, String?)] = [
                "finishWelcome": ("AXButton", "Start without extensions", nil),
                "goHome": ("AXButton", "Go to Home", nil),
                "widgetEditor": ("AXButton", "Widget editor", nil),
                "home": ("AXButton", "Home", nil),
                "notch": ("AXButton", "Notch", nil),
                "addKeep": ("AXButton", "Add Keep Awake", nil),
                "openEdithMenu": ("AXMenuBarItem", "Edith", nil),
                "checkUpdates": ("AXMenuItem", "Check for App Updates", nil),
                "installUpdate": ("AXButton", "Install Update", nil),
                "installRelaunch": ("AXButton", "Install and Relaunch", nil),
                "pressKeep": ("AXCheckBox", "Keep awake", "keepAwake.preventSleep"),
            ]
            guard let specification = fixed[request.operation] else {
                throw HostWorkerError.rejected
            }
            let deadline = DispatchTime.now() + 5
            var uiOwners = [host]
            if ["installUpdate", "installRelaunch"].contains(request.operation) {
                uiOwners += request.observed.filter { $0.role == "sparkleUpdater" && $0.running }
            }
            guard uiOwners.count <= 3 else { throw HostWorkerError.rejected }
            for peer in uiOwners {
                guard try observe(peer, scope).running else { throw HostWorkerError.rejected }
            }
            let control = try uniqueControl(uiOwners.map(\.pid), specification, deadline: deadline)
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds,
                AXUIElementSetMessagingTimeout(
                    control, Float(Double(deadline.uptimeNanoseconds - now) / 1_000_000_000)
                ) == .success
            else { throw HostWorkerError.rejected }
            var controlPID: pid_t = 0
            guard AXUIElementGetPid(control, &controlPID) == .success,
                request.observed.contains(where: { $0.pid == controlPID && $0.running }),
                let peer = request.observed.first(where: { $0.pid == controlPID }),
                try observe(peer, scope).running,
                DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds,
                AXUIElementPerformAction(control, kAXPressAction as CFString) == .success,
                DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds
            else { throw HostWorkerError.rejected }
            let owners = [try observe(peer, scope), try observe(host, scope)]
            guard request.operation == "installRelaunch" || owners.allSatisfy(\.running) else {
                throw HostWorkerError.rejected
            }
            result = try canonical(
                ActionResult(performedAction: request.operation, postActionOwners: owners))
        default:
            throw HostWorkerError.rejected
        }
        guard
            try HostRemoteKernelIdentity.read(scope.producerPID).generation
                == scope.producerGeneration
        else {
            throw HostWorkerError.rejected
        }
        FileHandle.standardOutput.write(result)
    }

    static func savedDomain(_ suite: String, _ scope: Scope) throws -> [String: Any] {
        guard ["com.pulkit.edith.host", "com.pulkit.edith.shared"].contains(suite) else {
            throw HostWorkerError.rejected
        }
        let path = scope.accountHome + "/Library/Preferences/" + suite + ".plist"
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else {
            throw HostWorkerError.rejected
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return [:] }
        guard descriptor >= 0 else { throw HostWorkerError.rejected }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
            before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
            before.st_mode & 0o022 == 0, before.st_size > 0, before.st_size <= 1_048_576
        else { throw HostWorkerError.rejected }
        var bytes = Data(count: Int(before.st_size) + 1)
        let count = try bytes.withUnsafeMutableBytes { pointer in
            var used = 0
            while used < pointer.count {
                let received = Darwin.read(
                    descriptor, pointer.baseAddress!.advanced(by: used), pointer.count - used)
                if received < 0, errno == EINTR { continue }
                guard received >= 0 else { throw HostWorkerError.rejected }
                if received == 0 { break }
                used += received
            }
            return used
        }
        var after = stat()
        var named = stat()
        guard count == Int(before.st_size), fstat(descriptor, &after) == 0,
            lstat(path, &named) == 0,
            sameFile(before, after), sameFile(before, named),
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
        else { throw HostWorkerError.rejected }
        bytes.count = count
        guard
            let value = try PropertyListSerialization.propertyList(
                from: bytes, options: [], format: nil)
                as? [String: Any]
        else {
            throw HostWorkerError.rejected
        }
        return value
    }

    static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
            && first.st_mode == second.st_mode && first.st_uid == second.st_uid
            && first.st_nlink == second.st_nlink && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    static func identity(_ pid: Int32, _ role: Role) throws -> Identity {
        let expected = URL(fileURLWithPath: role.executable)
        let peer = try HostRemoteProcessIdentity.read(pid)
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard peer.executable == expected,
            SecRequirementCreateWithString(role.requirement as CFString, [], &requirement)
                == errSecSuccess,
            let requirement,
            SecStaticCodeCreateWithPath(expected as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
                == errSecSuccess,
            peer.codeHash.map({ String(format: "%02x", $0) }).joined() == role.codeHash,
            try HostRemoteProcessIdentity.read(pid) == peer
        else { throw HostWorkerError.rejected }
        var signing: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
            let signing = signing as? [String: Any],
            let staticHash = signing[kSecCodeInfoUnique as String] as? Data,
            staticHash == peer.codeHash,
            try HostRemoteProcessIdentity.read(pid) == peer
        else { throw HostWorkerError.rejected }
        return Identity(
            role: role.role, pid: pid, generation: peer.generation,
            executable: role.executable, codeHash: role.codeHash, running: true)
    }

    static func snapshot(_ scope: Scope) throws -> [Identity] {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.pulkit.edith"
        ).filter { $0.bundleURL?.path == "/Applications/Edith.app" && !$0.isTerminated }
        guard applications.count <= 1 else { throw HostWorkerError.rejected }
        let hostPID = applications.first?.processIdentifier
        let count = proc_listallpids(nil, 0)
        guard count > 0, count < 65_000 else { throw HostWorkerError.rejected }
        var pids = [pid_t](repeating: 0, count: Int(count) + 256)
        let read = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard read > 0, read < pids.count else { throw HostWorkerError.rejected }
        var rows: [Identity] = []
        for pid in pids.prefix(Int(read)) where pid > 1 {
            guard let kernel = try? HostRemoteKernelIdentity.read(pid),
                scope.roles.contains(where: { $0.executable == kernel.executable.path })
            else { continue }
            let category: String
            if kernel.executable.path == hostPath {
                if pid == hostPID {
                    category = "host"
                } else {
                    var info = proc_bsdinfo()
                    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                    guard let hostPID,
                        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                        info.pbi_pid == pid, info.pbi_ppid == hostPID,
                        info.pbi_uid == getuid(), info.pbi_ruid == getuid(),
                        "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)" == kernel.generation,
                        try HostRemoteKernelIdentity.read(pid) == kernel
                    else { throw HostWorkerError.rejected }
                    category = "engine"
                }
            } else if kernel.executable.path.hasPrefix(
                "/Applications/Edith.app/Contents/Frameworks/Sparkle.framework/")
            {
                let categories = Set(
                    scope.roles.filter { $0.executable == kernel.executable.path }.map(\.role))
                guard categories.count == 1, let role = categories.first else {
                    throw HostWorkerError.rejected
                }
                category = role
            } else {
                category = "managedUI"
            }
            let live = try HostRemoteProcessIdentity.read(pid)
            let hash = live.codeHash.map { String(format: "%02x", $0) }.joined()
            let candidates = scope.roles.filter {
                $0.role == category && $0.executable == kernel.executable.path
                    && $0.codeHash == hash
            }
            guard candidates.count == 1, let role = candidates.first,
                try HostRemoteKernelIdentity.read(pid) == kernel
            else { throw HostWorkerError.rejected }
            rows.append(try identity(pid, role))
        }
        guard rows.count <= 12 else { throw HostWorkerError.rejected }
        return rows
    }

    static func observe(_ expected: Identity, _ scope: Scope) throws -> Identity {
        guard
            let role = scope.roles.first(where: {
                $0.role == expected.role && $0.executable == expected.executable
                    && $0.codeHash == expected.codeHash
            })
        else { throw HostWorkerError.rejected }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 1, &info, size)
        if result == 0, errno == ESRCH {
            return Identity(
                role: expected.role, pid: expected.pid, generation: expected.generation,
                executable: expected.executable, codeHash: expected.codeHash, running: false)
        }
        guard result == size, info.pbi_pid == expected.pid, info.pbi_uid == getuid(),
            info.pbi_ruid == getuid()
        else {
            throw HostWorkerError.rejected
        }
        let generation = "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
        guard generation == expected.generation else { throw HostWorkerError.rejected }
        if info.pbi_status == SZOMB {
            return Identity(
                role: expected.role, pid: expected.pid, generation: expected.generation,
                executable: expected.executable, codeHash: expected.codeHash, running: false)
        }
        guard try identity(expected.pid, role) == expected else { throw HostWorkerError.rejected }
        return expected
    }

    static func requireRole(_ role: String, _ rows: [Identity], _ scope: Scope) throws -> Identity {
        let matches = rows.filter { $0.role == role && $0.running }
        guard matches.count == 1, let row = matches.first, try observe(row, scope).running else {
            throw HostWorkerError.rejected
        }
        return row
    }

    static func requireHost(_ rows: [Identity], _ scope: Scope) throws -> Identity {
        try requireRole("host", rows, scope)
    }

    static func uniqueControl(
        _ pids: [Int32], _ specification: (String, String, String?), deadline: DispatchTime
    ) throws
        -> AXUIElement
    {
        guard !pids.isEmpty, pids.count <= 3, Set(pids).count == pids.count else {
            throw HostWorkerError.rejected
        }
        var pending = pids.map { AXUIElementCreateApplication($0) }
        var matches: [AXUIElement] = []
        var examined = 0
        while let element = pending.popLast() {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else {
                throw HostWorkerError.rejected
            }
            let remaining =
                Double(deadline.uptimeNanoseconds - now)
                / 1_000_000_000
            guard AXUIElementSetMessagingTimeout(element, Float(remaining)) == .success else {
                throw HostWorkerError.rejected
            }
            examined += 1
            guard examined <= 4096 else { throw HostWorkerError.rejected }
            var role: CFTypeRef?
            var title: CFTypeRef?
            var identifier: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier)
            if role as? String == specification.0, title as? String == specification.1,
                specification.2 == nil || identifier as? String == specification.2
            {
                matches.append(element)
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                == .success,
                let values = children as? [AXUIElement]
            {
                guard values.count <= 4096 - examined - pending.count else {
                    throw HostWorkerError.rejected
                }
                pending.append(contentsOf: values)
            }
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds, matches.count == 1,
            let control = matches.first
        else {
            throw HostWorkerError.rejected
        }
        return control
    }
}
