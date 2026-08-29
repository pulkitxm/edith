import CoreGraphics
import EdithCore
import Foundation

public struct WorkspaceDisplaySnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt32
    public let name: String
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let order: Int

    public init(id: UInt32, name: String, frame: CGRect, visibleFrame: CGRect, order: Int) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.order = order
    }
}

public struct WorkspaceWindowSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let bundleIdentifier: String
    public let applicationName: String
    public let applicationURL: String?
    public let title: String
    public let role: String
    public let subrole: String
    public let frame: CGRect
    public let minimized: Bool
    public let fullScreen: Bool
    public let displayID: UInt32
    public let order: Int

    public init(
        id: UUID = UUID(), bundleIdentifier: String, applicationName: String,
        applicationURL: String?, title: String, role: String, subrole: String, frame: CGRect,
        minimized: Bool, fullScreen: Bool, displayID: UInt32, order: Int
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.applicationURL = applicationURL
        self.title = title
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.minimized = minimized
        self.fullScreen = fullScreen
        self.displayID = displayID
        self.order = order
    }
}

public struct WorkspaceProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var capturedAt: Date
    public var displays: [WorkspaceDisplaySnapshot]
    public var windows: [WorkspaceWindowSnapshot]
    public var activeBundleIdentifier: String?

    public init(
        id: UUID = UUID(), name: String, capturedAt: Date = Date(),
        displays: [WorkspaceDisplaySnapshot], windows: [WorkspaceWindowSnapshot],
        activeBundleIdentifier: String?
    ) {
        self.id = id
        self.name = name
        self.capturedAt = capturedAt
        self.displays = displays
        self.windows = windows
        self.activeBundleIdentifier = activeBundleIdentifier
    }
}

public struct WorkspaceCandidateWindow: Equatable, Sendable {
    public let token: String
    public let bundleIdentifier: String
    public let title: String
    public let role: String
    public let subrole: String
    public let frame: CGRect
    public let displayID: UInt32
    public let order: Int

    public init(
        token: String, bundleIdentifier: String, title: String, role: String, subrole: String,
        frame: CGRect, displayID: UInt32, order: Int
    ) {
        self.token = token
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.displayID = displayID
        self.order = order
    }
}

public enum WorkspaceMatchConfidence: String, Codable, CaseIterable, Sendable {
    case exact
    case high
    case medium
    case low
    case missing
}

public enum WorkspaceRestoreDisposition: String, Codable, Sendable {
    case move
    case launch
    case skip
}

public struct WorkspaceRestorePlanItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let windowID: UUID
    public let applicationName: String
    public let title: String
    public let candidateToken: String?
    public let confidence: WorkspaceMatchConfidence
    public let score: Double
    public let disposition: WorkspaceRestoreDisposition
    public let sourceFrame: CGRect
    public let targetFrame: CGRect
    public let sourceDisplayID: UInt32
    public let targetDisplayID: UInt32
    public let minimized: Bool
    public let fullScreen: Bool

    public init(
        id: UUID = UUID(), windowID: UUID, applicationName: String, title: String,
        candidateToken: String?, confidence: WorkspaceMatchConfidence, score: Double,
        disposition: WorkspaceRestoreDisposition, sourceFrame: CGRect, targetFrame: CGRect,
        sourceDisplayID: UInt32, targetDisplayID: UInt32, minimized: Bool, fullScreen: Bool
    ) {
        self.id = id
        self.windowID = windowID
        self.applicationName = applicationName
        self.title = title
        self.candidateToken = candidateToken
        self.confidence = confidence
        self.score = score
        self.disposition = disposition
        self.sourceFrame = sourceFrame
        self.targetFrame = targetFrame
        self.sourceDisplayID = sourceDisplayID
        self.targetDisplayID = targetDisplayID
        self.minimized = minimized
        self.fullScreen = fullScreen
    }
}

public struct WorkspaceRestorePlan: Codable, Equatable, Sendable {
    public let profileID: UUID
    public let profileName: String
    public let createdAt: Date
    public let displayMapping: [UInt32: UInt32]
    public let items: [WorkspaceRestorePlanItem]

    public init(
        profileID: UUID, profileName: String, createdAt: Date = Date(),
        displayMapping: [UInt32: UInt32], items: [WorkspaceRestorePlanItem]
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.createdAt = createdAt
        self.displayMapping = displayMapping
        self.items = items
    }
}

public enum WorkspaceRestoreItemState: String, Codable, Sendable {
    case restored
    case launched
    case skipped
    case failed
    case cancelled
}

