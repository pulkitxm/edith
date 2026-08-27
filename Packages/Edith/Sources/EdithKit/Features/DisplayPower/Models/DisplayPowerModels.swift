import EdithCore
import Foundation

public enum DisplayBrightnessMethod: String, Codable, Equatable, Sendable {
    case system
    case ddc
    case software
    case unavailable
}

public struct DisplayPowerDisplay: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt32
    public let name: String
    public let builtIn: Bool
    public let method: DisplayBrightnessMethod
    public let brightness: Double

    public init(
        id: UInt32, name: String, builtIn: Bool, method: DisplayBrightnessMethod,
        brightness: Double
    ) {
        self.id = id
        self.name = name
        self.builtIn = builtIn
        self.method = method
        self.brightness = brightness
    }
}

public struct DisplayPowerSnapshot: Codable, Equatable, Sendable {
    public let displays: [DisplayPowerDisplay]
    public let xdrSupported: Bool
    public let xdrBoosting: Bool
    public let bluetoothSupported: Bool
    public let bluetoothOffDuringSleep: Bool
    public let bluetoothRestorePending: Bool
    public let updatedAt: Date

    public init(
        displays: [DisplayPowerDisplay], xdrSupported: Bool, xdrBoosting: Bool,
        bluetoothSupported: Bool, bluetoothOffDuringSleep: Bool,
        bluetoothRestorePending: Bool, updatedAt: Date = Date()
    ) {
        self.displays = displays
        self.xdrSupported = xdrSupported
        self.xdrBoosting = xdrBoosting
        self.bluetoothSupported = bluetoothSupported
        self.bluetoothOffDuringSleep = bluetoothOffDuringSleep
        self.bluetoothRestorePending = bluetoothRestorePending
        self.updatedAt = updatedAt
    }
}

public struct DisplayPowerBluetoothSleepPlan: Equatable, Sendable {
    public let powersOff: Bool
    public let owesRestore: Bool

    public init(powersOff: Bool, owesRestore: Bool) {
        self.powersOff = powersOff
        self.owesRestore = owesRestore
    }
}

public struct DisplayPowerDisplayIdentity: Equatable, Sendable {
    public var vendorID: Int64?
    public var productID: Int64?
    public var weekOfManufacture: Int64?
    public var yearOfManufacture: Int64?
    public var horizontalImageSize: Int64?
    public var verticalImageSize: Int64?
    public var ioDisplayLocation: String?
    public var productName: String?
    public var serialNumber: Int64?

    public init(
        vendorID: Int64? = nil, productID: Int64? = nil, weekOfManufacture: Int64? = nil,
        yearOfManufacture: Int64? = nil, horizontalImageSize: Int64? = nil,
        verticalImageSize: Int64? = nil, ioDisplayLocation: String? = nil,
        productName: String? = nil, serialNumber: Int64? = nil
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.weekOfManufacture = weekOfManufacture
        self.yearOfManufacture = yearOfManufacture
        self.horizontalImageSize = horizontalImageSize
        self.verticalImageSize = verticalImageSize
        self.ioDisplayLocation = ioDisplayLocation
        self.productName = productName
        self.serialNumber = serialNumber
    }
}

public struct DisplayPowerServiceIdentity: Equatable, Sendable {
    public var edidUUID: String
    public var ioDisplayLocation: String
    public var productName: String
    public var serialNumber: Int64
    public var ordinal: Int

    public init(
        edidUUID: String = "", ioDisplayLocation: String = "", productName: String = "",
        serialNumber: Int64 = 0, ordinal: Int = 0
    ) {
        self.edidUUID = edidUUID
        self.ioDisplayLocation = ioDisplayLocation
        self.productName = productName
        self.serialNumber = serialNumber
        self.ordinal = ordinal
    }
}

public enum DisplayPowerDDCProbeOutcome: Equatable, Sendable {
    case replied(current: UInt16, maximum: UInt16)
    case writeOnly
    case dead
}

public enum DisplayPowerPolicy {
    public static let xdrMacModels: Set<String> = [
        "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
        "Mac14,5", "Mac14,6", "Mac14,9", "Mac14,10", "Mac15,3", "Mac15,6",
        "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11", "Mac16,1",
        "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8", "Mac17,2", "Mac17,6",
        "Mac17,7", "Mac17,8", "Mac17,9",
    ]

    public static func normalizedBrightness(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }

    public static func deviceBrightness(_ value: Double, maximum: UInt16) -> UInt16 {
        let ceiling = maximum > 0 ? maximum : 100
        return UInt16((normalizedBrightness(value) * Double(ceiling)).rounded())
    }

    public static func gammaFactor(_ value: Double) -> Float {
        Float(normalizedBrightness(value))
    }

