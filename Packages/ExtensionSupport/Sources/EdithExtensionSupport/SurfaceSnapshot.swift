import Foundation

public struct SurfaceSnapshotRequest: Codable, Equatable, Sendable {
    public var contractVersion = 1
    public let target: SurfaceTarget
    public let tile: SurfaceTile

    public init(target: SurfaceTarget, tile: SurfaceTile) {
        self.target = target
        self.tile = tile
    }

    public func encoded(providerID: String) throws -> Data {
        try validate(providerID: providerID)
        let data = try JSONEncoder().encode(self)
        guard data.count <= 131_072 else { throw ExtensionPeerError.invalidRequest }
        return data
    }

    public static func decode(_ data: Data, providerID: String) throws -> Self {
        guard data.count <= 131_072 else { throw ExtensionPeerError.invalidRequest }
        let request = try JSONDecoder().decode(Self.self, from: data)
        try request.validate(providerID: providerID)
        return request
    }

    private func validate(providerID: String) throws {
        guard contractVersion == 1, tile.widget.providerIDs.contains(providerID), !tile.hidden,
            tile == SurfaceLayout(tiles: [tile]).normalized().tiles.first,
            SurfaceSnapshot.validText(tile.instanceID, maximum: 256),
            tile.hiddenFields.count <= 100,
            tile.hiddenFields.allSatisfy({ SurfaceSnapshot.validText($0, maximum: 80) })
        else { throw ExtensionPeerError.invalidRequest }
    }
}

public struct SurfaceMetric: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let value: String
    public let fraction: Double?

    public init(_ id: String, _ title: String, _ value: String, fraction: Double? = nil) {
        self.id = id; self.title = title; self.value = value; self.fraction = fraction
    }
}

public struct SurfaceAction: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let icon: String
    public let field: String?

    public init(_ id: String, _ title: String, _ icon: String, field: String? = nil) {
        self.id = id; self.title = title; self.icon = icon; self.field = field
    }
}

public struct SurfaceDataRow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sourceID: String
    public let title: String
    public let detail: String
    public let value: String
    public let icon: String
    public let progress: Double?
    public let field: String?
    public let actions: [SurfaceAction]
    public let sliders: [SurfaceSlider]?

    public init(
        _ id: String, sourceID: String? = nil, title: String, detail: String = "",
        value: String = "", icon: String = "circle", progress: Double? = nil,
        field: String? = nil, actions: [SurfaceAction] = [], sliders: [SurfaceSlider] = []
    ) {
        self.id = id; self.sourceID = sourceID ?? id; self.title = title; self.detail = detail
        self.value = value; self.icon = icon; self.progress = progress; self.field = field
        self.actions = actions; self.sliders = sliders.isEmpty ? nil : sliders
    }
}

public struct SurfaceSnapshot: Codable, Equatable, Sendable {
    public var contractVersion = 1
    public let providerID: String
    public var metrics: [SurfaceMetric]
    public var rows: [SurfaceDataRow]
    public var actions: [SurfaceAction]
    public var sliders: [SurfaceSlider]?
    public var sources: [SurfaceSourceChoice]
    public var message: String?
    public var updatedAt: Date?

    public init(
        providerID: String, metrics: [SurfaceMetric] = [], rows: [SurfaceDataRow] = [],
        actions: [SurfaceAction] = [], sliders: [SurfaceSlider] = [],
        sources: [SurfaceSourceChoice] = [],
        message: String? = nil, updatedAt: Date? = nil
    ) {
        self.providerID = providerID; self.metrics = metrics; self.rows = rows
        self.actions = actions; self.sliders = sliders.isEmpty ? nil : sliders;
        self.sources = sources; self.message = message
        self.updatedAt = updatedAt
    }

    public func encoded() throws -> Data {
        try validate(providerID: providerID)
        let data = try JSONEncoder().encode(self)
        guard data.count <= 524_288 else { throw ExtensionPeerError.invalidRequest }
        return data
    }

