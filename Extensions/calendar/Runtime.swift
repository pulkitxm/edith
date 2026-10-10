import AppKit
import CoreFoundation
import EdithExtensionSupport
import EdithExtensionUI
import EdithExtensionCommands
import Darwin
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var stopping = false
    private var store: CalendarStore?
    private var presentation: CalendarPresentationState?
    private var surface: CalendarSurface?
    private var uiEngine: CalendarUIEngine?
    private var navigation: CalendarHostNavigation?
    private var fixture: CalendarFixtureBackend?
    private let commands = ExtensionCommandRegistry()
    private var uiPresentations: [UUID: CalendarUIPresentation] = [:]

    override init() { super.init() }

    init(
        store: CalendarStore, presentation: CalendarPresentationState, uiEngine: CalendarUIEngine,
        fixture: CalendarFixtureBackend? = nil
    ) {
        self.store = store
        self.presentation = presentation
        self.uiEngine = uiEngine
        self.fixture = fixture
        surface = fixture?.surface
        super.init()
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        guard !stopping else {
            completion(nil, "The Calendar extension is stopping.")
            return
        }
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            if command == "calendar.cli.catalog" {
                guard self?.store != nil, payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.unavailable
                }
                return try CalendarCLICatalog.encoded(payload)
            }
            if command.hasPrefix("calendar.ui.") {
                guard let engine = self?.uiEngine else { throw ExtensionPeerError.unavailable }
                return try await engine.execute(command, payload: payload)
            }
            if command == "calendar.cli" {
                guard let store = self?.store else { throw ExtensionPeerError.unavailable }
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                let reply = try await CalendarCLIExecution.run(
                    request, actions: self?.fixture?.cliActions
                ) { query in
                    store.refreshAuthStatus()
                    guard store.authStatus == .fullAccess else {
                        throw CLIFailure.unavailable(
                            "macOS has not granted Edith calendar access",
                            hint: "run `ed permissions request calendar`")
                    }
                    return await store.events(query)
                }
                return try CalendarCLIExecution.encoded(reply)
            }
            guard let surface = self?.surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        stopping = true
        commands.shutdown()
        uiEngine?.shutdown()
        store?.shutdown()
        navigation?.invalidate()
        CalendarPermission.shutdown()
        Task {
            await commands.shutdownAndWait()
            await uiEngine?.stopAndWait()
            await store?.stopAndWait()
            await navigation?.stopAndWait()
            await CalendarPermission.stopAndWait()
            presentation?.shutdown()
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "calendar", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard !stopping, Bundle.main.bundleURL.pathExtension != "appex",
                uiPresentations.isEmpty,
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            do {
                let admission = try CalendarFixtureAdmission.current(input)
                if store == nil {
                    if let admission {
                        let fixture = CalendarFixtureBackend(admission: admission)
                        self.fixture = fixture
                        store = fixture.store
                        presentation = fixture.presentation
                    } else {
                        store = CalendarStore(startImmediately: false)
                    }
                }
            } catch { return ["ok": false] as NSDictionary }
            if presentation == nil { presentation = CalendarPresentationState() }
            if let store, let presentation, surface == nil {
                let navigation = CalendarHostNavigation(
                    bridge: input["hostNavigation"] as? NSObject)
                self.navigation = navigation
                surface =
                    fixture?.surface
                    ?? CalendarSurface(store: store, presentation: presentation)
                let navigate: (CalendarNavigationRequest) async throws -> Void = {
                    [weak navigation] request in
                    guard let navigation else { throw ExtensionPeerError.unavailable }
                    try await navigation.navigate(request)
                }
                if let fixture {
                    uiEngine = fixture.makeUIEngine(navigate: navigate)
                } else {
                    uiEngine = CalendarUIEngine(
                        store: store, presentation: presentation, navigate: navigate)
                }
                store.start()
            }
        case "configureUI":
            uiPresentations = uiPresentations.filter { $0.value.isRetained }
            guard store == nil, let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "calendar", let client = configuration.engineClient,
                let scene = CalendarUIPresentation(client: client, context: input),
                uiPresentations.count < 8 || uiPresentations[client.presentationID] != nil
            else { return ["ok": false] as NSDictionary }
            uiPresentations[client.presentationID]?.shutdown()
            uiPresentations[client.presentationID] = scene
        case "view":
            guard let value = input["presentationID"] as? String,
                let id = UUID(uuidString: value), let scene = uiPresentations[id],
                scene.matches(input)
            else { return ["ok": false] as NSDictionary }
            return scene.controller() ?? (["ok": false] as NSDictionary)
        case "stopUI":
            for scene in uiPresentations.values { scene.shutdown() }
            uiPresentations.removeAll()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": store?.refreshAuthStatus()
        case "stop":
            stopping = true
            for scene in uiPresentations.values { scene.shutdown() }
            uiPresentations.removeAll()
            commands.shutdown()
            navigation?.invalidate()
            navigation = nil
            uiEngine?.shutdown()
            uiEngine = nil
            surface = nil
            store?.shutdown()
            store = nil
            presentation?.shutdown()
            presentation = nil
            fixture = nil
            CalendarPermission.shutdown()
        case "status": return ["ok": true, "running": store != nil] as NSDictionary
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

struct CalendarFixtureAdmission {
    let home: URL
    let dataDirectory: URL
    let packageDirectory: URL

    private init(home: URL, dataDirectory: URL, packageDirectory: URL) {
        self.home = home
        self.dataDirectory = dataDirectory
        self.packageDirectory = packageDirectory
    }

    static func current(_ context: NSDictionary) throws -> Self? {
        let role = Bundle(for: ExtensionRuntime.self)
        return try admit(
            context: context, environment: ProcessInfo.processInfo.environment,
            hostIdentifier: Bundle.main.bundleIdentifier, hostBundle: Bundle.main.bundleURL,
            roleBundle: role.bundleURL,
            roleIdentifier: role.bundleIdentifier,
            hostABI: role.object(forInfoDictionaryKey: "EdithHostABI") as? String,
            version: role.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    static func admit(
        context: NSDictionary, environment: [String: String], hostIdentifier: String?,
        hostBundle: URL, roleBundle: URL, roleIdentifier: String?, hostABI: String?,
        version: String?
    ) throws -> Self? {
        let prefix = "com.pulkit.edith.tests.remote-"
        guard
            environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
                || hostIdentifier?.hasPrefix("com.pulkit.edith.tests.") == true
                || (context["hostIdentifier"] as? String)?.hasPrefix("com.pulkit.edith.tests.")
                    == true
        else { return nil }
        guard let identifier = hostIdentifier, identifier.hasPrefix(prefix),
            UUID(uuidString: String(identifier.dropFirst(prefix.count))) != nil,
            context["hostIdentifier"] as? String == identifier,
            environment["EDITH_APPLICATION_IDENTIFIER"] == identifier,
            context["defaultsSuite"] as? String == identifier + ".extensions.calendar",
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == identifier + ".extensions.calendar",
            environment["EDITH_EXTENSION_ID"] == "calendar",
            let homePath = environment["EDITH_EXTENSION_FIXTURE_HOME"],
            let dataPath = environment["EDITH_EXTENSION_DATA_ROOT"],
            context["dataDirectory"] as? String == dataPath,
            roleIdentifier == "com.pulkit.edith.extensions.calendar.app",
            let hostABI, validComponent(hostABI), let version, validComponent(version)
        else { throw ExtensionPeerError.invalidRequest }
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let directory = home.deletingLastPathComponent()
        guard homePath == home.path, home.lastPathComponent == "synthetic-data",
            directory.path != "/",
            directory.path != FileManager.default.homeDirectoryForCurrentUser.path,
            hostBundle == directory.appendingPathComponent("Host.app", isDirectory: true)
        else { throw ExtensionPeerError.invalidRequest }
        let slot = String(identifier.dropFirst("com.pulkit.edith.tests.".count))
        let identity = directory.appendingPathComponent("support/Edith Tests/" + slot)
        let data = identity.appendingPathComponent("Data/calendar", isDirectory: true)
        let package = identity.appendingPathComponent(
            "Extensions/calendar/" + hostABI + "/arm64/" + version + "/calendar",
            isDirectory: true)
        let role = package.appendingPathComponent(
            "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/calendar/app.bundle",
            isDirectory: true)
        guard dataPath == data.path, roleBundle == role else {
            throw ExtensionPeerError.invalidRequest
        }
        for url in [directory, home, hostBundle, identity, data, package, role] {
            try validatePath(url, directory: true)
        }
        let homeAttributes = try FileManager.default.attributesOfItem(atPath: home.path)
        guard (homeAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw ExtensionPeerError.invalidRequest
        }
        let marker = home.appendingPathComponent("calendar-fixture.json")
        try validatePath(marker, directory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 16_384,
            let values = try JSONSerialization.jsonObject(with: Data(contentsOf: marker))
                as? [String: Any],
            Set(values.keys) == ["schema", "hostIdentifier", "dataDirectory", "packageDirectory"],
            let schema = values["schema"] as? NSNumber, schema.doubleValue == 1,
            CFGetTypeID(schema) != CFBooleanGetTypeID(),
            values["hostIdentifier"] as? String == identifier,
            values["dataDirectory"] as? String == data.path,
            values["packageDirectory"] as? String == package.path
        else { throw ExtensionPeerError.invalidRequest }
        return Self(home: home, dataDirectory: data, packageDirectory: package)
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value != "." && value != ".."
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".")
            }
    }

    private static func validatePath(_ url: URL, directory: Bool) throws {
        guard url.isFileURL, url.path == url.standardizedFileURL.path,
            url.path == url.resolvingSymlinksInPath().path
        else { throw ExtensionPeerError.invalidRequest }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard
            attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0
        else { throw ExtensionPeerError.invalidRequest }
    }
}

@MainActor
final class CalendarFixtureBackend {
    let store: CalendarStore
    let presentation = CalendarPresentationState(channel: nil)
    private(set) var opened: [URL] = []
    private(set) var grants = 0

    init(admission: CalendarFixtureAdmission, now: Date = Date()) {
        let events = Self.events(now: now)
        store = CalendarStore(
            snapshotStore: .init(events: []),
            fetch: { query in events.filter(query.contains) }, authorization: { .fullAccess })
    }

    var surface: CalendarSurface {
        CalendarSurface(
            store: store, presentation: presentation,
            open: { [weak self] in
                self?.open($0) ?? false
            })
    }

    var cliActions: CalendarCLIActionServices {
        .init(
            openURL: { [weak self] in self?.open($0) ?? false },
            openCalendar: { [weak self] in _ = self?.open($0) })
    }

    func open(_ url: URL) -> Bool {
        opened.append(url)
        return true
    }

    func grant() async throws {
        try Task.checkCancellation()
        grants += 1
    }

    func makeUIEngine(
        navigate: @escaping (CalendarNavigationRequest) async throws -> Void
    ) -> CalendarUIEngine {
        CalendarUIEngine(
            store: store, presentation: presentation,
            open: { [weak self] in self?.open($0) ?? false },
            grant: { [weak self] in try await self?.grant() }, navigate: navigate)
    }

    static func events(now: Date) -> [CalendarEventPayload] {
        [
            .init(
                id: "synthetic-calendar-meeting", title: "Synthetic Calendar review",
                calendar: "Synthetic Work", calendarID: "synthetic-work",
                start: now, end: now.addingTimeInterval(1800),
                isAllDay: false, location: "Synthetic Hall", latitude: 37.3318,
                longitude: -122.0312,
                meetingURL: "https://meet.google.com/synthetic-calendar-review",
                notes: "Synthetic agenda notes"),
            .init(
                id: "synthetic-calendar-next-page", title: "Synthetic Planning",
                calendar: "Synthetic Personal", calendarID: "synthetic-personal",
                start: now.addingTimeInterval(16 * 86400),
                end: now.addingTimeInterval(16 * 86400 + 1800),
                isAllDay: false),
        ]
    }
}