    public static func ddcPacket(payload: [UInt8]) -> [UInt8] {
        var bytes = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)]
        bytes.append(contentsOf: payload)
        let seed = UInt8(0x37 << 1) ^ (payload.count == 1 ? 0 : UInt8(0x51))
        bytes.append(bytes.reduce(seed) { $0 ^ $1 })
        return bytes
    }

    public static func ddcWritePacket(value: UInt16) -> [UInt8] {
        ddcPacket(payload: [0x10, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    public static let ddcReadPacket = ddcPacket(payload: [0x10])

    public static func parseDDCReply(_ reply: [UInt8]) -> (current: UInt16, maximum: UInt16)? {
        guard reply.count >= 11 else { return nil }
        let checksum = reply[0..<(reply.count - 1)].reduce(UInt8(0x50)) { $0 ^ $1 }
        guard checksum == reply[reply.count - 1] else { return nil }
        return (
            UInt16(reply[8]) << 8 | UInt16(reply[9]),
            UInt16(reply[6]) << 8 | UInt16(reply[7])
        )
    }

    public static func ddcProbeOutcome(
        writeAccepted: Bool, reply: (current: UInt16, maximum: UInt16)?
    ) -> DisplayPowerDDCProbeOutcome {
        if let reply { return .replied(current: reply.current, maximum: reply.maximum) }
        return writeAccepted ? .writeOnly : .dead
    }

    public static func matchScore(
        service: DisplayPowerServiceIdentity, display: DisplayPowerDisplayIdentity
    ) -> Int {
        var score = 0
        func uuidChunk(at location: Int) -> String {
            String(service.edidUUID.prefix(location + 4).suffix(4))
        }
        if let vendor = display.vendorID, vendor > 0 {
            let key = String(format: "%04X", UInt16(clamping: vendor))
            if key != "0000", key == uuidChunk(at: 0) { score += 1 }
        }
        if let product = display.productID, product > 0 {
            let value = UInt16(clamping: product)
            let key = String(format: "%02X%02X", UInt8(value & 0xFF), UInt8(value >> 8))
            if key != "0000", key == uuidChunk(at: 4) { score += 1 }
        }
        if let week = display.weekOfManufacture, let year = display.yearOfManufacture,
            year >= 1990
        {
            let key = String(
                format: "%02X%02X", UInt8(clamping: week), UInt8(clamping: year - 1990))
            if key != "0000", key == uuidChunk(at: 19) { score += 1 }
        }
        if let horizontal = display.horizontalImageSize,
            let vertical = display.verticalImageSize
        {
            let key = String(
                format: "%02X%02X", UInt8(clamping: horizontal / 10),
                UInt8(clamping: vertical / 10))
            if key != "0000", key == uuidChunk(at: 30) { score += 1 }
        }
        if !service.ioDisplayLocation.isEmpty,
            service.ioDisplayLocation == display.ioDisplayLocation
        {
            score += 10
        }
        if !service.productName.isEmpty,
            service.productName.lowercased() == display.productName?.lowercased()
        {
            score += 1
        }
        if service.serialNumber != 0, service.serialNumber == display.serialNumber { score += 1 }
        return score
    }

    public static func assignServices(
        scores: [(displayIndex: Int, serviceOrdinal: Int, score: Int)]
    ) -> [Int: Int] {
        var assignment: [Int: Int] = [:]
        var services = Set<Int>()
        for entry in scores.sorted(by: { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.displayIndex != right.displayIndex {
                return left.displayIndex < right.displayIndex
            }
            return left.serviceOrdinal < right.serviceOrdinal
        }) where entry.score > 0 {
            guard assignment[entry.displayIndex] == nil,
                !services.contains(entry.serviceOrdinal)
            else { continue }
            assignment[entry.displayIndex] = entry.serviceOrdinal
            services.insert(entry.serviceOrdinal)
        }
        return assignment
    }

    public static func bluetoothSleepPlan(isPoweredOn: Bool) -> DisplayPowerBluetoothSleepPlan {
        DisplayPowerBluetoothSleepPlan(powersOff: isPoweredOn, owesRestore: isPoweredOn)
    }

    public static func shouldRestoreBluetooth(owesRestore: Bool, isPoweredOn: Bool) -> Bool {
        owesRestore && !isPoweredOn
    }

    public static func xdrSupported(
        builtIn: Bool, name: String, potentialHeadroom: Double, model: String? = nil
    ) -> Bool {
        builtIn
            && (model.map(xdrMacModels.contains) == true || potentialHeadroom > 2.05
                || name.localizedCaseInsensitiveContains("XDR"))
    }

    public static func xdrFactor(level: Double, currentHeadroom: Double) -> Double {
        let available = max(currentHeadroom - 1, 0)
        return 1 + normalizedBrightness(level) * min(available, 0.48)
    }
}

public enum DisplayPowerOperation: String, CaseIterable, Sendable {
    case status
    case brightness
    case xdr
    case bluetoothSleep

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .status:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "display.status"),
                summary: "Inspect display brightness routes and sleep power settings.",
                cli: ["display", "status"], effect: .read)
        case .brightness:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "display.brightness"),
                summary: "Set brightness for one display or every active display.",
                cli: ["display", "brightness"], effect: .write)
        case .xdr:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "display.xdr"),
                summary: "Configure extra brightness on a supported built-in XDR display.",
                cli: ["display", "xdr"], effect: .write)
        case .bluetoothSleep:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "display.bluetoothSleep"),
                summary: "Configure Bluetooth to turn off only while this Mac sleeps.",
                cli: ["display", "bluetooth-sleep"], effect: .write)
        }
    }
}