    public static func decode(_ data: Data, providerID: String) throws -> Self {
        guard data.count <= 524_288 else { throw ExtensionPeerError.invalidRequest }
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        try snapshot.validate(providerID: providerID)
        return snapshot
    }

    private func validate(providerID expected: String) throws {
        let controls = (sliders ?? []) + rows.flatMap { $0.sliders ?? [] }
        guard controls.count <= 32, Self.unique(controls.map(\.id)),
            Set(controls.map(\.id)).isDisjoint(
                with: Set((actions + rows.flatMap(\.actions)).map(\.id)))
        else { throw ExtensionPeerError.invalidRequest }
        for control in controls { try control.validate() }
        guard contractVersion == 1, providerID == expected,
            Self.validText(providerID, maximum: 80), metrics.count <= 32, rows.count <= 100,
            sources.count <= 100, Self.validActions(actions),
            Self.unique(metrics.map(\.id)), Self.unique(rows.map(\.id)),
            Self.unique(sources.map(\.id)),
            metrics.allSatisfy({
                Self.validText($0.id, maximum: 80) && Self.validText($0.title, maximum: 256)
                    && Self.validText($0.value, maximum: 256, empty: true)
                    && Self.validFraction($0.fraction)
            }),
            rows.allSatisfy({
                Self.validText($0.id, maximum: 512) && Self.validText($0.sourceID, maximum: 2048)
                    && Self.validText($0.title, maximum: 1024)
                    && Self.validText($0.detail, maximum: 4096, empty: true)
                    && Self.validText($0.value, maximum: 256, empty: true)
                    && Self.validText($0.icon, maximum: 128)
                    && Self.validFraction($0.progress)
                    && ($0.field.map { Self.validText($0, maximum: 80) } ?? true)
                    && Self.validActions($0.actions)
            }),
            sources.allSatisfy({
                Self.validText($0.id, maximum: 2048) && Self.validText($0.title, maximum: 1024)
            }),
            message.map({ Self.validText($0, maximum: 4096, empty: true) }) ?? true,
            updatedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
    }

    private static func validActions(_ values: [SurfaceAction]) -> Bool {
        values.count <= 8 && unique(values.map(\.id))
            && values.allSatisfy {
                validText($0.id, maximum: 512) && validText($0.title, maximum: 256)
                    && validText($0.icon, maximum: 128)
                    && ($0.field.map { validText($0, maximum: 80) } ?? true)
            }
    }

    private static func unique(_ values: [String]) -> Bool { Set(values).count == values.count }
    private static func validFraction(_ value: Double?) -> Bool {
        value.map { $0.isFinite && (0...1).contains($0) } ?? true
    }
    static func validText(_ value: String, maximum: Int, empty: Bool = false) -> Bool {
        (empty || !value.isEmpty) && value.utf8.count <= maximum && !value.utf8.contains(0)
    }
}

public struct SurfaceActionRequest: Codable, Equatable, Sendable {
    public let snapshot: SurfaceSnapshotRequest
    public let actionID: String
    public let value: Double?

    public init(snapshot: SurfaceSnapshotRequest, actionID: String, value: Double? = nil) {
        self.snapshot = snapshot; self.actionID = actionID; self.value = value
    }

    public func encoded(providerID: String) throws -> Data {
        _ = try snapshot.encoded(providerID: providerID)
        guard SurfaceSnapshot.validText(actionID, maximum: 512),
            value.map({ $0.isFinite && (0...1).contains($0) }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 131_072 else { throw ExtensionPeerError.invalidRequest }
        return data
    }

    public static func decode(_ data: Data, providerID: String) throws -> Self {
        guard data.count <= 131_072 else { throw ExtensionPeerError.invalidRequest }
        let request = try JSONDecoder().decode(Self.self, from: data)
        _ = try request.encoded(providerID: providerID)
        return request
    }
}
