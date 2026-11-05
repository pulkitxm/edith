@testable import MachinesExtension
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@MainActor enum MachinesCaptureRig {
    static let regular = CGSize(width: 1_100, height: 760)
    static let compact = CGSize(width: 640, height: 700)

    static var directory: URL? {
        ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    static var isolated: Bool {
        ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
    }

    @discardableResult
    static func capture<V: View>(
        _ name: String, size: CGSize, dark: Bool, zoom: Double = 1, automatic: Bool = false,
        @ViewBuilder _ view: () -> V
    ) async throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let prior = UIScale.current
        UIScale.apply(zoom)
        defer { UIScale.apply(prior) }
        let host = NSHostingView(
            rootView:
                NavigationRouteHost(router: WindowRouter()) {
                    view()
                        .environment(\.compactLayout, size.width < UIScale.pt(720))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.machineConnectionsEnabled, true)
                        .environment(\.terminalLaunchEnabled, false)
                        .environment(\.automaticViewActionsEnabled, automatic)
                        .environment(\.windowVisible, true)
                })
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.contentView = nil
        window.close()
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let suffix = "\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light")"
            let zoomSuffix = zoom == 1 ? "" : "-zoom\(zoom)"
            try data.write(to: directory.appendingPathComponent("\(name)-\(suffix)\(zoomSuffix).png"))
        }
        return bitmap
    }

    static func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                colors.insert(
                    Int(color.redComponent * 31) << 10 | Int(color.greenComponent * 31) << 5
                        | Int(color.blueComponent * 31))
            }
        }
        return colors.count
    }

    static func variants(zoomed: Bool = true) -> [(CGSize, Bool, Double)] {
        var all: [(CGSize, Bool, Double)] = []
        for size in [regular, compact] {
            for dark in [false, true] { all.append((size, dark, 1)) }
        }
        if zoomed { all.append((regular, false, 1.6)) }
        return all
    }
}

@Suite(.serialized) @MainActor struct MachinesSurfaceCaptureTests {
    private static let buildServer = Machine(
        id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!, name: "build-server",
        host: "build.example.invalid", username: "deploy")
    private static let garagePi = Machine(
        id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A2")!, name: "garage-pi",
        host: "10.0.0.42", username: "pi")
    private static let mediaBox = Machine(
        id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A3")!, name: "media-box",
        host: "media.example.invalid", username: "admin")

