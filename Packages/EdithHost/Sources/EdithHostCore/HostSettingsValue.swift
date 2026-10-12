import Foundation

indirect enum HostSettingsValue: Codable, Sendable {
    case string(String), boolean(Bool), integer(Int64), number(Double), data(Data), date(Date)
    case array([HostSettingsValue]), dictionary([String: HostSettingsValue])

    init(_ value: Any, depth: Int = 0) throws {
        guard depth <= 16 else { throw HostWorkerError.rejected }
        switch value {
        case let value as Data: self = .data(value)
        case let value as Date: self = .date(value)
        case let value as String: self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .boolean(value.boolValue)
            } else {
                let number = value.doubleValue
                guard number.isFinite else { throw HostWorkerError.rejected }
                if String(cString: value.objCType) == "f" || String(cString: value.objCType) == "d"
                {
                    self = .number(number)
                } else {
                    self = .integer(value.int64Value)
                }
            }
        case let value as [Any]:
            guard value.count <= 8192 else { throw HostWorkerError.rejected }
            self = .array(try value.map { try Self($0, depth: depth + 1) })
        case let value as [String: Any]:
            guard value.count <= 8192 else { throw HostWorkerError.rejected }
            self = .dictionary(try value.mapValues { try Self($0, depth: depth + 1) })
        default: throw HostWorkerError.rejected
        }
    }

    var value: Any {
        switch self {
        case .string(let value): value
        case .boolean(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .data(let value): value
        case .date(let value): value
        case .array(let value): value.map(\.value)
        case .dictionary(let value): value.mapValues(\.value)
        }
    }

    func validate(depth: Int = 0) throws {
        guard depth <= 16 else { throw HostWorkerError.rejected }
        switch self {
        case .array(let values):
            guard values.count <= 8192 else { throw HostWorkerError.rejected }
            for value in values { try value.validate(depth: depth + 1) }
        case .dictionary(let values):
            guard values.count <= 8192 else { throw HostWorkerError.rejected }
            for value in values.values { try value.validate(depth: depth + 1) }
        case .date(let value):
            guard value.timeIntervalSince1970.isFinite, abs(value.timeIntervalSince1970) <= 1e12
            else { throw HostWorkerError.rejected }
        case .number(let value):
            guard value.isFinite else { throw HostWorkerError.rejected }
        default: break
        }
    }
}

struct HostSettingsDocument: Codable, Sendable {
    let version: Int
    let preferences: [String: [String: HostSettingsValue]]
    let enabledIDs: [String]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= HostSettingsArchive.maximumBytes else { throw HostWorkerError.rejected }
        return data
    }

    static func decode(_ data: Data, extensionIDs: Set<String>) throws -> Self {
        guard data.count <= HostSettingsArchive.maximumBytes else { throw HostWorkerError.rejected }
        try checkDepth(JSONSerialization.jsonObject(with: data), depth: 0)
        let document = try JSONDecoder().decode(Self.self, from: data)
        guard document.version == 1, document.preferences.count <= extensionIDs.count + 1,
            Set(document.preferences.keys).isSubset(of: extensionIDs.union(["application"])),
            document.enabledIDs.count <= extensionIDs.count,
            Set(document.enabledIDs).count == document.enabledIDs.count,
            Set(document.enabledIDs).isSubset(of: extensionIDs),
            document.preferences.values.allSatisfy({
                Set($0.keys).isSubset(of: HostSettingsCatalog.keys)
            })
        else { throw HostWorkerError.rejected }
        for values in document.preferences.values {
            for (key, value) in values {
                try value.validate()
                if ["cleanerSelectedDrives", "cleanerCustomFolders"].contains(key),
                    !(value.value is [String])
                {
                    throw HostWorkerError.rejected
                }
                if key == "lidAwakeBatteryThreshold" {
                    guard case .integer(let threshold) = value, (0...100).contains(threshold)
                    else { throw HostWorkerError.rejected }
                }
            }
        }
        return document
    }

    private static func checkDepth(_ value: Any, depth: Int) throws {
        guard depth <= 64 else { throw HostWorkerError.rejected }
        if let values = value as? [Any] {
            for nested in values { try checkDepth(nested, depth: depth + 1) }
        } else if let values = value as? [String: Any] {
            for nested in values.values { try checkDepth(nested, depth: depth + 1) }
        } else if let number = value as? NSNumber, !number.doubleValue.isFinite {
            throw HostWorkerError.rejected
        }
    }
}
