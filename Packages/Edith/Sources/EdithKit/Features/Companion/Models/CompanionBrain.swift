import Foundation

public struct CompanionPersonaRetrieval: Codable, Equatable, Sendable {
    public let k: Int
    public let windowDays: Int?
    public let prefer: String
    public let beliefs: Bool
    public let observations: Bool
    public let graph: Bool
}

public struct CompanionPersonaEvidence: Codable, Equatable, Sendable {
    public let selfReportWeight: Double
    public let observationWeight: Double
    public let requireCorroboration: Bool
}

public struct CompanionPersona: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let retrieval: CompanionPersonaRetrieval
    public let evidence: CompanionPersonaEvidence
    public let pipeline: [String]
    public let output: String
    public let abstainBelow: Double
    public let maxWords: Int
}

public struct CompanionGrounding: Codable, Equatable, Sendable {
    public let score: Double
    public let scorer: String
    public let unsupported: [String]
}

public struct CompanionBeliefHit: Codable, Equatable, Sendable {
    public let id: String
    public let statement: String
    public let confidence: Double
    public let stability: Double
    public let corroboration: String
    public let status: String
}

public struct CompanionPersonaAnswer: Codable, Equatable, Sendable {
    public let persona: String
    public let label: String
    public let question: String
    public let reframed: String?
    public let answer: String
    public let abstained: Bool
    public let citations: [CompanionAskCitation]
    public let beliefs: [CompanionBeliefHit]
    public let grounding: CompanionGrounding
    public let opinion: String?
    public let stages: [String]
    public let chunksConsidered: Int
    public let model: String
}

public struct CompanionCouncil: Codable, Equatable, Sendable {
    public let question: String
    public let answers: [CompanionPersonaAnswer]
    public let agreement: String
    public let divergence: String
    public let crux: String
    public let cruxQuestion: String
    public let model: String
}

public struct CompanionCoreSection: Codable, Equatable, Sendable {
    public let section: String
    public let content: String
    public let tokens: Int
    public let updatedAt: String
    public let updatedBy: String
}

public struct CompanionHypothesis: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let statement: String
    public let mechanism: String
    public let status: String
    public let prior: Double
    public let posterior: Double
    public let testCount: Int
    public let alternativeExplanations: [String]
    public let formedAt: String
    public let generatedBy: String
}

public struct CompanionPrediction: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let hypothesisId: String
    public let statement: String
    public let observable: String
    public let windowStart: String
    public let windowEnd: String
    public let resolvedAt: String?
    public let outcome: String?
}

public struct CompanionCommitment: Codable, Equatable, Sendable {
    public let id: String
    public let claim: String
    public let statedAt: String
    public let dueBy: String
    public let status: String
    public let resolvedAt: String?
    public let userOverride: String?
}

public struct CompanionDiscrepancy: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let claim: String
    public let kind: String
    public let magnitude: Double
    public let detectedAt: String
    public let dismissed: Bool
    public let userResponse: String?
}

public struct CompanionCalibration: Codable, Equatable, Sendable {
    public let domain: String
    public let direction: String
    public let samples: Int
    public let averageMagnitude: Double
}

public struct CompanionQuestion: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let question: String
    public let motive: String
    public let topic: String
    public let targetKind: String
    public let expectedGain: Double
    public let sensitivity: Int
    public let status: String
    public let resolution: String?
}

public struct CompanionQuestionList: Codable, Equatable, Sendable {
    public let questions: [CompanionQuestion]
    public let muted: [String]
    public let askedToday: Int
    public let dailyBudget: Int
}

public struct CompanionNextQuestion: Codable, Equatable, Sendable {
    public let question: CompanionQuestion?
    public let askedToday: Int?
    public let dailyBudget: Int?
}

public struct CompanionQuestionAnswer: Codable, Equatable, Sendable {
    public let question: String
    public let episodeId: String
    public let resolution: String
    public let askedToday: Int
}

public struct CompanionEntity: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let canonicalName: String
    public let aliases: [String]
    public let mentionCount: Int
    public let firstSeen: String
    public let lastSeen: String
}

public struct CompanionLens: Codable, Equatable, Sendable {
    public let persona: String
    public let content: String
    public let updatedAt: String
    public let updatedBy: String
}

public struct CompanionEvalCase: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let expect: String
    public let passed: Bool
    public let reason: String
    public let abstained: Bool
    public let grounding: Double
    public let words: Int
}

public struct CompanionEvalOutcome: Codable, Equatable, Sendable {
    public let suite: String
    public let persona: String
    public let model: String
    public let cases: Int
    public let passed: Int
    public let results: [CompanionEvalCase]
}

