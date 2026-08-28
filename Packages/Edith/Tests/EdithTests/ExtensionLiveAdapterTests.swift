import EventKit
import Foundation
import ServiceManagement
import Testing

import EdithCore
@testable import EdithKit

@Suite struct ExtensionLiveAdapterTests {
    @Test func catalogCoversEveryPreviouslyDeferredExtension() {
        #expect(
            ExtensionLiveAdapters.extensionIDs
                == ExtensionRegistry.entries.map(\.id).filter {
                    !["companion", "herdr"].contains($0)
                })
    }

    @Test func sharedFactsPreserveAllRuntimeOutcomes() {
        let values = [
            ExtensionAdapterFacts(
                installed: false, readyDetail: "ready", uninstalledDetail: "missing"
            ).readiness,
            ExtensionAdapterFacts(contentCount: 0, readyDetail: "ready").readiness,
            ExtensionAdapterFacts(loading: true, readyDetail: "ready").readiness,
            ExtensionAdapterFacts(
                unsupportedReason: "unsupported", readyDetail: "ready"
            ).readiness,
            ExtensionAdapterFacts(failure: "failed", readyDetail: "ready").readiness,
            ExtensionAdapterFacts(readyDetail: "ready").readiness,
        ]

        #expect(
            values == [
                .uninstalled("missing"), .empty("The extension is ready, but has no content yet."),
                .loading("The extension runtime is loading."), .unsupported("unsupported"),
                .failed("failed"), .ready("ready"),
            ])
    }

    @Test func attentionRequiresAnEnabledTrackingSource() {
        #expect(
            ExtensionLiveAdapters.attentionReadiness(settings: AttentionSettings())
                == .needsSetup("Turn on application tracking, browser tracking, or both."))
        #expect(
            ExtensionLiveAdapters.attentionReadiness(
                settings: AttentionSettings(isEnabled: true, trackingEnabled: true))
                == .ready("Attention tracking is configured for the selected sources."))
        #expect(
            ExtensionLiveAdapters.attentionReadiness(
                settings: AttentionSettings(isEnabled: true, browserTrackingEnabled: true))
                == .ready("Attention tracking is configured for the selected sources."))
    }

    @Test func usageDetectsMissingLoadingEmptyReadyAndCorruptData() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("refresh")
        let data = root.appendingPathComponent("usage.json")
        try Data().write(to: script)

        #expect(
            ExtensionLiveAdapters.usageReadiness(script: nil, data: data, loading: false)
                == .uninstalled("The bundled usage collector is missing."))
        #expect(
            ExtensionLiveAdapters.usageReadiness(script: script, data: data, loading: true)
                == .loading("Usage providers are being refreshed."))
        #expect(
            ExtensionLiveAdapters.usageReadiness(script: script, data: data, loading: false)
                == .empty("No usage sample has been collected yet."))

        try Data(#"{"daily":[{"period":"2026-08-23"}]}"#.utf8).write(to: data)
        #expect(
            ExtensionLiveAdapters.usageReadiness(script: script, data: data, loading: false)
                == .ready("Usage data is readable and current."))

        try Data("not json".utf8).write(to: data)
        guard
            case .failed = ExtensionLiveAdapters.usageReadiness(
                script: script, data: data, loading: false
            )
        else {
            Issue.record("corrupt usage data did not fail")
            return
        }
    }

    @Test func quinjetValidatesInstallationAndTerminalConfiguration() {
        let suite = "test.extension-adapter.quinjet.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let executable = URL(fileURLWithPath: "/usr/local/bin/quinjet")

        #expect(
            ExtensionLiveAdapters.quinjetReadiness(
                defaults: defaults, executable: nil, cmux: nil)
                == .uninstalled("The Quinjet executable is not installed."))
        #expect(
            ExtensionLiveAdapters.quinjetReadiness(
                defaults: defaults, executable: executable, cmux: nil)
                == .ready("Quinjet and its embedded terminal are ready."))

        defaults.set(QuinjetThemePreference.app, forKey: AppStorageKeys.Quinjet.theme)
        #expect(
            ExtensionLiveAdapters.quinjetReadiness(
                defaults: defaults, executable: executable, cmux: nil)
                == .ready("Quinjet and its embedded terminal are ready."))
        defaults.set("future-theme", forKey: AppStorageKeys.Quinjet.theme)
        #expect(
            ExtensionLiveAdapters.quinjetReadiness(
                defaults: defaults, executable: executable, cmux: nil)
                == .ready("Quinjet and its embedded terminal are ready."))

        defaults.set("cmux", forKey: AppStorageKeys.Quinjet.terminal)
        #expect(
            ExtensionLiveAdapters.quinjetReadiness(
                defaults: defaults, executable: executable, cmux: nil)
                == .needsSetup("cmux is selected, but cmux is not installed in Applications."))
    }

    @Test func machineAdapterRejectsCorruptAndIncompleteConfiguration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("machines.json")

        #expect(
            ExtensionLiveAdapters.machinesReadiness(file: file)
                == .empty("No SSH machines are configured."))

        try Data("broken".utf8).write(to: file)
        guard case .failed = ExtensionLiveAdapters.machinesReadiness(file: file) else {
            Issue.record("corrupt machine configuration did not fail")
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([Machine(name: "Build", host: "build.local")]).write(to: file)
        #expect(
            ExtensionLiveAdapters.machinesReadiness(file: file)
                == .ready("Configured machines: 1."))

        try encoder.encode([Machine(name: "Build", host: "", port: 0)]).write(to: file)
        #expect(
            ExtensionLiveAdapters.machinesReadiness(file: file)
                == .needsSetup("A machine has an empty name or host, or an invalid SSH port."))
    }

    @Test func hardwareAdaptersDifferentiateReadyEmptyUnsupportedAndFailure() {
        #expect(
            ExtensionLiveAdapters.systemStatsReadiness(
                ticks: CPUTicks(used: 1, total: 2), physicalMemory: 1)
                == .ready("CPU and memory metrics can be sampled."))
        #expect(
            ExtensionLiveAdapters.systemStatsReadiness(ticks: nil, physicalMemory: 1)
                == .failed("CPU metrics could not be sampled."))
        #expect(
            ExtensionLiveAdapters.systemStatsReadiness(
                ticks: CPUTicks(used: 1, total: 2), physicalMemory: 0)
                == .unsupported("Physical memory metrics are unavailable."))
        #expect(
            ExtensionLiveAdapters.microphoneReadiness(devices: .success(2))
                == .ready("Controllable microphone inputs: 2."))
        #expect(
            ExtensionLiveAdapters.microphoneReadiness(devices: .success(0))
                == .empty("No microphone input device is available."))
        #expect(
            ExtensionLiveAdapters.microphoneReadiness(devices: .failure(.audio(-1)))
                == .failed("Core Audio device discovery failed with status -1."))
    }

    @Test func lidAwakeMapsEveryServiceManagementState() {
        #expect(
            ExtensionLiveAdapters.lidAwakeReadiness(status: .enabled)
                == .ready("The privileged sleep helper is registered and enabled."))
        #expect(
            ExtensionLiveAdapters.lidAwakeReadiness(status: .requiresApproval)
                == .needsSetup(
                    "The sleep helper needs approval in System Settings > General > Login Items."))
        #expect(
            ExtensionLiveAdapters.lidAwakeReadiness(status: .notRegistered)
                == .uninstalled("The privileged sleep helper is not registered."))
        #expect(
            ExtensionLiveAdapters.lidAwakeReadiness(status: .notFound)
                == .uninstalled("The privileged sleep helper is missing from Edith.app."))
        #expect(
            ExtensionLiveAdapters.lidAwakeReadiness(helperStatus: "awaitingApproval")
                == .needsSetup(
                    "The sleep helper needs approval in System Settings > General > Login Items."))
    }

    @Test func musicAdapterDetectsMissingEmptyReadyAndInvalidLibraries() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")

        #expect(
            ExtensionLiveAdapters.musicReadiness(directory: missing)
                == .uninstalled("The configured music library folder does not exist."))
        #expect(
            ExtensionLiveAdapters.musicReadiness(directory: root)
                == .empty("The music library contains no supported audio files."))

        try Data("audio".utf8).write(to: root.appendingPathComponent("track.mp3"))
        #expect(
            ExtensionLiveAdapters.musicReadiness(directory: root)
                == .ready("Playable tracks in the library: 1."))

        let file = root.appendingPathComponent("library")
        try Data().write(to: file)
        #expect(
            ExtensionLiveAdapters.musicReadiness(directory: file)
                == .failed("The configured music library path is not a folder."))
    }

    @Test func mediaToolkitAdapterValidatesStoredDefaults() {
        let suite = "test.extension-adapter.media-toolkit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(
            ExtensionLiveAdapters.mediaToolkitReadiness(defaults: defaults)
                == .ready("ImageIO and AVFoundation processing defaults are ready."))
        defaults.set("webp", forKey: AppStorageKeys.MediaToolkit.imageFormat)
        #expect(
            ExtensionLiveAdapters.mediaToolkitReadiness(defaults: defaults)
                == .needsSetup(
                    "Reset the stored Media Toolkit format, quality, dimensions or size limit."))
    }

    @Test func calendarAdapterMapsPermissionAndContentStates() {
        #expect(
            ExtensionLiveAdapters.calendarReadiness(
                status: .fullAccess, calendarCount: { 2 })
                == .ready("Readable calendars: 2."))
        #expect(
            ExtensionLiveAdapters.calendarReadiness(
                status: .fullAccess, calendarCount: { 0 })
                == .empty("Calendar access is granted, but no calendars are available."))
        #expect(
            ExtensionLiveAdapters.calendarReadiness(status: .notDetermined)
                == .needsSetup("Calendar access has not been requested."))
        #expect(
            ExtensionLiveAdapters.calendarReadiness(status: .restricted)
                == .unsupported("macOS does not allow Edith to read calendar events."))
    }

    @Test func shelfAdapterReportsEmptyReadyDegradedAndCorruptIndexes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            ExtensionLiveAdapters.shelfReadiness(root: root)
                == .empty("The shelf is ready and has no parked files."))

        let present = ShelfItem(id: UUID(), name: "present.txt", addedAt: Date())
        let missing = ShelfItem(id: UUID(), name: "missing.txt", addedAt: Date())
        try Data().write(to: root.appendingPathComponent(present.name))
        ShelfIndex.save([present], to: root)
        #expect(
            ExtensionLiveAdapters.shelfReadiness(root: root)
                == .ready("Parked shelf files: 1."))

        ShelfIndex.save([present, missing], to: root)
        #expect(
            ExtensionLiveAdapters.shelfReadiness(root: root)
                == .degraded("Shelf items missing on disk: 1."))

        try Data("broken".utf8).write(to: ShelfIndex.indexFile(in: root))
        guard case .failed = ExtensionLiveAdapters.shelfReadiness(root: root) else {
            Issue.record("corrupt shelf data did not fail")
            return
        }
    }

    @Test func shelfAdapterRejectsRedirectedEmptyStorage() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("Shelf")
        let outside = container.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)

        guard case .failed = ExtensionLiveAdapters.shelfReadiness(root: root) else {
            Issue.record("redirected empty shelf storage did not fail")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func clipboardAdapterReportsEmptyReadyDegradedAndCorruptStorage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("index.jsonl")
        let blobs = root.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)

        #expect(
            ExtensionLiveAdapters.clipboardReadiness(index: index, blobs: blobs)
                == .empty("Clipboard history is ready and empty."))

        let entry = ClipboardEntry(
            sha256: "abc", types: ["public.utf8-plain-text"], ext: "txt",
            sourceApp: nil, sourceBundleID: nil, size: 4, preview: "text")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try (encoder.encode(entry) + Data("\n".utf8)).write(to: index)
        #expect(
            ExtensionLiveAdapters.clipboardReadiness(index: index, blobs: blobs)
                == .degraded("Clipboard entries missing payloads: 1."))

        try Data("text".utf8).write(to: blobs.appendingPathComponent("abc.txt"))
        #expect(
            ExtensionLiveAdapters.clipboardReadiness(index: index, blobs: blobs)
                == .ready("Clipboard history entries: 1."))

        try Data("broken".utf8).write(to: index)
        guard
            case .failed = ExtensionLiveAdapters.clipboardReadiness(
                index: index, blobs: blobs
            )
        else {
            Issue.record("corrupt clipboard data did not fail")
            return
        }
    }

    @Test func preferenceAdaptersValidateStoredConfiguration() async {
        let suite = "test.extension-adapter.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Double.nan, forKey: AppStorageKeys.FocusDim.intensity)
        #expect(
            await ExtensionLiveAdapters.focusDimReadiness(defaults: defaults)
                == .needsSetup(
                    "A stored dim intensity, animation duration, or display mode is invalid."))

        defaults.removeObject(forKey: AppStorageKeys.FocusDim.intensity)
        #expect(
            ExtensionLiveAdapters.presenterReadiness(defaults: defaults)
                == .ready("Presenter protects 4 data categories."))
        for key in [
            AppStorageKeys.Presenter.blurAgents, AppStorageKeys.Presenter.blurCalendar,
            AppStorageKeys.Presenter.blurMoney, AppStorageKeys.Presenter.blurMusic,
            AppStorageKeys.Presenter.blurUsage,
        ] {
            defaults.set(false, forKey: key)
        }
        #expect(
            ExtensionLiveAdapters.presenterReadiness(defaults: defaults)
                == .needsSetup("Presenter has no protected data categories enabled."))

        defaults.set(Data("broken".utf8), forKey: "colorPickerHistory")
        guard
            case .failed = await ExtensionLiveAdapters.colorPickerReadiness(
                defaults: defaults
            )
        else {
            Issue.record("corrupt color history did not fail")
            return
        }
    }

    @Test func probeReportsAdapterRecoveryToCliAndUIConsumers() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "music" })
        let probe = ExtensionLifecycleProbe(
            environment: ExtensionLifecycleProbeEnvironment(
                isEnabled: { _ in true }, grantedPermissions: { [:] },
                toolReadiness: { _ in .uninstalled }, helperRunning: { true },
                platformCapabilities: .macOS, machineCount: { 1 },
                adapterReadiness: { _ in .failed("Library scan failed.") }))
        let report = await probe.report(for: entry)

        #expect(report.state.phase == .failed)
        #expect(report.state.runtimePhase == .error)
        #expect(report.state.issues.map(\.id).contains("backend.music"))
        #expect(
            report.state.issues.first { $0.id == "backend.music" }?.recoveryCommand
                == "ed music library ~/Music")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extension-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