public struct WorkspaceRestoreItemResult: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let windowID: UUID
    public let applicationName: String
    public let title: String
    public let confidence: WorkspaceMatchConfidence
    public let state: WorkspaceRestoreItemState
    public let detail: String

    public init(
        id: UUID = UUID(), windowID: UUID, applicationName: String, title: String,
        confidence: WorkspaceMatchConfidence, state: WorkspaceRestoreItemState, detail: String
    ) {
        self.id = id
        self.windowID = windowID
        self.applicationName = applicationName
        self.title = title
        self.confidence = confidence
        self.state = state
        self.detail = detail
    }
}

public struct WorkspaceRestoreRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public let profileName: String
    public let startedAt: Date
    public let finishedAt: Date
    public let dryRun: Bool
    public let cancelled: Bool
    public let items: [WorkspaceRestoreItemResult]

    public init(
        id: UUID = UUID(), profileID: UUID, profileName: String, startedAt: Date,
        finishedAt: Date = Date(), dryRun: Bool, cancelled: Bool,
        items: [WorkspaceRestoreItemResult]
    ) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.dryRun = dryRun
        self.cancelled = cancelled
        self.items = items
    }
}

public enum WorkspaceLaunchPolicy: String, Codable, CaseIterable, Sendable {
    case never
    case missing
}

public struct WorkspaceRestoreOptions: Codable, Equatable, Sendable {
    public let launchPolicy: WorkspaceLaunchPolicy
    public let timeout: TimeInterval
    public let concurrency: Int

    public init(
        launchPolicy: WorkspaceLaunchPolicy = .never, timeout: TimeInterval = 12,
        concurrency: Int = 1
    ) {
        self.launchPolicy = launchPolicy
        self.timeout = max(1, min(120, timeout))
        self.concurrency = max(1, min(4, concurrency))
    }
}

public enum WorkspaceRestorerGeometry {
    public static func displayMapping(
        saved: [WorkspaceDisplaySnapshot], current: [WorkspaceDisplaySnapshot]
    ) -> [UInt32: UInt32] {
        guard !current.isEmpty else { return [:] }
        let orderedCurrent = current.sorted(by: displayOrder)
        let orderedSaved = saved.sorted(by: displayOrder)
        var mapping: [UInt32: UInt32] = [:]
        for (index, display) in orderedSaved.enumerated() {
            if current.contains(where: { $0.id == display.id }) {
                mapping[display.id] = display.id
                continue
            }
            let sourceRank =
                orderedSaved.count > 1
                ? Double(index) / Double(orderedSaved.count - 1) : 0
            let match = orderedCurrent.enumerated().min { left, right in
                let leftScore = displayScore(
                    display, left.element, sourceRank, left.offset,
                    orderedCurrent.count)
                let rightScore = displayScore(
                    display, right.element, sourceRank, right.offset,
                    orderedCurrent.count)
                if leftScore == rightScore { return left.element.id < right.element.id }
                return leftScore < rightScore
            }
            mapping[display.id] = match?.element.id
        }
        return mapping
    }

    public static func remappedFrame(
        _ frame: CGRect, from source: CGRect, to destination: CGRect
    ) -> CGRect {
        guard source.width > 0, source.height > 0, destination.width > 0,
            destination.height > 0
        else { return destination }
        let width = min(destination.width, max(120, frame.width / source.width * destination.width))
        let height = min(
            destination.height, max(80, frame.height / source.height * destination.height))
        let xProgress = (frame.midX - source.minX) / source.width
        let yProgress = (frame.midY - source.minY) / source.height
        let x = destination.minX + xProgress * destination.width - width / 2
        let y = destination.minY + yProgress * destination.height - height / 2
        return CGRect(
            x: min(max(x, destination.minX), destination.maxX - width).rounded(),
            y: min(max(y, destination.minY), destination.maxY - height).rounded(),
            width: width.rounded(), height: height.rounded())
    }

    private static func displayOrder(
        _ left: WorkspaceDisplaySnapshot, _ right: WorkspaceDisplaySnapshot
    ) -> Bool {
        if left.frame.minX != right.frame.minX { return left.frame.minX < right.frame.minX }
        if left.frame.minY != right.frame.minY { return left.frame.minY < right.frame.minY }
        return left.id < right.id
    }

    private static func displayScore(
        _ source: WorkspaceDisplaySnapshot, _ target: WorkspaceDisplaySnapshot,
        _ sourceRank: Double, _ targetIndex: Int, _ targetCount: Int
    ) -> Double {
        let sourceAspect = source.visibleFrame.width / max(1, source.visibleFrame.height)
        let targetAspect = target.visibleFrame.width / max(1, target.visibleFrame.height)
        let aspect = abs(log(max(0.01, sourceAspect / max(0.01, targetAspect))))
        let area = abs(log(max(0.01, source.visibleFrame.area / max(1, target.visibleFrame.area))))
        let targetRank = targetCount > 1 ? Double(targetIndex) / Double(targetCount - 1) : 0
        return aspect * 2 + area + abs(sourceRank - targetRank)
    }
}

