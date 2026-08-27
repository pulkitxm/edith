import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct DisplayPowerPolicyTests {
    @Test func brightnessNormalizationAndDeviceScalingAreBounded() {
        #expect(DisplayPowerPolicy.normalizedBrightness(-1) == 0)
        #expect(DisplayPowerPolicy.normalizedBrightness(1.5) == 1)
        #expect(DisplayPowerPolicy.normalizedBrightness(.nan) == 1)
        #expect(DisplayPowerPolicy.deviceBrightness(0.5, maximum: 100) == 50)
        #expect(DisplayPowerPolicy.deviceBrightness(0.5, maximum: 0) == 50)
        #expect(DisplayPowerPolicy.gammaFactor(0.4) == 0.4)
    }

    @Test func ddcPacketsAndRepliesFollowTheWireFormat() {
        #expect(
            DisplayPowerPolicy.ddcWritePacket(value: 0x1234) == [
                0x84, 0x03, 0x10, 0x12, 0x34, 0x8E,
            ])
        #expect(DisplayPowerPolicy.ddcReadPacket == [0x82, 0x01, 0x10, 0xFD])
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32]
        reply.append(reply.reduce(UInt8(0x50)) { $0 ^ $1 })
        #expect(DisplayPowerPolicy.parseDDCReply(reply)?.current == 50)
        #expect(DisplayPowerPolicy.parseDDCReply(reply)?.maximum == 100)
        reply[7] ^= 0xFF
        #expect(DisplayPowerPolicy.parseDDCReply(reply) == nil)
        #expect(DisplayPowerPolicy.parseDDCReply([0x6E, 0x88]) == nil)
    }

    @Test func ddcProbingKeepsWriteOnlyMonitorsControllable() {
        #expect(
            DisplayPowerPolicy.ddcProbeOutcome(
                writeAccepted: true, reply: (current: 45, maximum: 100))
                == .replied(current: 45, maximum: 100))
        #expect(DisplayPowerPolicy.ddcProbeOutcome(writeAccepted: true, reply: nil) == .writeOnly)
        #expect(DisplayPowerPolicy.ddcProbeOutcome(writeAccepted: false, reply: nil) == .dead)
    }

    @Test func displayServicesMatchByIdentityWithoutReuse() {
        let display = DisplayPowerDisplayIdentity(
            vendorID: 0x10AC, productID: 0xA05F, weekOfManufacture: 30,
            yearOfManufacture: 2015, horizontalImageSize: 600, verticalImageSize: 340,
            ioDisplayLocation: "IOService:/some/path", productName: "Desk Display",
            serialNumber: 42)
        let service = DisplayPowerServiceIdentity(
            edidUUID: "10AC5FA0-0000-0000-1E19-0000003C2200",
            ioDisplayLocation: "IOService:/some/path", productName: "desk display",
            serialNumber: 42, ordinal: 1)
        #expect(DisplayPowerPolicy.matchScore(service: service, display: display) == 16)
        #expect(
            DisplayPowerPolicy.matchScore(
                service: DisplayPowerServiceIdentity(),
                display: DisplayPowerDisplayIdentity()) == 0)

        let assignment = DisplayPowerPolicy.assignServices(scores: [
            (displayIndex: 0, serviceOrdinal: 1, score: 2),
            (displayIndex: 0, serviceOrdinal: 2, score: 11),
            (displayIndex: 1, serviceOrdinal: 1, score: 3),
            (displayIndex: 1, serviceOrdinal: 2, score: 4),
        ])
        #expect(assignment == [0: 2, 1: 1])
        #expect(
            DisplayPowerPolicy.assignServices(scores: [
                (displayIndex: 0, serviceOrdinal: 1, score: 0)
            ]).isEmpty)
    }

    @Test func bluetoothRestorationOnlyPaysOwnedDebt() {
        #expect(
            DisplayPowerPolicy.bluetoothSleepPlan(isPoweredOn: true)
                == DisplayPowerBluetoothSleepPlan(powersOff: true, owesRestore: true))
        #expect(
            DisplayPowerPolicy.bluetoothSleepPlan(isPoweredOn: false)
                == DisplayPowerBluetoothSleepPlan(powersOff: false, owesRestore: false))
        #expect(DisplayPowerPolicy.shouldRestoreBluetooth(owesRestore: true, isPoweredOn: false))
        #expect(!DisplayPowerPolicy.shouldRestoreBluetooth(owesRestore: true, isPoweredOn: true))
        #expect(!DisplayPowerPolicy.shouldRestoreBluetooth(owesRestore: false, isPoweredOn: false))
    }

    @Test func xdrRequiresABuiltInCapableDisplayAndTracksHeadroom() {
        #expect(
            DisplayPowerPolicy.xdrSupported(
                builtIn: true, name: "Built-in Display", potentialHeadroom: 1,
                model: "MacBookPro18,1"))
        #expect(
            DisplayPowerPolicy.xdrSupported(
                builtIn: true, name: "Liquid Retina XDR Display", potentialHeadroom: 1))
        #expect(
            !DisplayPowerPolicy.xdrSupported(
                builtIn: false, name: "Pro Display XDR", potentialHeadroom: 4))
        #expect(abs(DisplayPowerPolicy.xdrFactor(level: 0.5, currentHeadroom: 1.4) - 1.2) < 0.0001)
        #expect(abs(DisplayPowerPolicy.xdrFactor(level: 1, currentHeadroom: 3) - 1.48) < 0.0001)
    }
}

