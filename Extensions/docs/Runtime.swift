import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var browser: DocsBrowser?
    private var uiPresentations: [UUID: (browser: DocsBrowser, client: ExtensionEngineClient)] = [:]
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?
    private var stopped = false
    private var activeCalls = 0
    private var suspended = false
    private var suspension: Task<Void, Never>?
    private var uiRetirements: [UUID: Task<Void, Never>] = [:]

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, !self.stopped, let browser = self.browser else {
                throw ExtensionPeerError.unavailable
            }
            self.activeCalls += 1
            defer { self.activeCalls -= 1 }
            if command == "docs.cli.catalog" {
                return try ExtensionCLICatalog.data(
                    DocsCommandGroup.self, owner: "docs", payload: payload, streaming: true)
            }
            if command.hasPrefix("docs.cli.") {
                if self.cliStreams == nil {
                    self.cliStreams = try ExtensionCLIStreams(owner: "docs")
                }
                guard let streams = self.cliStreams else { throw ExtensionPeerError.unavailable }
                return try await DocsCLIExecution.stream(
                    streams, operation: command, payload: payload, browser: browser)
            }
            if command == "docs.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await DocsCLIExecution.run(request, browser: browser))
            }
            if command.hasPrefix("docs.ui.") {
                return try await DocsUIBridge.execute(command, payload: payload, browser: browser)
            }
            return try await DocsSurface.execute(command, payload: payload, browser: browser)
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        commands.suspend()
        suspended = true
        ExtensionUIResources.cleanup(of: self, key: "copyReset") {
            DocsCopyResetWork.beginSuspension()
        }
        let browser = browser
        let uiBrowsers = uiPresentations.values.map(\.browser)
        let streams = cliStreams
        browser?.cancelPendingWork()
        uiBrowsers.forEach { $0.cancelPendingWork() }
        streams?.stop()
        if suspension == nil {
            let retired = Array(uiRetirements.values)
            suspension = Task { [self, browser, uiBrowsers, streams] in
                await commands.suspendAndWait()
                if ExtensionUIResources.canDrainSharedResources(of: self) {
                    await DocsCopyResetWork.drain()
                }
                await browser?.drain()
                for uiBrowser in uiBrowsers { await uiBrowser.drain() }
                await streams?.stopAndWait()
                for task in retired { await task.value }
            }
        }
        let pending = suspension
        Task { [self] in
            await pending?.value
            withExtendedLifetime(self) { completion() }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        suspendCommands(completion: {})
        stopped = true
        let streams = cliStreams; cliStreams = nil; streams?.stop()
        commands.shutdown()
        let browser = browser
        browser?.cancelPendingWork()
        Task { [self, browser, streams] in
            await suspension?.value
            await browser?.drain()
            while activeCalls > 0 { await Task.yield() }
            await streams?.stopAndWait()
            await commands.shutdownAndWait()
            browser?.shutdown()
            for task in Array(uiRetirements.values) { await task.value }
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "docs", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !suspended, uiRetirements.isEmpty, uiPresentations.count < 8 else {
                return ["ok": false] as NSDictionary
            }
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "docs", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            if let previous = uiPresentations[client.presentationID] {
                previous.browser.cancelPendingWork()
                previous.client.invalidate()
            }
            DocsCopyResetWork.enable()
            uiPresentations[client.presentationID] = (
                DocsBrowser(remote: DocsUIBridge(client: client)), client
            )
        case "stopUI":
            ExtensionUIResources.cleanup(of: self, key: "copyReset") {
                DocsCopyResetWork.beginSuspension()
            }
            let retired = uiPresentations.values
            uiPresentations = [:]
            for presentation in retired {
                let browser = presentation.browser
                browser.cancelPendingWork()
                let id = UUID()
                uiRetirements[id] = Task { [self, browser] in
                    await browser.drain()
                    if ExtensionUIResources.canDrainSharedResources(of: self) {
                        await DocsCopyResetWork.drain()
                    }
                    browser.shutdown()
                    uiRetirements[id] = nil
                }
                presentation.client.invalidate()
            }
        case "start":
            guard !suspended else { return ["ok": false] as NSDictionary }
            guard !stopped, let suite = input["defaultsSuite"] as? String,
                suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if browser == nil { browser = DocsBrowser() }
        case "view":
            guard let value = input["presentationID"] as? String, let id = UUID(uuidString: value),
                let browser = uiPresentations[id]?.browser
            else { return ["ok": false] as NSDictionary }
            return NSHostingController(rootView: ExtensionPageHost { DocsScreen(browser: browser) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": _ = DocsPeerDecider.configured()
        case "stop":
            prepareToStop(completion: {})
            browser = nil
        case "status": return ["ok": true, "running": !stopped && browser != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
