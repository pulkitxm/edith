import AppKit
import CryptoKit
import ExtensionFoundation
import ExtensionKit
import Foundation

@MainActor
final class HostedManagedApprovalProbe: NSObject, NSApplicationDelegate {
    private let fixture: ProbeFixture
    private var window: NSWindow?
    private var browser: EXAppExtensionBrowserViewController?
    private var observation: Task<Void, Never>?

    static func run(directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("fixture.json"))
        guard data.count <= 16_384 else { throw ProbeContractError.invalidFixture }
        let fixture = try JSONDecoder().decode(ProbeFixture.self, from: data)
        try fixture.validate(
            home: ProbeRunner.accountHome(),
            environment: ProcessInfo.processInfo.environment)
        guard directory.path == fixture.directory,
            directory.resolvingSymlinksInPath().path == directory.path,
            Bundle.main.bundleIdentifier == fixture.identifier,
            Bundle.main.bundleURL.path == fixture.app,
            Bundle.main.executableURL?.path == fixture.executable,
            SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: fixture.executable)))
                .map({ String(format: "%02x", $0) }).joined() == fixture.hostExecutableSHA256
        else { throw ProbeContractError.invalidFixture }
        for path in [fixture.app, fixture.executable, fixture.carrier, fixture.worker] {
            guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else {
                throw ProbeContractError.invalidFixture
            }
        }
        let delegate = HostedManagedApprovalProbe(fixture: fixture)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    private init(fixture: ProbeFixture) { self.fixture = fixture }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--extension-ui-carrier"]
        configuration.activates = false
        configuration.hides = true
        configuration.createsNewApplicationInstance = true
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: fixture.carrier), configuration: configuration
        ) { [weak self] application, error in
            Task { @MainActor in
                guard let self else { return }
                guard application != nil, error == nil else {
                    self.write(
                        "approval-failure.json", ["outcome": "failed", "stage": "carrier-check-in"])
                    NSApp.terminate(nil)
                    return
                }
                self.presentBrowser()
            }
        }
    }

    private func presentBrowser() {
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
        window.title = "Managed Calendar Approval \(fixture.identifier)"
        window.contentViewController = root
        window.isReleasedWhenClosed = false
        self.window = window
        self.browser = browser
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        write(
            "approval-ready.json",
            [
                "hostIdentifier": fixture.identifier, "workerIdentifier": fixture.workerIdentifier,
                "expectedLabel": "Edith calendar", "publicBrowser": true,
            ])
        observation = Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + .seconds(90)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                do {
                    let point = fixture.identifier + ".ExtensionUI"
                    let identities = try await Task.detached {
                        var iterator = try AppExtensionIdentity.matching(
                            appExtensionPointIDs: point
                        )
                        .makeAsyncIterator()
                        return await iterator.next() ?? []
                    }.value
                    guard identities.count <= 1 else { throw ProbeContractError.invalidFixture }
                    if let identity = identities.first {
                        guard identity.bundleIdentifier == fixture.workerIdentifier,
                            identity.extensionPointIdentifier == point
                        else { throw ProbeContractError.invalidFixture }
                        write(
                            "public-identity.json",
                            [
                                "hostIdentifier": fixture.identifier,
                                "workerIdentifier": identity.bundleIdentifier,
                                "extensionPointIdentifier": identity.extensionPointIdentifier,
                                "identity": identity.id, "publicDiscovery": true,
                            ])
                        return
                    }
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    if !Task.isCancelled {
                        write(
                            "approval-failure.json",
                            ["outcome": "failed", "stage": "public-discovery"])
                    }
                    return
                }
            }
            if !Task.isCancelled {
                write("approval-failure.json", ["outcome": "failed", "stage": "approval-timeout"])
            }
        }
    }

    private func write(_ name: String, _ value: [String: Any]) {
        do {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(
                to: URL(fileURLWithPath: fixture.directory).appendingPathComponent(name),
                options: .atomic)
        } catch { NSApp.terminate(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) { observation?.cancel() }
}
