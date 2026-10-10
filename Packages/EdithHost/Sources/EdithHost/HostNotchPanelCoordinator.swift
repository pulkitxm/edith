import AppKit
import EdithHostCore
import Foundation

@MainActor
final class HostNotchPanelCoordinator {
    typealias Invoke = @MainActor (String, Data, Double) async throws -> Data
    typealias Environment = @MainActor () -> HostNotchPanelEnvironment

    let ownershipID = UUID()
    private let invoke: Invoke
    private let environment: Environment
    private let association: HostNotchWindowAssociation?
    private let create: HostNotchPanelAssembly.Create
    private let present: @MainActor (HostNotchPanel) -> Void
    private let now: @MainActor () -> ContinuousClock.Instant
    private var attachRequest: HostNotchPanelAttach?
    private var screens: [UInt32: HostNotchPanelScreen] = [:]
    private var identity: HostNotchPanelIdentity?
    private var batch: HostNotchPanelBatch?
    private var assemblies: [UInt32: HostNotchPanelAssembly] = [:]
    private var starting: Task<Void, any Error>?
    private var waiting: Task<Void, Never>?
    private var stopping: Task<Void, any Error>?
    private var writing: Task<Void, Never>?
    private var pointers: [UInt32: HostNotchPanelPointer] = [:]
    private var measurements: [UUID: HostNotchPanelMeasure] = [:]
    private var retired = false
    private(set) var failure: String?

    init(
        invoke: @escaping Invoke, environment: @escaping Environment,
        association: HostNotchWindowAssociation? = nil,
        create: @escaping HostNotchPanelAssembly.Create,
        present: @escaping @MainActor (HostNotchPanel) -> Void = { $0.orderFrontRegardless() },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.invoke = invoke; self.environment = environment; self.association = association
        self.create = create; self.present = present; self.now = now
    }

    var presentationIDs: Set<UUID> {
        assemblies.values.reduce(into: Set<UUID>()) { $0.formUnion($1.presentationIDs) }
    }
    var panelCount: Int { assemblies.count }
    var attachedSceneCount: Int { assemblies.values.reduce(0) { $0 + $1.attachedCount } }
    var pendingCleanupCount: Int {
        assemblies.values.reduce(0) { $0 + $1.pendingCleanupCount }
            + (retired && attachRequest != nil ? 1 : 0)
    }

    func window(for presentationID: UUID) -> NSWindow? {
        guard !retired, environment().activeVersions["notchShelf"] == attachRequest?.version else {
            return nil
        }
        return assemblies.values.first(where: { $0.containsLivePresentation(presentationID) })?
            .panel
    }

