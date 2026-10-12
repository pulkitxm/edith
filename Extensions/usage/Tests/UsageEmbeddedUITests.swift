import EdithExtensionSupport
import Foundation
import Testing
@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageEmbeddedUITests {
    @Test func owningCLIConfigChangesReachOpenUIWithoutSendingThemBack() async throws {
        let suite = "usage-ui-live-config-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("all", forKey: "dashRange")
        let controller = UsageWorkerController(
            dataDirectory: Repo.dataDir, collect: { _, _ in Data() })
        let service = UsageUICommands(controller: controller, defaults: defaults)
        var writes = 0
        let client = UsageUIClient(invoke: { command, payload in
            if command == "usage.ui.preferences.set" { writes += 1 }
            return try await service.execute(command, payload: payload)
        })
        defer { client.stop(); service.shutdown() }
        try await client.prepare()
        #expect(SharedDefaults.store.string(forKey: "dashRange") == "all")
        let executor = UsageConfigurationExecutor(shared: defaults, announceChange: {})
        try executor.set("week", forKey: "dashRange")
        try await client.refreshPreferences()
        #expect(SharedDefaults.store.string(forKey: "dashRange") == "week")
        try executor.unset("dashRange")
        try await client.refreshPreferences()
        #expect(SharedDefaults.store.object(forKey: "dashRange") == nil)
        try await Task.sleep(for: .milliseconds(30))
        #expect(writes == 0)
        await controller.shutdown()
    }

    @Test func enginePreferencePollingKeepsAnUnacknowledgedUIEdit() async throws {
        let suite = "usage-ui-pending-config-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("all", forKey: "dashRange")
        defaults.set("tokens", forKey: "dashHeatMetric")
        let controller = UsageWorkerController(
            dataDirectory: Repo.dataDir, collect: { _, _ in Data() })
        let service = UsageUICommands(controller: controller, defaults: defaults)
        var gate: CheckedContinuation<Void, Never>?
        let client = UsageUIClient(invoke: { command, payload in
            if command == "usage.ui.preferences.set" {
                await withCheckedContinuation { gate = $0 }
            }
            return try await service.execute(command, payload: payload)
        })
        defer { gate?.resume(); client.stop(); service.shutdown() }
        try await client.prepare()
        SharedDefaults.store.set("week", forKey: "dashRange")
        try await client.refreshPreferences()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while gate == nil && ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate != nil)
        let executor = UsageConfigurationExecutor(shared: defaults, announceChange: {})
        try executor.set("cost", forKey: "dashHeatMetric")
        try await client.refreshPreferences()
        #expect(SharedDefaults.store.string(forKey: "dashRange") == "week")
        gate?.resume(); gate = nil
        while defaults.string(forKey: "dashRange") != "week" && ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(defaults.string(forKey: "dashRange") == "week")
        try await Task.sleep(for: .milliseconds(30))
        try await client.refreshPreferences()
        #expect(SharedDefaults.store.string(forKey: "dashRange") == "week")
        #expect(SharedDefaults.store.string(forKey: "dashHeatMetric") == "cost")
        await controller.shutdown()
    }

    private let data = Data(
        #"{"schemaVersion":8,"generatedAt":"2026-10-09T12:00:00Z","sources":["sample"],"defaultSources":["sample"],"sourceMeta":{"sample":{"label":"Sample source"}},"sessions":[],"totals":{"cost":2,"tokens":150,"inputTokens":120,"outputTokens":30,"cacheCreationTokens":0,"cacheReadTokens":0,"bySource":{"sample":{"cost":2,"tokens":150}}},"daily":[{"period":"2026-10-09","bySource":{"sample":[{"modelName":"Sample model","inputTokens":120,"outputTokens":30,"cacheCreationTokens":0,"cacheReadTokens":0,"cost":2}]},"projects":[],"hours":[{"hour":0,"cost":0,"tokens":0,"bySource":{}},{"hour":1,"cost":0,"tokens":0,"bySource":{}},{"hour":2,"cost":0,"tokens":0,"bySource":{}},{"hour":3,"cost":0,"tokens":0,"bySource":{}},{"hour":4,"cost":0,"tokens":0,"bySource":{}},{"hour":5,"cost":0,"tokens":0,"bySource":{}},{"hour":6,"cost":0,"tokens":0,"bySource":{}},{"hour":7,"cost":0,"tokens":0,"bySource":{}},{"hour":8,"cost":0,"tokens":0,"bySource":{}},{"hour":9,"cost":0,"tokens":0,"bySource":{}},{"hour":10,"cost":0,"tokens":0,"bySource":{}},{"hour":11,"cost":0,"tokens":0,"bySource":{}},{"hour":12,"cost":0,"tokens":0,"bySource":{}},{"hour":13,"cost":0,"tokens":0,"bySource":{}},{"hour":14,"cost":0,"tokens":0,"bySource":{}},{"hour":15,"cost":0,"tokens":0,"bySource":{}},{"hour":16,"cost":0,"tokens":0,"bySource":{}},{"hour":17,"cost":0,"tokens":0,"bySource":{}},{"hour":18,"cost":0,"tokens":0,"bySource":{}},{"hour":19,"cost":0,"tokens":0,"bySource":{}},{"hour":20,"cost":0,"tokens":0,"bySource":{}},{"hour":21,"cost":0,"tokens":0,"bySource":{}},{"hour":22,"cost":0,"tokens":0,"bySource":{}},{"hour":23,"cost":0,"tokens":0,"bySource":{}}]}]}"#
            .utf8)

    @Test func originalDashboardUsesCheckedEngineDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent("usage.json"))
        let defaults = try #require(UserDefaults(suiteName: "usage-ui-test-" + UUID().uuidString))
        let controller = UsageWorkerController(
            dataDirectory: directory, collect: { _, _ in Data() })
        let service = UsageUICommands(
            controller: controller, directory: directory, defaults: defaults)
        let client = UsageUIClient(invoke: { try await service.execute($0, payload: $1) })
        let model = DashboardModel(
            preferences: defaults,
            homeUsageStore: HomeUsageSnapshotStore(
                file: directory.appendingPathComponent("unused.json")))
        UsageUIClient.current = client
        defer { client.stop(); UsageUIClient.current = nil; model.shutdown(); service.shutdown() }
        await model.load()
        await model.awaitPendingComputation()
        #expect(model.loaded)
        #expect(model.modelTotals.first?.tokens == 150)
        #expect(model.modelTotals.first?.cost == 2)
        #expect(model.homeUsage.calendarDays.count == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("unused.json").path))
        let value = UsageUIPreferences(values: [AppStorageKeys.Budget.capPercent: .number(35)])
        _ = try await service.execute(
            "usage.ui.preferences.set", payload: JSONEncoder().encode(value))
        #expect(defaults.double(forKey: AppStorageKeys.Budget.capPercent) == 35)
        await controller.shutdown()
    }

    @Test func firstDashboardRestoresEnginePreferencesBeforeReadingItsDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent("usage.json"))
        let suite = "usage-ui-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("yesterday", forKey: "dashRange")
        let controller = UsageWorkerController(
            dataDirectory: directory, collect: { _, _ in Data() })
        let service = UsageUICommands(
            controller: controller, directory: directory, defaults: defaults)
        var gate: CheckedContinuation<Void, Never>?
        var documentRequested = false
        let client = UsageUIClient(invoke: { command, payload in
            if command == "usage.ui.preferences" { await withCheckedContinuation { gate = $0 } }
            if command == "usage.ui.document" { documentRequested = true }
            return try await service.execute(command, payload: payload)
        })
        let model = DashboardModel(
            homeUsageStore: HomeUsageSnapshotStore(
                file: directory.appendingPathComponent("unused.json")))
        UsageUIClient.current = client
        defer { client.stop(); UsageUIClient.current = nil; model.shutdown(); service.shutdown() }
        let load = Task { await model.load() }
        while gate == nil { await Task.yield() }
        #expect(!documentRequested && !model.loaded)
        gate?.resume()
        await load.value
        await model.awaitPendingComputation()
        #expect(model.loaded && model.range == .yesterday && client.prepared)
        await controller.shutdown()
    }

    @Test func failedPreferenceLoadCanRecoverBeforeShowingOwnedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent("usage.json"))
        let suite = "usage-ui-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = UsageWorkerController(
            dataDirectory: directory, collect: { _, _ in Data() })
        let service = UsageUICommands(
            controller: controller, directory: directory, defaults: defaults)
        var attempts = 0
        let client = UsageUIClient(invoke: { command, payload in
            if command == "usage.ui.preferences" {
                attempts += 1
                if attempts == 1 { throw ExtensionPeerError.unavailable }
            }
            return try await service.execute(command, payload: payload)
        })
        defer { client.stop(); service.shutdown() }
        await #expect(throws: ExtensionPeerError.self) { try await client.prepare() }
        #expect(!client.prepared)
        let document = try await client.document()
        #expect(client.prepared && attempts == 2 && document.daily.count == 1)
        await controller.shutdown()
    }

    @Test func rejectsArbitraryPreferencesAndDocumentOffsets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: "usage-ui-test-" + UUID().uuidString))
        let controller = UsageWorkerController(
            dataDirectory: directory, collect: { _, _ in Data() })
        let service = UsageUICommands(
            controller: controller, directory: directory, defaults: defaults)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await service.execute(
                "usage.ui.preferences.set",
                payload: JSONEncoder().encode(
                    UsageUIPreferences(values: ["unrelatedPreference": .bool(true)])))
        }
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await service.execute(
                "usage.ui.chunk",
                payload: Data(
                    #"{"id":"00000000-0000-0000-0000-000000000000","offset":-1}"#.utf8))
        }
        service.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await service.execute("usage.ui.preferences", payload: Data("{}".utf8))
        }
        await controller.shutdown()
    }

    @Test func stoppedClientRejectsLateReplyAndInvalidatesExactlyOnce() async throws {
        var continuation: CheckedContinuation<Data, Never>?
        var invalidations = 0
        let client = UsageUIClient(
            invoke: { _, _ in
                await withCheckedContinuation { continuation = $0 }
            }, invalidate: { invalidations += 1 })
        let request = Task { try await client.invoke("usage.status") }
        while continuation == nil { await Task.yield() }
        client.stop(); client.stop()
        continuation?.resume(returning: Data("{}".utf8))
        await #expect(throws: ExtensionPeerError.self) { try await request.value }
        #expect(invalidations == 1)
    }

    @Test func stoppingCancelsOwnedRequestsAndCallerCancellationPropagates() async throws {
        var started = false
        var cancelled = false
        let client = UsageUIClient(invoke: { _, _ in
            started = true
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelled = Task.isCancelled; throw error
            }
            return Data("{}".utf8)
        })
        let request = Task { try await client.invoke("usage.status") }
        while !started { await Task.yield() }
        client.stop()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(cancelled)
        started = false; cancelled = false
        let next = UsageUIClient(invoke: { _, _ in
            started = true
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelled = Task.isCancelled; throw error
            }
            return Data("{}".utf8)
        })
        let caller = Task { try await next.invoke("usage.status") }
        while !started { await Task.yield() }
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(cancelled)
        next.stop()
    }

    @Test func ownedLimitsPreserveProviderWindowsAndHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: "usage-ui-test-" + UUID().uuidString))
        let now = Date()
        var history = LimitsHistory(url: directory.appendingPathComponent("limits-history.jsonl"))
        let appended = history.append(
            provider: .claude,
            session: LimitWindow(percent: 42, resetsAt: now.addingTimeInterval(3600)),
            week: LimitWindow(percent: 18, resetsAt: now.addingTimeInterval(86400)), now: now)
        #expect(appended)
        let controller = UsageWorkerController(
            dataDirectory: directory, collect: { _, _ in Data() })
        let service = UsageUICommands(
            controller: controller, directory: directory, defaults: defaults)
        let client = UsageUIClient(invoke: { try await service.execute($0, payload: $1) })
        defer { client.stop() }
        let value = try await client.limits(provider: .claude)
        #expect(value.provider == .claude)
        #expect(value.providers[.claude]?.session?.percent == 42)
        #expect(value.providers[.claude]?.week?.percent == 18)
        #expect(value.points.last?.s == 42)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await service.execute(
                "usage.ui.preferences.set",
                payload: JSONEncoder().encode(
                    UsageUIPreferences(values: [AppStorageKeys.Budget.enabled: .number(2)])))
        }
        service.shutdown(); await controller.shutdown()
    }

    @Test func fullLimitsHistoryCrossesTransportCapWithoutDroppingPoints() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let row =
            #"{"ts":"2026-10-09T12:00:00Z","p":"claude","s":42,"w":18,"sr":"2026-10-09T13:00:00Z","wr":"2026-10-10T12:00:00Z"}"#
            + "\n"
        try Data(String(repeating: row, count: 115_000).utf8)
            .write(to: directory.appendingPathComponent("limits-history.jsonl"))
        let suite = "usage-ui-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = UsageWorkerController(
            dataDirectory: directory, collect: { _, _ in Data() })
        let service = UsageUICommands(
            controller: controller, directory: directory, defaults: defaults)
        var chunks = 0
        var byteCount = 0
        let client = UsageUIClient(invoke: { command, payload in
            let reply = try await service.execute(command, payload: payload)
            #expect(reply.count <= ExtensionPeerEndpoint.maximumPayloadBytes)
            if command == "usage.ui.limits" {
                let object = try #require(
                    try JSONSerialization.jsonObject(with: reply) as? [String: Any])
                byteCount = try #require(object["byteCount"] as? Int)
            }
            if command == "usage.ui.chunk" { chunks += 1 }
            return reply
        })
        defer { client.stop(); service.shutdown() }
        let snapshot = try await client.limits(provider: .claude)
        #expect(byteCount > ExtensionPeerEndpoint.maximumPayloadBytes)
        #expect(chunks > 1)
        #expect(snapshot.points.count == 115_000)
        #expect(snapshot.points.first?.s == 42 && snapshot.points.last?.w == 18)
        #expect(snapshot.providers[.claude]?.week?.percent == 18)
        let latest: UsageUILimitsSummary = try await client.value("usage.ui.limits.latest")
        #expect(latest.providers[.claude]?.session?.percent == 42)
        await controller.shutdown()
    }

    @Test func statuslineUsesOwnedSettingsAndDecodesRecordedTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: "usage-ui-test-" + UUID().uuidString))
        let commands = UsageStatusLineCommands(
            settings: directory.appendingPathComponent("settings.json"),
            history: directory.appendingPathComponent("limits-history.jsonl"),
            executable: "/tmp/synthetic-ed", defaults: defaults)
        let client = UsageUIClient(invoke: { try await commands.execute($0, payload: $1) })
        _ = try await client.invoke("usage.statusline.install")
        _ = try await client.invoke(
            "usage.statusline.hook",
            payload: Data(#"{"rate_limits":{"five_hour":{"used_percentage":42}}}"#.utf8))
        let status: UsageStatusLineStatusResponse = try await client.value(
            "usage.statusline.status")
        #expect(status.installed && status.recordedAt != nil)
        client.stop(); try await commands.shutdown()
    }

    @Test func completedBetweenPollsRefreshStillNotifiesOriginalPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: "usage-ui-test-" + UUID().uuidString))
        let controller = UsageWorkerController(
            dataDirectory: directory, collect: { _, _ in Data() })
        let ui = UsageUICommands(controller: controller, directory: directory, defaults: defaults)
        let reports = UsageReportCommands(
            controller: controller,
            store: SurfaceUsageStore(url: directory.appendingPathComponent("usage.json")),
            directory: directory)
        let client = UsageUIClient(invoke: { command, payload in
            if command.hasPrefix("usage.ui.") {
                return try await ui.execute(command, payload: payload)
            }
            return try await reports.execute(command, payload: payload)
        })
        var updates = 0
        let observer = UsageEvents.observe(UsageEvents.usageUpdated) { updates += 1 }
        defer { UsageEvents.stopObserving(observer); client.stop(); ui.shutdown() }
        try await client.refreshState()
        #expect(updates == 0)
        try data.write(to: directory.appendingPathComponent("usage.json"))
        try await client.refreshState()
        #expect(!client.refreshing && updates == 1)
        try await client.refreshState()
        #expect(updates == 1)
        await reports.shutdown(); await controller.shutdown()
    }

    @Test func nativeHomeCardKeepsSourceAndDayConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let today = CalendarDay.stamp(Date())
        let document = Data(
            ("{\"daily\":[{\"period\":\"" + today
                + "\",\"bySource\":{\"one\":[{\"modelName\":\"sample\",\"inputTokens\":12,\"cost\":1}],\"two\":[{\"modelName\":\"sample\",\"inputTokens\":8,\"cost\":2}]}}]}")
                .utf8)
        try document.write(to: directory.appendingPathComponent("usage.json"))
        let defaults = try #require(UserDefaults(suiteName: "usage-ui-test-" + UUID().uuidString))
        let controller = UsageWorkerController(
            dataDirectory: directory, collect: { _, _ in Data() })
        let ui = UsageUICommands(controller: controller, directory: directory, defaults: defaults)
        var tile = SurfaceTile(.usage); tile.days = 1; tile.sourceIDs = ["two"]
        let reply = try await ui.execute("usage.ui.card", payload: JSONEncoder().encode(tile))
        let snapshot = try JSONDecoder().decode(SurfaceUsageSnapshot.self, from: reply)
        #expect(snapshot.today.tokens == 8 && snapshot.today.cost == 2)
        #expect(snapshot.days.count == 1 && snapshot.providers.map(\.id) == ["two"])
        tile.days = 0
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await ui.execute("usage.ui.card", payload: JSONEncoder().encode(tile))
        }
        ui.shutdown(); await controller.shutdown()
    }

    @Test func rejectsCorruptEngineSnapshot() async throws {
        let data = data
        let id = UUID()
        let client = UsageUIClient(invoke: { operation, _ in
            if operation == "usage.ui.preferences" {
                return try JSONEncoder().encode(UsageUIPreferences(values: [:]))
            }
            if operation == "usage.ui.document" {
                return try JSONSerialization.data(withJSONObject: [
                    "id": id.uuidString,
                    "byteCount": data.count, "sha256": String(repeating: "0", count: 64),
                ])
            }
            if operation == "usage.ui.chunk" {
                return try JSONEncoder().encode(
                    UsageMachinesPeer.Chunk(offset: 0, data: data, finished: true))
            }
            return Data("{}".utf8)
        })
        await #expect(throws: ExtensionPeerError.self) { try await client.document() }
        client.stop()
    }
}