public struct CompanionEvalRun: Codable, Equatable, Sendable {
    public let id: String
    public let suite: String
    public let ranAt: String
    public let model: String
    public let cases: Int
    public let passed: Int
}

public struct CompanionStandupClaim: Codable, Equatable, Sendable {
    public let id: String
    public let statement: String
    public let claimType: String
    public let testable: Bool
    public let verdict: String?
    public let note: String?
}

public struct CompanionStandupAggregate: Codable, Equatable, Sendable {
    public let standups: Int
    public let commitmentsResolved: Int
    public let metRate: Double
    public let medianSlipDays: Double?
    public let overstated: Int
    public let understated: Int
    public let invisibleWork: Int
}

public struct CompanionStandupOutcome: Codable, Equatable, Sendable {
    public let episodeId: String
    public let occurredAt: String
    public let claims: [CompanionStandupClaim]
    public let verified: Bool
    public let aggregate: CompanionStandupAggregate?
}

public struct CompanionStandupReport: Codable, Equatable, Sendable {
    public let aggregate: CompanionStandupAggregate
    public let dueSoon: Int
}

public struct CompanionMachine: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let transport: String
    public let endpoint: String
    public let os: String?
    public let arch: String?
    public let gpuVendor: String?
    public let gpuModel: String?
    public let vramMb: Int?
    public let cpuCores: Int?
    public let ramMb: Int?
    public let diskFreeMb: Int?
    public let profile: String?
    public let profileOverride: String?
    public let status: String

    public var effectiveProfile: String { profileOverride ?? profile ?? "unknown" }

    public var plainEnglish: String {
        var parts: [String] = []
        if let os, let arch { parts.append("\(os) \(arch)") }
        if let gpuModel, !gpuModel.isEmpty {
            if let vramMb, vramMb > 0 {
                parts.append("\(gpuModel), \(vramMb / 1024)GB VRAM")
            } else {
                parts.append(gpuModel)
            }
        }
        if let ramMb { parts.append("\(ramMb / 1024)GB RAM") }
        if let diskFreeMb { parts.append("\(diskFreeMb / 1024)GB free") }
        return parts.isEmpty ? "not probed yet" : parts.joined(separator: ", ")
    }
}

public struct CompanionPlacement: Codable, Equatable, Sendable {
    public let machine: String
    public let service: String
    public let role: String
    public let enabled: Bool
    public let notes: String
}

public struct CompanionPlan: Codable, Equatable, Sendable {
    public let placements: [CompanionPlacement]
    public let warnings: [String]
    public let compose: [String]
}

public struct CompanionBaselineRow: Codable, Equatable, Sendable {
    public let kind: String
    public let contextBucket: String
    public let median: Double
    public let iqr: Double
    public let samples: Int
}

public struct CompanionBaselines: Codable, Equatable, Sendable {
    public let audioSeconds: Double
    public let coldStart: Bool
    public let baselines: [CompanionBaselineRow]
}

public struct CompanionNotionOutcome: Codable, Equatable, Sendable {
    public let pagesSeen: Int
    public let pagesWritten: Int
    public let episodesIngested: Int
    public let watermark: String?
    public let fullScan: Bool
}

public struct CompanionConnectorState: Codable, Equatable, Sendable {
    public let configured: Bool
    public let detail: String
}

public struct CompanionConnectorSettings: Codable, Equatable, Sendable {
    public let github: CompanionConnectorState
    public let notion: CompanionConnectorState
    public let sources: [String]
    public let importable: [String]
}

public struct CompanionImportOutcome: Codable, Equatable, Sendable {
    public let source: String
    public let entriesRead: Int
    public let observationsInserted: Int
    public let skipped: Int
}

public struct CompanionFact: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let subject: String
    public let predicate: String
    public let object: String
    public let validFrom: String?
    public let validTo: String?
    public let createdAt: String
    public let expiredAt: String?
    public let confidence: Double?
    public let supersededBy: String?
}

public struct CompanionCorrectOutcome: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let statement: String
}

public struct CompanionCurateOutcome: Codable, Equatable, Sendable {
    public let beliefsExamined: Int
    public let linksMade: Int
    public let contestedReopened: Int
    public let retired: Int
}

public struct CompanionRebuildOutcome: Codable, Equatable, Sendable {
    public let chunksDropped: Int?
    public let beliefsRetired: Int?
    public let factsExpired: Int?
    public let episodesKept: Int?
    public let ok: Bool?
}
