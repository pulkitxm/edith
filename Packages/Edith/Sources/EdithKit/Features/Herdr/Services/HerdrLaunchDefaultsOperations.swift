import EdithCore
import Foundation

public enum HerdrLaunchOperation: String, CaseIterable, Sendable {
    case models
    case defaults
    case setDefaults

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .models:
            descriptor(
                "herdr.models", "List each agent's models, effort levels and fast mode.",
                cli: ["herdr", "models"], effect: .read)
        case .defaults:
            descriptor(
                "herdr.defaults.list", "Show the model, effort and fast mode each launch uses.",
                cli: ["herdr", "defaults", "ls"], effect: .read)
        case .setDefaults:
            descriptor(
                "herdr.defaults.set", "Choose the model, effort and fast mode for an agent kind.",
                cli: ["herdr", "defaults", "set"], effect: .write)
        }
    }

    private func descriptor(
        _ id: String, _ summary: String, cli: [String], effect: UserOperationEffect
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: id), summary: summary, cli: cli, effect: effect)
    }
}

public enum HerdrLaunchDefaults {
    public static let clearValue = "none"

    public static func updated(
        _ current: AgentLaunchOptions, model: String?, effort: String?, fast: Bool?
    ) -> AgentLaunchOptions {
        var next = current
        if let model { next.model = model == clearValue || model.isEmpty ? nil : model }
        if let effort { next.effort = effort == clearValue || effort.isEmpty ? nil : effort }
        if let fast { next.fast = fast }
        return next
    }

    @discardableResult
    public static func set(
        _ kind: AgentLaunchKind, model: String?, effort: String?, fast: Bool?,
        catalog: AgentLaunchCatalog, in defaults: UserDefaults = SharedDefaults.store
    ) throws -> AgentLaunchOptions {
        let next = updated(
            HerdrLaunchSettings.options(for: kind.rawValue, in: defaults), model: model,
            effort: effort, fast: fast)
        try AgentLaunchArguments.validate(next, in: catalog)
        HerdrLaunchSettings.setOptions(next, for: kind.rawValue, in: defaults)
        return next
    }
}