    private func withFleet(
        _ machines: [Machine], connected: Set<UUID>, mode: MachinesMode = .fleet,
        selection: UUID? = nil, _ body: (MachinesModel) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "machines-capture-\(UUID().uuidString)")
        let previousRoot = MachinePaths.root
        let previousMachines = MachinesModel.shared
        let previousWorkspace = WorkspaceModel.shared
        MachinePaths.root = root
        defer {
            MachinePaths.root = previousRoot
            MachinesModel.shared = previousMachines
            WorkspaceModel.shared = previousWorkspace
            try? FileManager.default.removeItem(at: root)
        }
        MachinePaths.prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(machines).write(to: MachinePaths.machinesFile)
        let model = MachinesModel()
        MachinesModel.shared = model
        WorkspaceModel.shared = WorkspaceModel(machines: model)
        #expect(model.store.machines.map(\.id) == machines.map(\.id))
        model.session(for: MachinesModel.localMachineID).start()
        for machine in machines where connected.contains(machine.id) {
            model.session(for: machine.id).start()
        }
        if let busy = machines.first(where: { $0.id == Self.buildServer.id }),
            connected.contains(busy.id)
        {
            model.session(for: busy.id).apply(
                sample: MachineSample(
                    ts: 2, dt: 2, cpu: MachineCPU(total: 71),
                    mem: MachineMemory(totalKB: 33_554_432, availKB: 6_000_000, usedKB: 27_554_432),
                    uptime: 86_400))
        }
        SharedDefaults.store.set(mode.rawValue, forKey: MachineSettingsKeys.mode)
        SharedDefaults.store.set(MachineTab.overview.rawValue, forKey: MachineSettingsKeys.tab)
        SharedDefaults.store.set(
            selection?.uuidString ?? "", forKey: MachineSettingsKeys.selection)
        model.selection = selection
        try await body(model)
        for machine in model.allMachines { model.session(for: machine.id).stop() }
    }

    @Test func firstRunFleetInvitesTheFirstRemoteMachine() async throws {
        guard MachinesCaptureRig.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        try await withFleet([], connected: []) { model in
            #expect(FleetFirstRun.needsRemoteMachine(model.snapshots))
            for (size, dark, zoom) in MachinesCaptureRig.variants() {
                let bitmap = try await MachinesCaptureRig.capture(
                    "fleet-first-run", size: size, dark: dark, zoom: zoom
                ) { MachinesPage() }
                #expect(bitmap.pixelsWide >= Int(size.width))
                #expect(MachinesCaptureRig.distinctColors(bitmap) > 12)
            }
        }
    }

    @Test func populatedFleetShowsEveryMachine() async throws {
        guard MachinesCaptureRig.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        let machines = [Self.buildServer, Self.garagePi, Self.mediaBox]
        try await withFleet(
            machines, connected: [Self.buildServer.id, Self.garagePi.id]
        ) { model in
            #expect(!FleetFirstRun.needsRemoteMachine(model.snapshots))
            #expect(model.fleet.machinesOnline == 3)
            for (size, dark, zoom) in MachinesCaptureRig.variants() {
                let bitmap = try await MachinesCaptureRig.capture(
                    "fleet-populated", size: size, dark: dark, zoom: zoom
                ) { MachinesPage() }
                #expect(MachinesCaptureRig.distinctColors(bitmap) > 12)
            }
        }
    }

    @Test func connectionPromptMatchesTheConnectionState() {
        #expect(MachineConnectionPrompt.resolve(.disconnected) == .connect)
        #expect(
            MachineConnectionPrompt.resolve(.failed(message: "Timed out", recoverable: true))
                == .retry)
        #expect(
            MachineConnectionPrompt.resolve(.failed(message: "Removed", recoverable: false))
                == .connect)
        #expect(MachineConnectionPrompt.resolve(.connecting) == nil)
        #expect(MachineConnectionPrompt.resolve(.connected(latencyMillis: 4)) == nil)
    }

    @Test func unreachableMachineOffersARetry() async throws {
        guard MachinesCaptureRig.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        let previousMachines = MachinesModel.shared
        let previousWorkspace = WorkspaceModel.shared
        defer {
            MachinesModel.shared = previousMachines
            WorkspaceModel.shared = previousWorkspace
        }
        let bridge = SilentMachineBridge()
        let transport = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let client = MachineUIClient(client: transport)
        defer { client.shutdown() }
        let model = MachinesModel(uiClient: client)
        MachinesModel.shared = model
        WorkspaceModel.shared = WorkspaceModel(machines: model)
        var failed = MachineSession(machine: Self.mediaBox, uiClient: client).uiState()
        failed.state = .failed(
            message: "media.example.invalid did not answer on port 22 within 10 seconds.",
            recoverable: true)
        model.applyUIState(
            MachineUIState(
                machines: [Self.mediaBox], forwards: [], snippets: [], sessions: [failed],
                workspaces: WorkspaceStore()))
        model.selection = Self.mediaBox.id
        SharedDefaults.store.set(MachinesMode.machine.rawValue, forKey: MachineSettingsKeys.mode)
        SharedDefaults.store.set(MachineTab.overview.rawValue, forKey: MachineSettingsKeys.tab)
        SharedDefaults.store.set(
            Self.mediaBox.id.uuidString, forKey: MachineSettingsKeys.selection)
        #expect(
            MachineConnectionPrompt.resolve(model.session(for: Self.mediaBox.id).state) == .retry)
        for (size, dark, zoom) in MachinesCaptureRig.variants() {
            let bitmap = try await MachinesCaptureRig.capture(
                "machine-unreachable", size: size, dark: dark, zoom: zoom
            ) { MachinesPage() }
            #expect(MachinesCaptureRig.distinctColors(bitmap) > 8)
        }
        failed.state = .connecting
        model.applyUIState(
            MachineUIState(
                machines: [Self.mediaBox], forwards: [], snippets: [], sessions: [failed],
                workspaces: WorkspaceStore()))
        for (size, dark, zoom) in MachinesCaptureRig.variants(zoomed: false) {
            let bitmap = try await MachinesCaptureRig.capture(
                "machine-connecting", size: size, dark: dark, zoom: zoom
            ) { MachinesPage() }
            #expect(MachinesCaptureRig.distinctColors(bitmap) > 4)
        }
    }

    @Test func addMachineSheetRendersBothEntryModes() async throws {
        guard MachinesCaptureRig.isolated else {
            Issue.record("Capture requires an isolated synthetic fixture."); return
        }
        let size = CGSize(width: 560, height: 690)
        let empty = MachineUIConfigurationState(hosts: [], sudoPasswordStored: [])
        let configured = MachineUIConfigurationState(
            hosts: [
                SSHConfigHost(alias: "build", hostName: "build.example.invalid", user: "deploy"),
                SSHConfigHost(alias: "garage-pi", hostName: "10.0.0.42", user: "pi", port: 2222),
            ], sudoPasswordStored: [])
        let edited = Machine(
            name: "garage-pi", host: "10.0.0.42", port: 2222, username: "pi",
            sshClipboardEnabled: true)
        let cases: [(String, MachineUIConfigurationState, Machine?)] = [
            ("add-machine-manual", empty, nil), ("add-machine-config", configured, nil),
            ("add-machine-edit", empty, edited),
        ]
        for (name, configuration, editing) in cases {
            for (dark, zoom) in [(false, 1.0), (true, 1.0), (false, 1.6)] {
                let sheetSize = CGSize(width: size.width * zoom, height: size.height * zoom)
                let bitmap = try await MachinesCaptureRig.capture(
                    name, size: sheetSize, dark: dark, zoom: zoom, automatic: true
                ) {
                    AddMachineSheet(editing: editing, loadConfiguration: { configuration }) {
                        _, _ in
                    }
                }
                #expect(MachinesCaptureRig.distinctColors(bitmap) > 8)
            }
        }
    }
}

@MainActor private final class SilentMachineBridge: NSObject {
    @objc func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {}
    @objc func cancel(_ token: NSString) {}
}
