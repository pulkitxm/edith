import EdithCore
import Foundation

public enum CompanionMindRuntimeOperation: String, CaseIterable, Identifiable, Sendable {
    case nightly
    case coreSet
    case inquireNext
    case stackUp
    case stackDown
    case stackRestart
    case deploy

    public var id: String { rawValue }

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: operationID), summary: summary, cli: cli,
            effect: effect)
    }

    public var placements: [UserInterfaceActionPlacement] {
        switch self {
        case .nightly:
            [
                UserInterfaceActionPlacement(
                    surface: "Companion mind", action: "run the nightly pipeline")
            ]
        case .coreSet:
            [
                UserInterfaceActionPlacement(
                    surface: "Companion mind", action: "edit a section of the standing summary",
                    exampleArguments: ["values", "honest"])
            ]
        case .inquireNext:
            [
                UserInterfaceActionPlacement(
                    surface: "Companion desk", action: "show the question it wants to ask today")
            ]
        case .stackUp:
            [
                UserInterfaceActionPlacement(
                    surface: "Companion backend", action: "start the stack on its host")
            ]
        case .stackDown:
            [
                UserInterfaceActionPlacement(
                    surface: "Companion backend", action: "stop the stack on its host")
            ]
        case .stackRestart:
            [
                UserInterfaceActionPlacement(
                    surface: "Companion backend", action: "restart the stack on its host")
            ]
        case .deploy:
            [
                UserInterfaceActionPlacement(
                    surface: "Companion backend",
                    action: "choose the machine that runs the companion"),
                UserInterfaceActionPlacement(
                    surface: "Companion setup", action: "set up the companion on a machine"),
            ]
        }
    }

    private var operationID: String {
        switch self {
        case .nightly: "companion.learning.nightly"
        case .coreSet: "companion.core.set"
        case .inquireNext: "companion.inquiry.next"
        case .stackUp: "companion.stack.up"
        case .stackDown: "companion.stack.down"
        case .stackRestart: "companion.stack.restart"
        case .deploy: "companion.deploy"
        }
    }

    private var cli: [String] {
        switch self {
        case .nightly: ["companion", "nightly"]
        case .coreSet: ["companion", "core", "set"]
        case .inquireNext: ["companion", "inquire", "next"]
        case .stackUp: ["companion", "stack", "up"]
        case .stackDown: ["companion", "stack", "down"]
        case .stackRestart: ["companion", "stack", "restart"]
        case .deploy: ["companion", "deploy"]
        }
    }

    private var summary: String {
        switch self {
        case .nightly: "Run the nightly learning pipeline now."
        case .coreSet: "Rewrite one standing-summary section."
        case .inquireNext: "Read the question worth asking now."
        case .stackUp: "Start the companion stack on its host."
        case .stackDown: "Stop the companion stack on its host."
        case .stackRestart: "Restart the companion stack on its host."
        case .deploy: "Choose and prepare the companion host."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .inquireNext: .read
        case .nightly, .coreSet, .stackUp, .stackDown, .stackRestart, .deploy: .write
        }
    }
}

public enum CompanionMindRuntimeOperationExecution {
    public static func nightly(
        using execute: () async throws -> CompanionNightlyStart
    ) async rethrows -> CompanionNightlyStart {
        try await execute()
    }

    public static func setCore(
        section: String, content: String,
        using execute: (String, String) async throws -> CompanionWriteAck
    ) async rethrows -> CompanionWriteAck {
        try await execute(section, content)
    }

    public static func nextQuestion(
        using execute: () async throws -> CompanionNextQuestion
    ) async rethrows -> CompanionNextQuestion {
        try await execute()
    }

    public static func deployment(
        host: CompanionHost, directory: String = CompanionDeployment.defaultRemoteDirectory,
        localPort: Int
    ) -> CompanionDeployment {
        CompanionDeployment(
            machineID: host.isLocal ? nil : host.id, machineName: host.name,
            directory: directory, tier: (host.tier ?? .cpu).rawValue,
            localPort: localPort)
    }

    public static func deploy(
        using execute: () async throws -> CompanionDeployment
    ) async rethrows -> CompanionDeployment {
        try await execute()
    }

    public static func start(
        _ deployment: CompanionDeployment, build: Bool,
        using run: (String, CompanionDeployment, TimeInterval) async throws -> String
    ) async rethrows -> String {
        try await run(
            CompanionStackCommands.up(
                directory: deployment.directory, tier: deployment.resolvedTier, build: build),
            deployment, 1800)
    }

    public static func stop(
        _ deployment: CompanionDeployment, wipe: Bool,
        using run: (String, CompanionDeployment, TimeInterval) async throws -> String
    ) async rethrows -> String {
        try await run(
            CompanionStackCommands.down(
                directory: deployment.directory, tier: deployment.resolvedTier,
                keepData: !wipe),
            deployment, 300)
    }

    public static func restart(
        _ deployment: CompanionDeployment,
        using run: (String, CompanionDeployment, TimeInterval) async throws -> String
    ) async rethrows -> String {
        try await run(
            CompanionStackCommands.restart(
                directory: deployment.directory, tier: deployment.resolvedTier),
            deployment, 600)
    }
}

public enum CompanionMindRuntimeOperationText {
    public static func nightly(_ started: CompanionNightlyStart) -> String {
        "pipeline finished, run \(started.runId); see `ed companion runs`"
    }

    public static func coreSet(_ section: String) -> String {
        "rewrote \(section)"
    }
}
