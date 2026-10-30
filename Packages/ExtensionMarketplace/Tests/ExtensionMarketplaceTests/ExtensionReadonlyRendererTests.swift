import Foundation
import Testing

@testable import ExtensionMarketplace

@Suite @MainActor struct ExtensionReadonlyRendererTests {
    @Test func separatePresentationsKeepIndependentRuntimeObjectsWhenAnotherCloses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-isolation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("herdr/app.bundle/Contents")
        let binaries = bundle.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let executable = binaries.appendingPathComponent("Renderer")
        let source = directory.appendingPathComponent("Renderer.swift")
        try """
        import AppKit
        import Foundation
        import ObjectiveC
        @MainActor final class Renderer: NSObject {
            private var title: String?
            @objc func execute(_ input: NSDictionary) -> NSObject {
                switch input["operation"] as? String {
                case "describe":
                    return ["id": "herdr", "version": "1.0.0", "hostABI": "synthetic-abi",
                            "role": "app"] as NSDictionary
                case "configureUI":
                    title = input["presentationID"] as? String
                    let key = unsafeBitCast(NSSelectorFromString("edithExtensionUIOwnership"), to: UnsafeRawPointer.self)
                    let bound = objc_getAssociatedObject(self, key) as? NSObject
                    return ["ok": title != nil, "ownershipBound": bound === input["hostUIOwnership"] as? NSObject] as NSDictionary
                case "view":
                    let controller = NSViewController()
                    controller.title = title
                    return controller
                case "stopUI":
                    title = nil
                    return ["ok": true] as NSDictionary
                default: return ["ok": false] as NSDictionary
                }
            }
        }
        @_cdecl("edith_extension_create")
        public func createRenderer() -> UnsafeMutableRawPointer? {
            MainActor.assumeIsolated { Unmanaged.passRetained(Renderer()).toOpaque() }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let information: [String: Any] = [
            "CFBundleIdentifier": "com.pulkit.edith.extensions.herdr.app",
            "CFBundleExecutable": "Renderer", "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.0.0", "EdithHostABI": "synthetic-abi",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: information, format: .xml, options: 0
        ).write(to: bundle.appendingPathComponent("Info.plist"))
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = [
            "swiftc", "-emit-library", "-module-name", "ScopedRendererFixture",
            source.path, "-o", executable.path,
        ]
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", bundle.deletingLastPathComponent().path]
        try signer.run()
        signer.waitUntilExit()
        try #require(signer.terminationStatus == 0)
        let package = ExtensionPackage(
            id: "herdr", version: "1.0.0", hostABI: "synthetic-abi",
            downloadURL: URL(string: "https://synthetic.invalid/herdr.zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
        let prototype = try ExtensionBundleRuntime(
            readOnlyPackage: package, directory: directory, role: .app,
            hostABI: package.hostABI, verify: ExtensionCodeSignature.verifyDevelopment)
        let first = try prototype.makeRenderer(ownership: NSObject())
        let second = try prototype.makeRenderer(ownership: NSObject())
        let firstID = UUID()
        let secondID = UUID()
        for (runtime, id) in [(first, firstID), (second, secondID)] {
            let response = try runtime.response(
                id: package.id, operation: "configureUI",
                context: configuration(package.id, "main", id))
            #expect(response["ok"] as? Bool == true)
            #expect(response["ownershipBound"] as? Bool == true)
        }
        #expect(try first.viewController(id: package.id, context: [:])?.title == firstID.uuidString)
        #expect(
            try second.viewController(id: package.id, context: [:])?.title == secondID.uuidString)
        _ = try first.response(id: package.id, operation: "stopUI")
        #expect(try first.viewController(id: package.id, context: [:])?.title == nil)
        #expect(
            try second.viewController(id: package.id, context: [:])?.title == secondID.uuidString)
        _ = try second.response(id: package.id, operation: "stopUI")
    }

    @Test func actualReadonlyRuntimeRejectsUnconfiguredCallbacksStartAndNativeTasksBeforeLoading()
        throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let package = ExtensionPackage(
            id: "herdr", version: "1.0.0", hostABI: "synthetic-abi",
            downloadURL: URL(
                string: "https://github.com/synthetic/fixture/releases/download/1/herdr.zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
        var verifications = 0
        let runtime = try ExtensionBundleRuntime(
            readOnlyPackage: package, directory: directory,
            role: .app, hostABI: package.hostABI, verify: { _ in verifications += 1 })
        for operation in ["start", "invoke", "nativeTask", "terminalUI", "terminalUIStatus"] {
            #expect(throws: MarketplaceError.invalidBundle) {
                try runtime.response(
                    id: "herdr", operation: operation,
                    context: ["presentationID": UUID().uuidString])
            }
        }
        #expect(throws: MarketplaceError.invalidBundle) {
            try runtime.start(id: "herdr", context: [:])
        }
        #expect(throws: MarketplaceError.invalidBundle) {
            try runtime.nativeTask(id: "herdr", payload: Data([1]))
        }
        #expect(try runtime.response(id: "herdr", operation: "stopUI")["ok"] as? Bool == true)
        #expect(verifications == 0 && !FileManager.default.fileExists(atPath: directory.path))
        #expect(try runtime.snapshot(id: "herdr") == nil)
    }

    @Test func configuredFixedOwnerLocationsPermitOnlyLocalRendererCallbacks() throws {
        for (owner, location) in [
            ("terminal", "main"), ("herdr", "main"), ("herdr", "herdr.agent"),
            ("herdr", "herdr.space"), ("quinjet", "main"),
        ] {
            var gate = ExtensionBundleRuntime.RendererCallbacks()
            let id = UUID()
            let input = configuration(owner, location, id)
            var calls = 0
            #expect(throws: MarketplaceError.invalidBundle) {
                try gate.response(
                    id: owner, role: .app, operation: "terminalUIStatus",
                    context: ["presentationID": id.uuidString]
                ) {
                    calls += 1; return ["ok": true]
                }
            }
            #expect(calls == 0)
            _ = try gate.response(id: owner, role: .app, operation: "configureUI", context: input) {
                calls += 1; return ["ok": true]
            }
            _ = try gate.response(
                id: owner, role: .app, operation: "terminalUI", context: event(id, 1)
            ) {
                calls += 1; return ["ok": true]
            }
            _ = try gate.response(
                id: owner, role: .app, operation: "terminalUIStatus",
                context: ["presentationID": id.uuidString]
            ) {
                calls += 1; return ["ok": true, "presentationID": id.uuidString, "focused": false]
            }
            #expect(calls == 3)
            for operation in [
                "start", "invoke", "synchronize", "command", "nativeTask", "execute", "readFile",
                "cancelCommand",
            ] {
                #expect(throws: MarketplaceError.invalidBundle) {
                    try gate.response(id: owner, role: .app, operation: operation, context: [:]) {
                        calls += 1; return ["ok": true]
                    }
                }
            }
            #expect(calls == 3)
        }
    }

    @Test func readonlyInactiveRejectedConfigureAndForeignBindingsDoNotAdmitEvents() throws {
        for mode in [
            "inactive", "noClient", "wrongOwner", "settings", "badLocation", "noTarget", "noToken",
            "failed", "role",
        ] {
            var gate = ExtensionBundleRuntime.RendererCallbacks()
            let id = UUID()
            let input = NSMutableDictionary(dictionary: configuration("herdr", "herdr.agent", id))
            switch mode {
            case "inactive": input["uiOnly"] = true
            case "noClient": input.removeObject(forKey: "engineClient")
            case "wrongOwner": input["extensionID"] = "quinjet"
            case "settings": input["location"] = "settings"
            case "badLocation": input["location"] = "main.arbitrary"
            case "noTarget": input.removeObject(forKey: "target")
            case "noToken": input.removeObject(forKey: "herdrPresentationToken")
            default: break
            }
            _ = try? gate.response(
                id: "herdr", role: mode == "role" ? .helper : .app, operation: "configureUI",
                context: input
            ) { ["ok": mode != "failed"] }
            var calls = 0
            #expect(throws: MarketplaceError.invalidBundle) {
                try gate.response(
                    id: "herdr", role: .app, operation: "terminalUI", context: event(id, 1)
                ) {
                    calls += 1; return ["ok": true]
                }
            }
            #expect(calls == 0)
        }
        for owner in ["music", "machines"] {
            var gate = ExtensionBundleRuntime.RendererCallbacks()
            let id = UUID()
            _ = try gate.response(
                id: owner, role: .app, operation: "configureUI",
                context: configuration(owner, "main", id)
            ) { ["ok": true] }
            #expect(throws: MarketplaceError.invalidBundle) {
                try gate.response(
                    id: owner, role: .app, operation: "terminalUI", context: event(id, 1)
                ) { ["ok": true] }
            }
        }
    }

    @Test func sealedMonotonicPayloadsRejectReplayOversizeAndArbitraryActions() throws {
        var gate = ExtensionBundleRuntime.RendererCallbacks()
        let id = UUID()
        _ = try gate.response(
            id: "herdr", role: .app, operation: "configureUI",
            context: configuration("herdr", "main", id)
        ) { ["ok": true] }
        _ = try gate.response(
            id: "herdr", role: .app, operation: "terminalUI", context: event(id, 2)
        ) { ["ok": false] }
        var calls = 0
        let oversized: NSDictionary = [
            "presentationID": id.uuidString, "payload": Data(repeating: 32, count: 1025),
        ]
        for input in [
            try event(id, 0), try event(id, 1), try event(id, 2),
            try event(UUID(), 3, envelope: id), try event(id, 3, action: "filesystem.open"),
            oversized,
        ] {
            #expect(throws: (any Error).self) {
                try gate.response(id: "herdr", role: .app, operation: "terminalUI", context: input)
                {
                    calls += 1; return ["ok": true]
                }
            }
        }
        #expect(calls == 0)
        #expect(throws: MarketplaceError.invalidBundle) {
            try gate.response(
                id: "quinjet", role: .app, operation: "terminalUI", context: event(id, 3)
            ) { ["ok": true] }
        }
        _ = try gate.response(
            id: "herdr", role: .app, operation: "releaseUI",
            context: ["presentationID": id.uuidString]
        ) { ["ok": true] }
        #expect(throws: MarketplaceError.invalidBundle) {
            try gate.response(
                id: "herdr", role: .app, operation: "terminalUIStatus",
                context: ["presentationID": id.uuidString]
            ) { ["ok": true] }
        }
        _ = try gate.response(
            id: "herdr", role: .app, operation: "configureUI",
            context: configuration("herdr", "main", id)
        ) { ["ok": true] }
        _ = try gate.response(id: "herdr", role: .app, operation: "stopUI", context: [:]) {
            ["ok": true]
        }
        #expect(throws: MarketplaceError.invalidBundle) {
            try gate.response(
                id: "herdr", role: .app, operation: "terminalUIStatus",
                context: ["presentationID": id.uuidString]
            ) { ["ok": true] }
        }
    }

    @Test func stoppingOnePresentationKeepsOtherPresentationsBound() throws {
        var gate = ExtensionBundleRuntime.RendererCallbacks()
        let main = UUID()
        let agent = UUID()
        for (location, id) in [("main", main), ("herdr.agent", agent)] {
            _ = try gate.response(
                id: "herdr", role: .app, operation: "configureUI",
                context: configuration("herdr", location, id)
            ) { ["ok": true] }
        }
        _ = try gate.response(
            id: "herdr", role: .app, operation: "stopUI",
            context: ["presentationID": agent.uuidString]
        ) { ["ok": true] }
        var calls = 0
        _ = try gate.response(
            id: "herdr", role: .app, operation: "terminalUI", context: event(main, 1)
        ) {
            calls += 1; return ["ok": true]
        }
        #expect(calls == 1)
        #expect(throws: MarketplaceError.invalidBundle) {
            try gate.response(
                id: "herdr", role: .app, operation: "terminalUI", context: event(agent, 1)
            ) { ["ok": true] }
        }
    }

    private func configuration(_ owner: String, _ location: String, _ id: UUID) -> NSDictionary {
        let input = NSMutableDictionary(dictionary: [
            "remoteUI": true, "uiOnly": false, "extensionID": owner,
            "location": location, "presentationID": id.uuidString, "engineClient": NSObject(),
        ])
        if location.hasPrefix("herdr.") {
            input["target"] = "synthetic-host.synthetic-agent"
            input["herdrPresentationToken"] = UUID().uuidString
        }
        return input
    }
    private func event(_ id: UUID, _ sequence: UInt64, envelope: UUID? = nil, action: String? = nil)
        throws -> NSDictionary
    {
        var fields: [String: Any] = [
            "version": 1, "presentationID": id.uuidString, "sequence": sequence, "active": false,
            "key": false, "visible": false,
        ]
        if let action { fields["action"] = action }
        return [
            "presentationID": (envelope ?? id).uuidString,
            "payload": try JSONSerialization.data(withJSONObject: fields),
        ]
    }
}