@Suite struct DisplayPowerOperationTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "test.display-power.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func snapshot() -> DisplayPowerSnapshot {
        DisplayPowerSnapshot(
            displays: [
                DisplayPowerDisplay(
                    id: 1, name: "Built-in Display", builtIn: true, method: .system,
                    brightness: 0.7),
                DisplayPowerDisplay(
                    id: 2, name: "Desk Display", builtIn: false, method: .ddc,
                    brightness: 0.5),
            ], xdrSupported: true, xdrBoosting: false, bluetoothSupported: true,
            bluetoothOffDuringSleep: false, bluetoothRestorePending: false,
            updatedAt: Date(timeIntervalSince1970: 100))
    }

    @Test func snapshotsAndBrightnessSelectionsRoundTrip() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let snapshot = snapshot()
        DisplayPowerOperationExecution.saveSnapshot(snapshot, defaults: defaults)
        #expect(try DisplayPowerOperationExecution.snapshot(defaults: defaults) == snapshot)

        var announcements = 0
        let all = try DisplayPowerOperationExecution.setBrightness(
            percent: 60, displayID: nil, defaults: defaults, announce: { announcements += 1 })
        #expect(all == [1: 0.6, 2: 0.6])
        let one = try DisplayPowerOperationExecution.setBrightness(
            percent: 35, displayID: 2, defaults: defaults, announce: { announcements += 1 })
        #expect(one == [1: 0.6, 2: 0.35])
        #expect(DisplayPowerOperationExecution.brightnessLevels(defaults: defaults) == one)
        #expect(announcements == 2)
    }

    @Test func brightnessRejectsMissingSnapshotsDisplaysAndInvalidLevels() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(throws: DisplayPowerOperationError.snapshotUnavailable) {
            try DisplayPowerOperationExecution.setBrightness(
                percent: 50, displayID: nil, defaults: defaults)
        }
        DisplayPowerOperationExecution.saveSnapshot(snapshot(), defaults: defaults)
        #expect(throws: DisplayPowerOperationError.invalidDisplay(3)) {
            try DisplayPowerOperationExecution.setBrightness(
                percent: 50, displayID: 3, defaults: defaults)
        }
        #expect(throws: DisplayPowerOperationError.invalidLevel) {
            try DisplayPowerOperationExecution.setBrightness(
                percent: 101, displayID: nil, defaults: defaults)
        }
    }

    @Test func xdrAndBluetoothMutationsPersistAndAnnounce() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var announcements = 0
        try DisplayPowerOperationExecution.setXDR(
            enabled: true, percent: 65, defaults: defaults, announce: { announcements += 1 })
        DisplayPowerOperationExecution.setBluetoothSleep(
            true, defaults: defaults, announce: { announcements += 1 })
        #expect(defaults.bool(forKey: AppStorageKeys.DisplayPower.xdrBoostEnabled))
        #expect(defaults.integer(forKey: AppStorageKeys.DisplayPower.xdrBoostLevel) == 65)
        #expect(defaults.bool(forKey: AppStorageKeys.DisplayPower.bluetoothOffDuringSleep))
        #expect(announcements == 2)
        #expect(throws: DisplayPowerOperationError.invalidLevel) {
            try DisplayPowerOperationExecution.setXDR(
                enabled: true, percent: -1, defaults: defaults)
        }
    }
}

