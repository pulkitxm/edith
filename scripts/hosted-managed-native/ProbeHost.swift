import AppKit
import CoreServices
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
    private var checkInDeadline: Task<Void, Never>?
    private var checkInFinished = false

    private static func validatedFixture(directory: URL) throws -> ProbeFixture {
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
        try fixture.validateApplicationInfo(
            Data(
                contentsOf: URL(fileURLWithPath: fixture.app).appendingPathComponent(
                    "Contents/Info.plist")))
        return fixture
    }

    static func dispatch(arguments: [String]) throws {
        let directory = try ProbeLaunch.candidateDirectory(arguments)
        let fixture = try validatedFixture(directory: directory)
        try writeReceipt(
            fixture: fixture, name: "probe-startup.json",
            value: [
                "outcome": "started", "stage": "argv-received", "argumentCount": arguments.count,
                "extraArgumentCount": max(0, arguments.count - 2),
                "argumentKinds": ProbeLaunch.diagnosticKinds(arguments, directory: directory),
            ])
        let request: ProbeLaunch.Request
        do { request = try ProbeLaunch.parse(arguments) } catch {
            try writeReceipt(
                fixture: fixture, name: "approval-failure.json",
                value: [
                    "outcome": "failed", "stage": "argv-admission",
                    "argumentCount": arguments.count,
                    "extraArgumentCount": max(0, arguments.count - 2),
                    "argumentKinds": ProbeLaunch.diagnosticKinds(arguments, directory: directory),
                    "contractFailure": "launchArguments",
                ])
            throw error
        }
        switch request.mode {
        case .registration: try register(directory: request.directory)
        case .approval: try run(directory: request.directory)
        }
    }

    private static func writeReceipt(fixture: ProbeFixture, name: String, value: [String: Any])
        throws
    {
        let bound = value.merging(["hostIdentifier": fixture.identifier]) { _, next in next }
        let data = try JSONSerialization.data(withJSONObject: bound, options: [.sortedKeys])
        guard data.count <= 16_384 else { throw ProbeContractError.invalidFixture }
        try data.write(
            to: URL(fileURLWithPath: fixture.directory).appendingPathComponent(name),
            options: .atomic)
    }

    static func register(directory: URL) throws {
        let fixture = try validatedFixture(directory: directory)
        guard LSRegisterURL(URL(fileURLWithPath: fixture.app) as CFURL, true) == noErr else {
            throw ProbeContractError.invalidFixtureField("applicationRegistration")
        }
        let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: fixture.identifier)
        try fixture.validateRegisteredApplications(urls)
        try JSONSerialization.data(
            withJSONObject: [
                "publicApplicationRegistration": true, "hostIdentifier": fixture.identifier,
                "applicationPath": fixture.app,
            ], options: [.sortedKeys]
        ).write(to: directory.appendingPathComponent("registration-ready.json"), options: .atomic)
    }

    static func run(directory: URL) throws {
        let fixture = try validatedFixture(directory: directory)
        try writeReceipt(
            fixture: fixture, name: "probe-startup.json",
            value: [
                "outcome": "started", "stage": "approval-loop",
                "argumentCount": CommandLine.arguments.count - 1,
            ])
        let delegate = HostedManagedApprovalProbe(fixture: fixture)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    private init(fixture: ProbeFixture) { self.fixture = fixture }

    func applicationDidFinishLaunching(_ notification: Notification) {
        write("probe-startup.json", ["outcome": "started", "stage": "carrier-requested"])
        checkInDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, !checkInFinished else { return }
            checkInFinished = true
            write("approval-failure.json", ["outcome": "failed", "stage": "carrier-timeout"])
            NSApp.terminate(nil)
        }
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
                guard let self, !self.checkInFinished else { return }
                self.checkInFinished = true
                self.checkInDeadline?.cancel()
                let matches = application?.bundleURL?.path == self.fixture.carrier
                var receipt: [String: Any] = [
                    "outcome": "started", "stage": "carrier-check-in",
                    "applicationReturned": application != nil, "carrierPathMatched": matches,
                ]
                if let error {
                    let native = error as NSError
                    let domain = native.domain
                    receipt["errorDomain"] =
                        domain.range(of: #"^[A-Za-z0-9.-]{1,128}$"#, options: .regularExpression)
                            != nil ? domain : "other"
                    receipt["errorCode"] = native.code
                }
                guard application != nil, matches, error == nil else {
                    receipt["outcome"] = "failed"
                    self.write("approval-failure.json", receipt)
                    NSApp.terminate(nil)
                    return
                }
                self.write("probe-startup.json", receipt)
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
        write("probe-startup.json", ["outcome": "started", "stage": "browser-created"])
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
            try Self.writeReceipt(fixture: fixture, name: name, value: value)
        } catch { NSApp.terminate(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        checkInFinished = true
        checkInDeadline?.cancel()
        observation?.cancel()
    }
}
