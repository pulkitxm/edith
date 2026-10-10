import EdithExtensionSupport
import Foundation

struct HostNotchPanelIdentity: Codable, Equatable, Sendable {
    let ownershipID: UUID
    let generation: UUID
}

struct HostNotchDisplayRequest: Codable, Equatable, Sendable {
    let displayID: UInt32
    let presentationID: UUID
    let width: Double
    let height: Double
    let collapsedWidth: Double
    let collapsedHeight: Double
    let isBuiltin: Bool
}

struct HostNotchPanelAttach: Codable, Equatable, Sendable {
    let ownershipID: UUID
    let version: String
    let displays: [HostNotchDisplayRequest]
}

struct HostNotchPanelBatch: Codable, Equatable, Sendable {
    let identity: HostNotchPanelIdentity
    let revision: UInt64
    let states: [HostNotchPanelState]

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= HostNotchPanelState.maximumBytes else {
            throw HostNotchPanelError.invalidState
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

struct HostNotchPanelWait: Codable, Sendable {
    let identity: HostNotchPanelIdentity
    let revision: UInt64
    let timeout: Double
}

struct HostNotchPanelMeasure: Codable, Sendable {
    let identity: HostNotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let slotID: UUID
    let revision: UInt64
    let height: Double
    let error: String?
}

struct HostNotchPanelPointer: Codable, Sendable {
    let identity: HostNotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let x: Double
    let y: Double
    let buttons: UInt32
    let option: Bool
    let draggingFiles: Bool
}

struct HostNotchPanelEnvironment {
    var activeVersions: [String: String]
    var layout: SurfaceLayout
    var hiddenWidgets: Set<SurfaceWidget> = []
    var reservedProviderScenes: [String: Int] = [:]
}

struct HostNotchPanelScreen {
    let display: HostNotchDisplay
    let isBuiltin: Bool
    var presentationID = UUID()

    var request: HostNotchDisplayRequest {
        .init(
            displayID: display.id, presentationID: presentationID,
            width: display.frame.width, height: display.frame.height,
            collapsedWidth: display.collapsedSize.width,
            collapsedHeight: display.collapsedSize.height, isBuiltin: isBuiltin)
    }
}

struct HostNotchPanelSceneStop: Codable, Equatable, Sendable {
    let identity: HostNotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
}