@Suite struct DisplayPowerCLITests {
    private static func snapshot() -> DisplayPowerSnapshot {
        DisplayPowerSnapshot(
            displays: [
                DisplayPowerDisplay(
                    id: 7, name: "Built-in Display", builtIn: true, method: .system,
                    brightness: 0.7),
                DisplayPowerDisplay(
                    id: 9, name: "Desk Display", builtIn: false, method: .software,
                    brightness: 0.4),
            ], xdrSupported: true, xdrBoosting: true, bluetoothSupported: true,
            bluetoothOffDuringSleep: true, bluetoothRestorePending: true,
            updatedAt: Date(timeIntervalSince1970: 100))
    }

    @Test func commandGroupAndEveryLeafParseFromTheRoot() throws {
        for arguments in [
            ["display", "status"], ["display", "brightness", "60"],
            ["display", "xdr", "50"], ["display", "bluetooth-sleep", "on"],
        ] {
            _ = try EdRoot.parseAsRoot(arguments)
        }
    }

    @Test func statusReportsStableStructuredDisplayFacts() async throws {
        await CLIProbe.inWorld { world in
            DisplayPowerOperationExecution.saveSnapshot(Self.snapshot(), defaults: world.shared)
            let result = await CLIProbe.capture(["display", "status", "--json"])
            #expect(result.code == 0)
            #expect((result.object?["displays"] as? [[String: Any]])?.count == 2)
            #expect(result.object?["xdrSupported"] as? Bool == true)
            #expect(result.object?["xdrBoosting"] as? Bool == true)
            #expect(result.object?["bluetoothRestorePending"] as? Bool == true)
            #expect(result.object?["updatedAt"] as? String == "1970-01-01T00:01:40Z")
        }
    }

    @Test func brightnessTargetsOneDisplayAndPostsOneSettingsChange() async throws {
        await CLIProbe.inWorld { world in
            DisplayPowerOperationExecution.saveSnapshot(Self.snapshot(), defaults: world.shared)
            let result = await CLIProbe.capture([
                "display", "brightness", "35", "--display", "9", "--json",
            ])
            #expect(result.code == 0)
            #expect(result.object?["brightness"] as? Int == 35)
            #expect(result.object?["display"] as? Int == 9)
            #expect(
                DisplayPowerOperationExecution.brightnessLevels(defaults: world.shared) == [9: 0.35]
            )
            #expect(world.postedNames() == [IPC.Name.settingsChanged.rawValue])
        }
    }

    @Test func brightnessRejectsUnknownDisplaysAndInvalidPercentages() async throws {
        await CLIProbe.inWorld { world in
            DisplayPowerOperationExecution.saveSnapshot(Self.snapshot(), defaults: world.shared)
            let missing = await CLIProbe.capture([
                "display", "brightness", "50", "--display", "10",
            ])
            #expect(missing.code == ExitCodes.failure)
            #expect(missing.stderr.contains("Display 10 is not active"))
            let invalid = await CLIProbe.capture(["display", "brightness", "101"])
            #expect(invalid.code == ExitCodes.failure)
            #expect(invalid.stderr.contains("whole percentage"))
            #expect(world.postedNames().isEmpty)
        }
    }

    @Test func xdrAndBluetoothCommandsWriteTheSharedPreferences() async throws {
        await CLIProbe.inWorld { world in
            let xdr = await CLIProbe.capture(["display", "xdr", "55", "--json"])
            #expect(xdr.code == 0)
            #expect(xdr.object?["enabled"] as? Bool == true)
            #expect(world.shared.integer(forKey: AppStorageKeys.DisplayPower.xdrBoostLevel) == 55)
            let bluetooth = await CLIProbe.capture([
                "display", "bluetooth-sleep", "on", "--json",
            ])
            #expect(bluetooth.code == 0)
            #expect(world.shared.bool(forKey: AppStorageKeys.DisplayPower.bluetoothOffDuringSleep))
            let off = await CLIProbe.capture(["display", "xdr", "off", "--json"])
            #expect(off.code == 0)
            #expect(!world.shared.bool(forKey: AppStorageKeys.DisplayPower.xdrBoostEnabled))
            #expect(
                world.postedNames() == [
                    IPC.Name.settingsChanged.rawValue, IPC.Name.settingsChanged.rawValue,
                    IPC.Name.settingsChanged.rawValue,
                ])
        }
    }
}
