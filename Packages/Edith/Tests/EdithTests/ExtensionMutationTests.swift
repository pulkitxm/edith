import EdithCore
import Foundation
import Testing

@testable import EdithKit

private final class ExtensionMutationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var announcements = 0

    func announce() {
        lock.lock()
        announcements += 1
        lock.unlock()
    }

    var announcementCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return announcements
    }
}

private final class ExtensionMutationDefaults: @unchecked Sendable {
    let store: UserDefaults

    init(_ store: UserDefaults) {
        self.store = store
    }
}

private struct ExtensionMutationWorld {
    let suite: String
    let defaults: UserDefaults
    let recorder = ExtensionMutationRecorder()
    let availableTools: Set<String>
    let installTool: ExtensionMutationEnvironment.InstallTool

    init(
        availableTools: Set<String> = [],
        installTool: @escaping ExtensionMutationEnvironment.InstallTool = { tool, _ in
            tool.id
        }
    ) {
        suite = "ExtensionMutationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        self.availableTools = availableTools
        self.installTool = installTool
    }

    func center(granted: [ExtensionPermission: Bool] = [:]) -> ExtensionMutationCenter {
        let defaults = ExtensionMutationDefaults(defaults)
        let availableTools = availableTools
        let toolPresent: @Sendable (String) -> Bool = { availableTools.contains($0) }
        let lifecycle = ExtensionLifecycleProbeEnvironment(
            isEnabled: { entry in
                defaults.store.object(forKey: entry.defaultsKey) as? Bool ?? false
            }, grantedPermissions: { granted },
            toolReadiness: {
                toolPresent($0) ? .installed(version: "test") : .uninstalled
            },
            helperRunning: { true }, platformCapabilities: .macOS, machineCount: { 1 },
            adapterReadiness: { _ in .ready("Ready.") })
        return ExtensionMutationCenter(
            environment: ExtensionMutationEnvironment(
                defaults: defaults.store, announceChange: { recorder.announce() },
                grantedPermissions: { granted }, toolPresent: toolPresent,
                installTool: installTool, lifecycle: lifecycle))
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}

@Suite struct ExtensionMutationTests {
    @Test func permissionAwareEnableLeavesBlockedStateUntouched() throws {
        let world = ExtensionMutationWorld()
        defer { world.cleanUp() }
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "calendar" })

        let outcome = world.center().enablePermissionAware(entry)