public enum DisplayPowerOperationError: LocalizedError, Equatable {
    case invalidDisplay(UInt32)
    case invalidLevel
    case snapshotUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidDisplay(let id): "Display \(id) is not active."
        case .invalidLevel: "Brightness must be a whole percentage from 0 through 100."
        case .snapshotUnavailable: "Display status is not available yet. Start the Edith helper."
        }
    }
}

public enum DisplayPowerOperationExecution {
    public static func snapshot(
        defaults: UserDefaults = SharedDefaults.store
    ) throws -> DisplayPowerSnapshot {
        guard let data = defaults.data(forKey: AppStorageKeys.DisplayPower.latestSnapshot),
            let snapshot = try? JSONDecoder().decode(DisplayPowerSnapshot.self, from: data)
        else { throw DisplayPowerOperationError.snapshotUnavailable }
        return snapshot
    }

    @discardableResult
    public static func setBrightness(
        percent: Int, displayID: UInt32?, defaults: UserDefaults = SharedDefaults.store,
        announce: () -> Void = { IPC.post(IPC.Name.settingsChanged) }
    ) throws -> [UInt32: Double] {
        guard (0...100).contains(percent) else { throw DisplayPowerOperationError.invalidLevel }
        let snapshot = try snapshot(defaults: defaults)
        if let displayID, !snapshot.displays.contains(where: { $0.id == displayID }) {
            throw DisplayPowerOperationError.invalidDisplay(displayID)
        }
        var levels = brightnessLevels(defaults: defaults)
        let targets = displayID.map { [$0] } ?? snapshot.displays.map(\.id)
        for id in targets { levels[id] = Double(percent) / 100 }
        saveBrightnessLevels(levels, defaults: defaults)
        announce()
        return levels
    }

    public static func setXDR(
        enabled: Bool, percent: Int? = nil, defaults: UserDefaults = SharedDefaults.store,
        announce: () -> Void = { IPC.post(IPC.Name.settingsChanged) }
    ) throws {
        if let percent {
            guard (0...100).contains(percent) else { throw DisplayPowerOperationError.invalidLevel }
            defaults.set(percent, forKey: AppStorageKeys.DisplayPower.xdrBoostLevel)
        }
        defaults.set(enabled, forKey: AppStorageKeys.DisplayPower.xdrBoostEnabled)
        announce()
    }

    public static func setBluetoothSleep(
        _ enabled: Bool, defaults: UserDefaults = SharedDefaults.store,
        announce: () -> Void = { IPC.post(IPC.Name.settingsChanged) }
    ) {
        defaults.set(enabled, forKey: AppStorageKeys.DisplayPower.bluetoothOffDuringSleep)
        announce()
    }

    public static func brightnessLevels(
        defaults: UserDefaults = SharedDefaults.store
    ) -> [UInt32: Double] {
        guard let data = defaults.data(forKey: AppStorageKeys.DisplayPower.brightnessLevels),
            let stored = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: stored.compactMap { key, value in
                UInt32(key).map { ($0, DisplayPowerPolicy.normalizedBrightness(value)) }
            })
    }

    public static func saveSnapshot(
        _ snapshot: DisplayPowerSnapshot, defaults: UserDefaults = SharedDefaults.store
    ) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: AppStorageKeys.DisplayPower.latestSnapshot)
        }
    }

    private static func saveBrightnessLevels(
        _ levels: [UInt32: Double], defaults: UserDefaults
    ) {
        let stored = Dictionary(
            uniqueKeysWithValues: levels.map {
                (String($0.key), DisplayPowerPolicy.normalizedBrightness($0.value))
            })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: AppStorageKeys.DisplayPower.brightnessLevels)
        }
    }
}