    func start(version: String, screens: [HostNotchPanelScreen]) async throws {
        guard !retired, starting == nil, attachRequest == nil,
            environment().activeVersions["notchShelf"] == version,
            !screens.isEmpty, screens.count <= 8, screens.allSatisfy({ $0.display.valid }),
            Set(screens.map { $0.display.id }).count == screens.count,
            Set(screens.map(\.presentationID)).count == screens.count,
            screens.filter(\.isBuiltin).count <= 1
        else { throw HostNotchPanelError.invalidState }
        self.screens = Dictionary(uniqueKeysWithValues: screens.map { ($0.display.id, $0) })
        let request = HostNotchPanelAttach(
            ownershipID: ownershipID, version: version, displays: screens.map(\.request))
        attachRequest = request
        let task = Task { [self] in
            let result = try await requestBatch("notch.panel.attach", request, timeout: 5)
            guard result.identity.ownershipID == ownershipID else {
                throw HostNotchPanelError.staleState
            }
            identity = result.identity
            try Task.checkCancellation()
            guard !retired else { throw CancellationError() }
            try accept(result)
            waitForChanges()
        }
        starting = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            starting = nil
        } catch {
            starting = nil
            failure = "The Notch panel could not connect."
            try? await stop()
            throw error
        }
    }

    func synchronize() {
        let current = environment()
        if current.activeVersions["notchShelf"] != attachRequest?.version {
            waiting?.cancel(); writing?.cancel(); pointers = [:]; measurements = [:]
        }
        measurements = measurements.filter { slotID, _ in
            guard let slot = batch?.states.flatMap(\.slots).first(where: { $0.id == slotID }) else {
                return false
            }
            return current.activeVersions[slot.providerID] == slot.providerVersion
                && !current.hiddenWidgets.contains(slot.tile.widget)
        }
        for assembly in assemblies.values {
            assembly.synchronize(
                activeVersions: current.activeVersions, hiddenWidgets: current.hiddenWidgets)
        }
    }

    func pointer(
        displayID: UInt32, globalPoint: CGPoint, buttons: UInt32,
        option: Bool, draggingFiles: Bool
    ) {
        guard !retired, let identity, let screen = screens[displayID],
            environment().activeVersions["notchShelf"] == attachRequest?.version,
            globalPoint.x.isFinite, globalPoint.y.isFinite, buttons <= 31
        else { return }
        let x = globalPoint.x - screen.display.frame.minX
        let y = screen.display.frame.maxY - globalPoint.y
        guard (-128...screen.display.frame.width + 128).contains(x),
            (-128...screen.display.frame.height + 128).contains(y)
        else { return }
        pointers[displayID] = .init(
            identity: identity, displayID: displayID,
            presentationID: screen.presentationID, x: x, y: y,
            buttons: buttons, option: option, draggingFiles: draggingFiles)
        writePending()
    }

    func stop() async throws {
        if let stopping { try await stopping.value; return }
        retired = true
        for assembly in assemblies.values { assembly.hide() }
        starting?.cancel(); waiting?.cancel(); writing?.cancel()
        let task = Task { [self] in try await stopOwned() }
        stopping = task
        defer { stopping = nil }
        try await task.value
    }

    private func stopOwned() async throws {
        if let starting { _ = try? await starting.value }
        if let waiting { await waiting.value }
        if let writing { await writing.value }
        waiting = nil; writing = nil; pointers = [:]; measurements = [:]
        var cleanupError: (any Error)?
        for assembly in assemblies.values {
            do { try await assembly.stop() } catch { cleanupError = error }
        }
        if identity == nil, let attachRequest {
            do {
                let recovered = try await requestBatch(
                    "notch.panel.attach", attachRequest, timeout: 5)
                guard recovered.identity.ownershipID == ownershipID else {
                    throw HostNotchPanelError.staleState
                }
                identity = recovered.identity
            } catch { cleanupError = error }
        }
        guard cleanupError == nil, assemblies.values.allSatisfy({ $0.pendingCleanupCount == 0 })
        else {
            failure = "The Notch panel is still stopping. Try cleanup again."
            throw cleanupError ?? HostNotchPanelError.staleState
        }
        if let identity {
            do {
                _ = try await request("notch.panel.detach", identity, timeout: 5)
                self.identity = nil; attachRequest = nil
            } catch { cleanupError = error }
        }
        if let cleanupError {
            failure = "The Notch panel is still stopping. Try cleanup again."
            throw cleanupError
        }
        assemblies = [:]; batch = nil; failure = nil
    }

    private func accept(_ next: HostNotchPanelBatch) throws {
        guard !retired, let identity, next.identity == identity,
            let attachRequest, next.states.count == screens.count,
            Set(next.states.map(\.displayID)) == Set(screens.keys),
            next.revision > 0, next.states.allSatisfy({ $0.revision == next.revision })
        else { throw HostNotchPanelError.staleState }
        if let batch, next.revision == batch.revision {
            guard next == batch else { throw HostNotchPanelError.staleState }
            return
        }
        let current = environment()
        var counts = next.states.flatMap(\.slots).reduce(into: current.reservedProviderScenes) {
            $0[$1.providerID, default: 0] += 1
        }
        counts["notchShelf", default: 0] += next.states.filter(\.visible).count
        guard counts.values.allSatisfy({ $0 <= HostNotchPanelState.providerSceneLimit }) else {
            throw HostNotchPanelError.capacityExceeded
        }
        var admissions: [UInt32: HostNotchPanelAdmission] = [:]
        for state in next.states {
            guard let screen = screens[state.displayID] else {
                throw HostNotchPanelError.invalidState
            }
            var reserved = counts
            if state.visible { reserved["notchShelf", default: 0] -= 1 }
            for slot in state.slots { reserved[slot.providerID, default: 0] -= 1 }
            let admission = HostNotchPanelAdmission(
                ownershipID: ownershipID, notchVersion: attachRequest.version,
                presentationID: screen.presentationID, display: screen.display,
                previousRevision: batch?.revision, activeVersions: current.activeVersions,
                layout: current.layout, hiddenWidgets: current.hiddenWidgets,
                reservedProviderScenes: reserved)
            try state.validate(admission)
            admissions[state.displayID] = admission
        }
        for state in next.states {
            let assembly: HostNotchPanelAssembly
            if let existing = assemblies[state.displayID] {
                assembly = existing
            } else {
                assembly = HostNotchPanelAssembly(
                    create: create, present: present,
                    didRelease: { [weak self] request in
                        guard let self, request.extensionID == "notchShelf" else { return }
                        guard let identity = self.identity,
                            let screen = screens.values.first(where: {
                                $0.presentationID == request.presentationID
                                    && request.section == "panel." + String($0.display.id)
                            })
                        else { throw HostNotchPanelError.staleState }
                        _ = try await self.request(
                            "notch.panel.scene.stop",
                            HostNotchPanelSceneStop(
                                identity: identity, displayID: screen.display.id,
                                presentationID: request.presentationID), timeout: 5)
                    },
                    measure: { [weak self] slotID, height in self?.measure(slotID, height: height)
                    },
                    reportFailure: { [weak self] slotID, message in
                        guard let self,
                            let slot = batch?.states.flatMap(\.slots).first(where: {
                                $0.id == slotID
                            })
                        else { return }
                        measure(
                            slotID, height: min(1200, max(1, slot.rectangle.height)), error: message
                        )
                    }
                )
                if let association { try assembly.associate(association) }
                assemblies[state.displayID] = assembly
            }
            try assembly.accept(state, admission: admissions[state.displayID]!)
        }
        batch = next
        failure = nil
    }

    private func waitForChanges() {
        waiting = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !retired, let identity, let batch {
                do {
                    let started = now()
                    let next = try await requestBatch(
                        "notch.panel.wait",
                        HostNotchPanelWait(
                            identity: identity, revision: batch.revision, timeout: 25),
                        timeout: 30)
                    try Task.checkCancellation()
                    if next.revision == batch.revision, started.duration(to: now()) < .seconds(1) {
                        throw HostNotchPanelError.invalidState
                    }
                    try accept(next)
                } catch {
                    guard !Task.isCancelled, !retired else { return }
                    failure = "The Notch panel connection stopped."
                    for assembly in assemblies.values { assembly.hide() }
                    return
                }
            }
        }
    }

    private func measure(_ slotID: UUID, height: Double, error: String? = nil) {
        guard !retired, let identity, let batch, height.isFinite, (1...1200).contains(height),
            let state = batch.states.first(where: { $0.slots.contains { $0.id == slotID } }),
            environment().activeVersions["notchShelf"] == attachRequest?.version
        else { return }
        measurements[slotID] = .init(
            identity: identity, displayID: state.displayID, presentationID: state.presentationID,
            slotID: slotID, revision: batch.revision, height: height, error: error)
        writePending()
    }

    private func writePending() {
        guard writing == nil, !retired else { return }
        writing = Task { [weak self] in
            guard let self else { return }
            defer { writing = nil }
            while !Task.isCancelled, !retired {
                do {
                    if let (id, pointer) = pointers.first {
                        pointers[id] = nil
                        _ = try await request("notch.panel.pointer", pointer, timeout: 5)
                    } else if let (id, measurement) = measurements.first {
                        measurements[id] = nil
                        _ = try await request("notch.panel.measure", measurement, timeout: 5)
                    } else {
                        return
                    }
                } catch {
                    guard !Task.isCancelled, !retired else { return }
                    failure = "The Notch panel could not update."
                    return
                }
            }
        }
    }

    private func requestBatch<T: Encodable>(_ command: String, _ body: T, timeout: Double)
        async throws -> HostNotchPanelBatch
    {
        try HostNotchPanelBatch.decode(await request(command, body, timeout: timeout))
    }

    private func request<T: Encodable>(_ command: String, _ body: T, timeout: Double)
        async throws -> Data
    {
        let data = try JSONEncoder().encode(body)
        guard data.count <= HostNotchPanelState.maximumBytes else {
            throw HostNotchPanelError.invalidState
        }
        let response = try await invoke(command, data, timeout)
        guard response.count <= HostNotchPanelState.maximumBytes else {
            throw HostNotchPanelError.invalidState
        }
        return response
    }
}