public enum WorkspaceRestorerPlanner {
    public static func plan(
        profile: WorkspaceProfile, candidates: [WorkspaceCandidateWindow],
        displays: [WorkspaceDisplaySnapshot], launchPolicy: WorkspaceLaunchPolicy
    ) -> WorkspaceRestorePlan {
        let mapping = WorkspaceRestorerGeometry.displayMapping(
            saved: profile.displays, current: displays)
        var available = candidates
        let items = profile.windows.sorted { $0.order > $1.order }.map { saved in
            let ranked = available.enumerated().filter {
                $0.element.bundleIdentifier == saved.bundleIdentifier
            }.map { index, candidate in
                (index, candidate, matchScore(saved, candidate))
            }.sorted {
                if $0.2 == $1.2 { return $0.1.token < $1.1.token }
                return $0.2 > $1.2
            }
            let best = ranked.first
            if let best { available.remove(at: best.0) }
            let targetDisplayID =
                mapping[saved.displayID] ?? displays.sorted { $0.id < $1.id }.first?.id
                ?? saved.displayID
            let sourceDisplay = profile.displays.first { $0.id == saved.displayID }
            let targetDisplay = displays.first { $0.id == targetDisplayID }
            let targetFrame =
                if let sourceDisplay, let targetDisplay {
                    WorkspaceRestorerGeometry.remappedFrame(
                        saved.frame, from: sourceDisplay.visibleFrame,
                        to: targetDisplay.visibleFrame)
                } else {
                    saved.frame
                }
            let score = best?.2 ?? 0
            let confidence = confidence(score: score, hasMatch: best != nil)
            let disposition: WorkspaceRestoreDisposition =
                if best != nil {
                    .move
                } else if launchPolicy == .missing {
                    .launch
                } else {
                    .skip
                }
            return WorkspaceRestorePlanItem(
                windowID: saved.id, applicationName: saved.applicationName, title: saved.title,
                candidateToken: best?.1.token, confidence: confidence, score: score,
                disposition: disposition, sourceFrame: saved.frame, targetFrame: targetFrame,
                sourceDisplayID: saved.displayID, targetDisplayID: targetDisplayID,
                minimized: saved.minimized, fullScreen: saved.fullScreen)
        }
        return WorkspaceRestorePlan(
            profileID: profile.id, profileName: profile.name, displayMapping: mapping, items: items)
    }

    private static func matchScore(
        _ saved: WorkspaceWindowSnapshot, _ candidate: WorkspaceCandidateWindow
    ) -> Double {
        var score = 0.25
        let savedTitle = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !savedTitle.isEmpty, savedTitle == candidateTitle {
            score += 0.45
        } else if !savedTitle.isEmpty, !candidateTitle.isEmpty,
            candidateTitle.localizedCaseInsensitiveContains(savedTitle)
                || savedTitle.localizedCaseInsensitiveContains(candidateTitle)
        {
            score += 0.25
        }
        if saved.role == candidate.role { score += 0.08 }
        if saved.subrole == candidate.subrole { score += 0.07 }
        if saved.order == candidate.order { score += 0.1 }
        if saved.displayID == candidate.displayID { score += 0.05 }
        return min(1, score)
    }

    private static func confidence(score: Double, hasMatch: Bool) -> WorkspaceMatchConfidence {
        guard hasMatch else { return .missing }
        if score >= 0.9 { return .exact }
        if score >= 0.72 { return .high }
        if score >= 0.5 { return .medium }
        return .low
    }
}

private extension CGRect {
    var area: CGFloat { max(1, width * height) }
}

public struct WorkspaceRestorerLibrary: Codable, Equatable, Sendable {
    public var profiles: [WorkspaceProfile]
    public var history: [WorkspaceRestoreRun]
    public var recoveryProfile: WorkspaceProfile?

    public init(
        profiles: [WorkspaceProfile] = [], history: [WorkspaceRestoreRun] = [],
        recoveryProfile: WorkspaceProfile? = nil
    ) {
        self.profiles = profiles
        self.history = history
        self.recoveryProfile = recoveryProfile
    }

