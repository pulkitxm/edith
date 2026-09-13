import Foundation
import Testing

@testable import EdithCore
@testable import EdithKit

@Suite struct QuickActionOperationTests {
    final class State {
        var appearance = QuickActionAppearance.light
        var keyboardLevel: Float? = 0.7
        var hiddenFiles = false
        var desktopIcons = true
        var volumes = [(URL(fileURLWithPath: "/Volumes/Work"), "Work")]
        var emptiedTrash = false
        var locked = false
    }

    @Test func snapshotReportsEveryCurrentState() {
        let state = State()
        let snapshot = center(state).snapshot()

        #expect(snapshot.appearance == .light)
        #expect(snapshot.keyboardLightAvailable)
        #expect(snapshot.keyboardLightEnabled == true)
        #expect(!snapshot.hiddenFilesShown)
        #expect(snapshot.desktopIconsShown)
        #expect(
            snapshot.ejectableVolumes == [QuickActionVolume(name: "Work", path: "/Volumes/Work")])
    }

    @Test func reversibleActionsToggleTheirState() async throws {
        let state = State()
        let center = center(state)

        #expect(try await center.perform(.appearance).snapshot.appearance == .dark)
        #expect(try await center.perform(.keyboardLight).snapshot.keyboardLightEnabled == false)
        #expect(try await center.perform(.hiddenFiles).snapshot.hiddenFilesShown)
        #expect(try await center.perform(.desktopIcons).snapshot.desktopIconsShown == false)
    }

    @Test func operationalActionsReportEffects() async throws {
        let state = State()
        let center = center(state)

        let trash = try await center.perform(.emptyTrash)
        #expect(state.emptiedTrash)
        #expect(trash.changed)

        let eject = try await center.perform(.ejectDisks)
        #expect(eject.affectedCount == 1)
        #expect(eject.snapshot.ejectableVolumes.isEmpty)

        let lock = try await center.perform(.lockScreen)
        #expect(state.locked)
        #expect(lock.changed)
    }

    @Test func unsupportedKeyboardLightFailsWithoutChangingState() async {
        let state = State()
        state.keyboardLevel = nil

        await #expect(throws: QuickActionError.self) {
            try await center(state).perform(.keyboardLight)
        }
        #expect(state.keyboardLevel == nil)
    }

    @Test func descriptorsCoverEveryActionAndProtectTrash() {
        #expect(Set(QuickAction.allCases.map(\.descriptor.id)).count == QuickAction.allCases.count)
        #expect(QuickAction.emptyTrash.descriptor.effect == .destructive)
        #expect(QuickAction.emptyTrash.descriptor.requiresPreview)
        #expect(
            QuickAction.allCases.filter { $0 != .emptyTrash }.allSatisfy {
                !$0.descriptor.requiresPreview
            })
    }

    @Test func volumePolicyOnlyAllowsLocalExternalNonRootVolumes() {
        #expect(
            QuickActionVolumePolicy.shouldEject(
                isInternal: false, isRemovable: false, isEjectable: true, isLocal: true,
                isRootFileSystem: false, path: "/Volumes/Backup"))
        #expect(
            QuickActionVolumePolicy.shouldEject(
                isInternal: true, isRemovable: true, isEjectable: true, isLocal: true,
                isRootFileSystem: false, path: "/Volumes/Card"))
        #expect(
            !QuickActionVolumePolicy.shouldEject(
                isInternal: true, isRemovable: false, isEjectable: false, isLocal: true,
                isRootFileSystem: false, path: "/System/Volumes/Data"))
        #expect(
            !QuickActionVolumePolicy.shouldEject(
                isInternal: false, isRemovable: true, isEjectable: true, isLocal: false,
                isRootFileSystem: false, path: "/Volumes/Network"))
        #expect(
            !QuickActionVolumePolicy.shouldEject(
                isInternal: false, isRemovable: true, isEjectable: true, isLocal: true,
                isRootFileSystem: true, path: "/"))
    }

    @Test func lifecycleReadinessTreatsKeyboardLightAsOptional() {
        let available = QuickActionsSnapshot(
            appearance: .dark, keyboardLightAvailable: true, keyboardLightEnabled: true,
            hiddenFilesShown: false, desktopIconsShown: true, ejectableVolumes: [])
        let unavailable = QuickActionsSnapshot(
            appearance: .dark, keyboardLightAvailable: false, keyboardLightEnabled: nil,
            hiddenFilesShown: false, desktopIconsShown: true, ejectableVolumes: [])

        #expect(
            ExtensionLiveAdapters.quickActionsReadiness(snapshot: available)
                == .ready("All 7 Quick Actions are available."))
        #expect(
            ExtensionLiveAdapters.quickActionsReadiness(snapshot: unavailable)
                == .ready(
                    "6 Quick Actions are available; this Mac has no controllable keyboard light."))
    }

    private func center(_ state: State) -> QuickActionCenter {
        QuickActionCenter(
            environment: QuickActionEnvironment(
                appearance: { state.appearance },
                toggleAppearance: {
                    state.appearance = state.appearance == .dark ? .light : .dark
                },
                keyboardLight: { state.keyboardLevel },
                setKeyboardLight: {
                    state.keyboardLevel = $0
                    return true
                },
                finderFlag: { key, fallback in
                    switch key {
                    case "AppleShowAllFiles": return state.hiddenFiles
                    case "CreateDesktop": return state.desktopIcons
                    default: return fallback
                    }
                },
                setFinderFlag: { key, value in
                    if key == "AppleShowAllFiles" { state.hiddenFiles = value }
                    if key == "CreateDesktop" { state.desktopIcons = value }
                },
                volumes: { state.volumes.map { (url: $0.0, name: $0.1) } },
                eject: { url in state.volumes.removeAll { $0.0 == url } },
                emptyTrash: { state.emptiedTrash = true },
                lockScreen: { state.locked = true }))
    }
}
