import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import SwiftUI

@MainActor
final class DocsService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var browser: DocsBrowser?
    private var uiPresentations: [UUID: (browser: DocsBrowser, client: ExtensionEngineClient)] = [:]
    private var cliStreams: ExtensionCLIStreams?

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { browser != nil }

    func start() -> Bool {
        if browser == nil { browser = DocsBrowser() }
        return true
    }

    func synchronize() { _ = DocsPeerDecider.configured() }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let browser else { throw ExtensionPeerError.unavailable }
        if command == "docs.cli.catalog" {
            return try ExtensionCLICatalog.data(
                DocsCommandGroup.self, owner: "docs", payload: payload, streaming: true)
        }
        if command.hasPrefix("docs.cli.") {
            if cliStreams == nil { cliStreams = try ExtensionCLIStreams(owner: "docs") }
            guard let streams = cliStreams else { throw ExtensionPeerError.unavailable }
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

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard uiPresentations.count < 8, let client = configuration.engineClient else {
            return false
        }
        if let previous = uiPresentations[client.presentationID] {
            previous.browser.cancelPendingWork()
            previous.client.invalidate()
        }
        DocsCopyResetWork.enable()
        uiPresentations[client.presentationID] = (
            DocsBrowser(remote: DocsUIBridge(client: client)), client
        )
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let browser = uiPresentations[presentation]?.browser else { return nil }
        return NSHostingController(rootView: ExtensionPageHost { DocsScreen(browser: browser) })
    }

    func stopUI() -> [Task<Void, Never>] {
        ExtensionUIResources.cleanup(of: runtime, key: "copyReset") {
            DocsCopyResetWork.beginSuspension()
        }
        let retired = uiPresentations.values
        uiPresentations = [:]
        return retired.map { presentation in
            let browser = presentation.browser
            browser.cancelPendingWork()
            presentation.client.invalidate()
            return Task { [runtime, browser] in
                await browser.drain()
                if ExtensionUIResources.canDrainSharedResources(of: runtime) {
                    await DocsCopyResetWork.drain()
                }
                browser.shutdown()
            }
        }
    }

    func cancelPendingWork() {
        ExtensionUIResources.cleanup(of: runtime, key: "copyReset") {
            DocsCopyResetWork.beginSuspension()
        }
        browser?.cancelPendingWork()
        uiPresentations.values.forEach { $0.browser.cancelPendingWork() }
        cliStreams?.stop()
    }

    func drain() async {
        if ExtensionUIResources.canDrainSharedResources(of: runtime) {
            await DocsCopyResetWork.drain()
        }
        await browser?.drain()
        for presentation in uiPresentations.values { await presentation.browser.drain() }
        await cliStreams?.stopAndWait()
    }

    func teardown() async {
        let streams = cliStreams
        cliStreams = nil
        await streams?.stopAndWait()
        browser?.shutdown()
        browser = nil
    }
}

@MainActor
func makeDocsRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(id: "docs", role: "app", bundle: Bundle(for: BundleAnchor.self))
    { DocsService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeDocsRuntime()).toOpaque())
        })
}