        guard case let .needsPermissions(plan) = outcome else {
            Issue.record("Calendar should wait for its required permission")
            return
        }
        #expect(plan.entry == entry)
        #expect(plan.required == [.calendar])
        #expect(world.defaults.object(forKey: entry.defaultsKey) == nil)
        #expect(world.defaults.object(forKey: OnboardingFlow.seenKey(for: entry)) == nil)
        #expect(world.recorder.announcementCount == 0)
    }

    @Test func permissionAwareEnableAppliesAfterTheGrant() throws {
        let world = ExtensionMutationWorld()
        defer { world.cleanUp() }
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "calendar" })

        let outcome = world.center(granted: [.calendar: true]).enablePermissionAware(entry)

        guard case let .applied(result) = outcome else {
            Issue.record("Calendar should enable after its required permission is granted")
            return
        }
        #expect(result.changed)
        #expect(result.missingRequiredPermissions.isEmpty)
        #expect(world.defaults.bool(forKey: entry.defaultsKey))
        #expect(world.defaults.bool(forKey: OnboardingFlow.seenKey(for: entry)))
        #expect(world.recorder.announcementCount == 1)
    }

    @Test func onboardingWritesOnlyTheSelectedExtensions() {
        let world = ExtensionMutationWorld()
        defer { world.cleanUp() }

        let result = world.center().completeOnboarding(
            selectedIDs: ["usage", "notchShelf"], icloudBackup: false)

        #expect(result.enabledIDs == ["usage", "notchShelf"])
        #expect(!result.iCloudBackup)
        #expect(world.defaults.bool(forKey: OnboardingFlow.completionKey))
        #expect(world.defaults.object(forKey: OnboardingFlow.iCloudBackupKey) as? Bool == false)
        for entry in ExtensionRegistry.entries {
            if result.enabledIDs.contains(entry.id) {
                #expect(world.defaults.object(forKey: entry.defaultsKey) as? Bool == true)
                #expect(
                    world.defaults.object(forKey: OnboardingFlow.seenKey(for: entry)) as? Bool
                        == true)
            } else {
                #expect(world.defaults.object(forKey: entry.defaultsKey) as? Bool == false)
                #expect(world.defaults.object(forKey: OnboardingFlow.seenKey(for: entry)) == nil)
            }
        }
    }

    @Test func setupKeepsEnablementAndReportsProvisioningFailures() async throws {
        let world = ExtensionMutationWorld { tool, _ in
            throw NSError(
                domain: "ExtensionMutationTests", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "could not install \(tool.id)"])
        }
        defer { world.cleanUp() }
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "quinjet" })

        let result = await world.center().setup(
            entry, dryRun: false, installTools: true)

        #expect(result.changed)
        #expect(world.defaults.bool(forKey: entry.defaultsKey))
        #expect(result.tools.planned == ["quinjet"])
        #expect(result.tools.installed.isEmpty)
        #expect(
            result.tools.failures == [
                ExtensionToolFailure(id: "quinjet", detail: "could not install quinjet")
            ])
        #expect(result.report.state.phase == .needsSetup)
    }

    @Test func dryRunDoesNotWriteOrInstall() async throws {
        let world = ExtensionMutationWorld { _, _ in
            Issue.record("dry-run attempted an install")
            return "unexpected"
        }
        defer { world.cleanUp() }
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "quinjet" })

        let result = await world.center().setup(
            entry, dryRun: true, installTools: true)

        #expect(!result.changed)
        #expect(result.tools.planned == ["quinjet"])
        #expect(world.defaults.object(forKey: entry.defaultsKey) == nil)
        #expect(world.recorder.announcementCount == 0)
    }

    @Test func dependencyStateMatchesTheSettingsPane() throws {
        let world = ExtensionMutationWorld()
        defer { world.cleanUp() }
        let usage = try #require(ExtensionRegistry.entries.first { $0.id == "usage" })
        let system = try #require(ExtensionRegistry.entries.first { $0.id == "system" })
        world.defaults.set(LimitProvider.codex.rawValue, forKey: AppStorageKeys.Limits.provider)
        world.defaults.set(true, forKey: AppStorageKeys.General.preventSleep)
        let center = world.center()

        _ = center.setEnabled(true, for: usage)
        _ = center.setEnabled(false, for: system)

        #expect(world.defaults.bool(forKey: AppStorageKeys.Limits.codexEnabled))
        #expect(!world.defaults.bool(forKey: AppStorageKeys.Limits.claudeEnabled))
        #expect(!world.defaults.bool(forKey: AppStorageKeys.General.preventSleep))
    }

    @Test func everyMutationDescriptorResolvesThroughTheCatalog() {
        let descriptors = ExtensionMutationOperation.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        for descriptor in descriptors {
            #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
            #expect(UserOperationCatalog.descriptor(cli: descriptor.cli) == descriptor)
            #expect(descriptor.effect == .write)
        }
    }

    @Test func everyRegisteredExtensionHasAnExplicitDetailRoute() {
        let registered = Set(ExtensionRegistry.entries.map(\.id))
        let routed = Set(ExtensionDetailRoute.allCases.map(\.rawValue))

        #expect(registered == routed)
        for entry in ExtensionRegistry.entries {
            #expect(ExtensionDetailRoute(rawValue: entry.id) != nil)
        }
    }

    @MainActor @Test func everyDisabledModalCanEnableAndDisableThroughTheMutationCenter() {
        let world = ExtensionMutationWorld()
        defer { world.cleanUp() }
        let granted = Dictionary(
            uniqueKeysWithValues: ExtensionPermission.allCases.map { ($0, true) })
        let center = world.center(granted: granted)

        for entry in ExtensionRegistry.entries {
            world.defaults.set(false, forKey: entry.defaultsKey)
            let coordinator = ExtensionModalCoordinator(entry: entry, mutationCenter: center)
            #expect(!coordinator.isEnabled)

            guard case let .applied(enabled, _) = coordinator.setEnabled(true) else {
                Issue.record("\(entry.id) should enable from its detail modal")
                continue
            }
            #expect(enabled.enabled)
            #expect(coordinator.isEnabled)

            guard case let .applied(disabled, tools) = coordinator.setEnabled(false) else {
                Issue.record("\(entry.id) should disable from its detail modal")
                continue
            }
            #expect(!disabled.enabled)
            #expect(tools.isEmpty)
            #expect(!coordinator.isEnabled)
        }
        #expect(world.recorder.announcementCount == ExtensionRegistry.entries.count * 2)
    }

    @MainActor @Test func modalEnablementPreservesRequiredToolProvisioning() throws {
        let world = ExtensionMutationWorld()
        defer { world.cleanUp() }
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "quinjet" })
        let coordinator = ExtensionModalCoordinator(entry: entry, mutationCenter: world.center())

        guard case let .applied(enabled, tools) = coordinator.setEnabled(true) else {
            Issue.record("Quinjet should enable before required tool provisioning")
            return
        }
        #expect(enabled.enabled)
        #expect(tools.map(\.id) == ["quinjet"])
        #expect(coordinator.isEnabled)

        guard case let .applied(disabled, remaining) = coordinator.setEnabled(false) else {
            Issue.record("Quinjet should disable without a provisioning prompt")
            return
        }
        #expect(!disabled.enabled)
        #expect(remaining.isEmpty)
        #expect(!coordinator.isEnabled)
    }

    @MainActor @Test func modalDefersPermissionBlockedEnablementWithoutChangingState() throws {
        let world = ExtensionMutationWorld()
        defer { world.cleanUp() }
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "calendar" })
        let coordinator = ExtensionModalCoordinator(
            entry: entry, mutationCenter: world.center())

        guard case let .needsPermissions(plan) = coordinator.setEnabled(true) else {
            Issue.record("Calendar should present its permission flow")
            return
        }
        #expect(plan.required == [.calendar])
        #expect(!coordinator.isEnabled)
        #expect(coordinator.enableAfterPermissions() == .needsPermissions(plan))
        #expect(world.recorder.announcementCount == 0)
    }
}