    public mutating func upsert(_ profile: WorkspaceProfile) {
        profiles.removeAll {
            $0.id == profile.id || $0.name.caseInsensitiveCompare(profile.name) == .orderedSame
        }
        profiles.append(profile)
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public mutating func remove(_ query: String) throws {
        let profile = try resolve(query)
        profiles.removeAll { $0.id == profile.id }
    }

    public mutating func rename(_ query: String, to name: String) throws -> WorkspaceProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceRestorerError.invalidName }
        let profile = try resolve(query)
        guard
            !profiles.contains(where: {
                $0.id != profile.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            })
        else { throw WorkspaceRestorerError.duplicateName(trimmed) }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw WorkspaceRestorerError.notFound(query)
        }
        profiles[index].name = trimmed
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return profiles.first { $0.id == profile.id }!
    }

    public mutating func duplicate(_ query: String, as name: String) throws -> WorkspaceProfile {
        let source = try resolve(query)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceRestorerError.invalidName }
        guard !profiles.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { throw WorkspaceRestorerError.duplicateName(trimmed) }
        let copy = WorkspaceProfile(
            name: trimmed, displays: source.displays, windows: source.windows,
            activeBundleIdentifier: source.activeBundleIdentifier)
        upsert(copy)
        return copy
    }

    public func resolve(_ query: String) throws -> WorkspaceProfile {
        let matches = profiles.filter {
            $0.id.uuidString.caseInsensitiveCompare(query) == .orderedSame
                || $0.name.caseInsensitiveCompare(query) == .orderedSame
        }
        guard let profile = matches.first else { throw WorkspaceRestorerError.notFound(query) }
        return profile
    }

    public mutating func record(_ run: WorkspaceRestoreRun) {
        history.insert(run, at: 0)
        history = Array(history.prefix(25))
    }
}

public enum WorkspaceRestorerError: LocalizedError, Equatable {
    case invalidName
    case duplicateName(String)
    case notFound(String)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Workspace profile names cannot be empty."
        case .duplicateName(let name): "A workspace profile named \"\(name)\" already exists."
        case .notFound(let query): "No workspace profile matches \"\(query)\"."
        case .storage(let detail): "Workspace profiles could not be saved: \(detail)"
        }
    }
}

public enum WorkspaceRestorerStore {
    public static func load(defaults: UserDefaults = SharedDefaults.store)
        -> WorkspaceRestorerLibrary
    {
        guard let data = defaults.data(forKey: AppStorageKeys.WorkspaceRestorer.library),
            let library = try? JSONDecoder().decode(WorkspaceRestorerLibrary.self, from: data)
        else { return WorkspaceRestorerLibrary() }
        return library
    }

    public static func save(
        _ library: WorkspaceRestorerLibrary, defaults: UserDefaults = SharedDefaults.store
    ) throws {
        do {
            defaults.set(
                try JSONEncoder().encode(library), forKey: AppStorageKeys.WorkspaceRestorer.library)
            IPC.post(IPC.Name.workspaceRestorerChanged)
        } catch {
            throw WorkspaceRestorerError.storage(error.localizedDescription)
        }
    }
}

public enum WorkspaceRestorerOperation: String, CaseIterable, Codable, Sendable {
    case capture
    case preview
    case restore
    case cancel
    case recover

    public var title: String {
        switch self {
        case .capture: "Capture workspace"
        case .preview: "Preview workspace restore"
        case .restore: "Restore workspace"
        case .cancel: "Cancel workspace restore"
        case .recover: "Recover previous workspace"
        }
    }

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "window.workspace.\(rawValue)"),
            summary: "\(title).", cli: ["window", "workspace", rawValue], effect: .write)
    }
}

public struct WorkspaceRestorerRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let operation: WorkspaceRestorerOperation
    public let profile: String?
    public let options: WorkspaceRestoreOptions

    public init(
        id: UUID = UUID(), operation: WorkspaceRestorerOperation, profile: String? = nil,
        options: WorkspaceRestoreOptions = WorkspaceRestoreOptions()
    ) {
        self.id = id
        self.operation = operation
        self.profile = profile
        self.options = options
    }
}

public struct WorkspaceRestorerResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let ok: Bool
    public let profile: WorkspaceProfile?
    public let plan: WorkspaceRestorePlan?
    public let run: WorkspaceRestoreRun?
    public let error: String?

    public init(
        requestID: UUID, ok: Bool, profile: WorkspaceProfile? = nil,
        plan: WorkspaceRestorePlan? = nil, run: WorkspaceRestoreRun? = nil,
        error: String? = nil
    ) {
        self.requestID = requestID
        self.ok = ok
        self.profile = profile
        self.plan = plan
        self.run = run
        self.error = error
    }
}

public enum WorkspaceRestorerIPC {
    public static let payloadKey = "payload"

    public static func payload<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else { return nil }
        return [payloadKey: string]
    }

    public static func decode<T: Decodable>(_ type: T.Type, from info: [AnyHashable: Any]) -> T? {
        guard let string = info[payloadKey] as? String, let data = string.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
