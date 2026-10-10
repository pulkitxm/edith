import AppKit
import Darwin
import ExtensionFoundation
import ExtensionKit
import Foundation

@MainActor
func awaitHostedManagedApproval(
    directory: URL, hostIdentifier: String, extensionID: String, workerIdentifier: String
) async throws -> HostedManagedApprovalReceipt {
    let route = try HostedManagedApprovalRoute.load(
        directory: directory, environment: ProcessInfo.processInfo.environment)
    guard route.hostIdentifier == hostIdentifier, route.extensionID == extensionID,
        route.workerIdentifier == workerIdentifier
    else { throw HostedManagedApprovalError.invalidRoute }
    try route.validateHostedDirectory()
    let application = Bundle.main
    try route.validateApplicationPaths(
        bundle: application.bundleURL, executable: application.executableURL)
    let descriptorDirectory = application.bundleURL.appendingPathComponent("Contents/Extensions")
    let descriptorBytes = try HostedManagedApprovalRoute.readOwned(
        directory: descriptorDirectory, name: "ExtensionUI.appextensionpoints", maximumBytes: 65_536
    )
    guard
        let descriptor = try PropertyListSerialization.propertyList(
            from: descriptorBytes, format: nil) as? [String: Any]
    else { throw HostedManagedApprovalError.invalidApplication }
    try route.validateApplication(identifier: application.bundleIdentifier, descriptor: descriptor)
    let host = try HostedManagedApprovalHost(route: route)
    return try await host.run()
}

@MainActor
private final class HostedManagedApprovalHost: NSObject, NSWindowDelegate {
    private let route: HostedManagedApprovalRoute
    private let generation: String
    private var window: NSWindow?
    private var browser: EXAppExtensionBrowserViewController?
    private var observation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var continuation: CheckedContinuation<HostedManagedApprovalReceipt, any Error>?
    private var presented = false
    private var originalActivationPolicy: NSApplication.ActivationPolicy?

    init(route: HostedManagedApprovalRoute) throws {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
            info.pbi_uid == getuid()
        else { throw HostedManagedApprovalError.invalidApplication }
        self.route = route
        generation = "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
        super.init()
    }

    func run() async throws -> HostedManagedApprovalReceipt {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let point = route.extensionPoint
                observation = Task { [weak self] in
                    do {
                        let identities = try AppExtensionIdentity.matching(
                            appExtensionPointIDs: point)
                        for await values in identities {
                            guard !Task.isCancelled, let self else { return }
                            if try self.observe(values) { return }
                        }
                        if !Task.isCancelled {
                            self?.finish(.failure(HostedManagedApprovalError.ambiguousIdentity))
                        }
                    } catch {
                        if !Task.isCancelled {
                            self?.finish(.failure(HostedManagedApprovalError.ambiguousIdentity))
                        }
                    }
                }
                deadline = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(90))
                        self?.finish(.failure(HostedManagedApprovalError.timedOut))
                    } catch {}
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func observe(_ identities: [AppExtensionIdentity]) throws -> Bool {
        let matched = try route.validateIdentities(
            identities.map {
                HostedManagedApprovalIdentity(
                    identifier: $0.id, workerIdentifier: $0.bundleIdentifier,
                    extensionPoint: $0.extensionPointIdentifier, label: $0.localizedName)
            })
        if matched != nil {
            finish(.success(()))
            return true
        }
        if !presented { try presentBrowser() }
        return false
    }

    private func presentBrowser() throws {
        guard NSApp.activationPolicy() == .prohibited else {
            throw HostedManagedApprovalError.invalidApplication
        }
        originalActivationPolicy = NSApp.activationPolicy()
        guard NSApp.setActivationPolicy(.regular) else {
            throw HostedManagedApprovalError.invalidApplication
        }
        let browser = EXAppExtensionBrowserViewController()
        let root = NSViewController()
        root.view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        root.addChild(browser)
        browser.view.frame = root.view.bounds
        browser.view.autoresizingMask = [.width, .height]
        root.view.addSubview(browser.view)
        let window = NSWindow(
            contentRect: root.view.bounds, styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = route.windowTitle
        window.contentViewController = root
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        self.browser = browser
        presented = true
        try write(
            receipt(outcome: "ready", discovered: false, closed: false), name: "approval-ready.json"
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        finish(.failure(HostedManagedApprovalError.windowClosed))
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        observation?.cancel()
        observation = nil
        deadline?.cancel()
        deadline = nil
        window?.delegate = nil
        window?.close()
        let closed = window?.isVisible != true
        browser?.view.removeFromSuperview()
        browser?.removeFromParent()
        window?.contentViewController = nil
        browser = nil
        window = nil
        var restored = NSApp.activationPolicy() == .prohibited
        if let originalActivationPolicy {
            restored =
                NSApp.setActivationPolicy(originalActivationPolicy)
                && NSApp.activationPolicy() == originalActivationPolicy
            self.originalActivationPolicy = nil
        }
        do {
            let discovered = if case .success = result { true } else { false }
            let receipt = receipt(
                outcome: discovered ? "approved" : "failed", discovered: discovered, closed: closed)
            try write(receipt, name: "approval-result.json")
            try result.get()
            guard closed else { throw HostedManagedApprovalError.windowClosed }
            guard restored else { throw HostedManagedApprovalError.invalidApplication }
            continuation.resume(returning: receipt)
        } catch { continuation.resume(throwing: error) }
    }

    private func receipt(outcome: String, discovered: Bool, closed: Bool)
        -> HostedManagedApprovalReceipt
    {
        HostedManagedApprovalReceipt(
            schema: 1, sourceCommit: route.sourceCommit, extensionID: route.extensionID,
            selectedVersion: route.version, hostABI: route.hostABI,
            sourceFingerprint: route.sourceFingerprint, packageSHA256: route.packageSHA256,
            hostIdentifier: route.hostIdentifier, workerIdentifier: route.workerIdentifier,
            extensionPointIdentifier: route.extensionPoint, expectedLabel: route.expectedLabel,
            hostPID: getpid(), hostGeneration: generation, outcome: outcome,
            publicBrowser: presented, publicDiscovery: discovered, ownedBrowserClosed: closed,
            activationPolicyRestored: NSApp.activationPolicy() == .prohibited,
            managedViewReady: false)
    }

    private func write(_ receipt: HostedManagedApprovalReceipt, name: String) throws {
        let bytes = try JSONEncoder().encode(receipt)
        guard bytes.count <= 16_384 else { throw HostedManagedApprovalError.invalidRoute }
        let root = open(route.directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw HostedManagedApprovalError.invalidRoute }
        defer { close(root) }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700
        else {
            throw HostedManagedApprovalError.invalidRoute
        }
        let temporary = ".approval-" + UUID().uuidString
        let descriptor = openat(root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HostedManagedApprovalError.invalidRoute }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(root, temporary, 0) }
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        guard linkat(root, temporary, root, name, 0) == 0 else {
            throw HostedManagedApprovalError.invalidRoute
        }
    }
}
