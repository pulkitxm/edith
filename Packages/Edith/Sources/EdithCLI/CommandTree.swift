import ArgumentParser
import Foundation

public enum ArgumentKind: Equatable, Sendable {
    case machine
    case machineOrLocal
    case appAction
    case runningApp
    case appPath
    case appLink
    case guideTopic
    case cleanerCategory
    case homebrewKind
    case colorFormat
    case colorIndex
    case emojiTone
    case emojiGroup
    case emojiCharacter
    case pruneTarget
    case composeProject
    case historyIndex
    case shelfItem
    case shelfKeepDuration
    case musicTrack
    case calendarEvent
    case configKey
    case configValue
    case extensionID
    case toolID
    case permission
    case onOff
    case shell
    case group
    case usageRange
    case usageShareCard
    case attentionRange
    case attentionEntity
    case attentionCategory
    case downloadKind
    case quinjetAppearance
    case quinjetMachine
    case quinjetPath
    case quinjetSession
    case quinjetTheme
    case localPath
    case musicPlayer
    case remotePath
    case container
    case tool
    case usageChat
    case usageProject
    case usageSource
    case free
}

public enum DestructivePolicy: String, Equatable, Sendable {
    case previewThenYes
}

public struct PassthroughCompletion: Equatable, Sendable {
    public let afterPositionals: Int
    public let remoteMachinePosition: Int?

    public init(afterPositionals: Int, remoteMachinePosition: Int? = nil) {
        self.afterPositionals = afterPositionals
        self.remoteMachinePosition = remoteMachinePosition
    }
}

public struct CommandNode: Equatable, Sendable {
    public let name: String
    public let summary: String
    public let aliases: [String]
    public let options: [String]
    public let optionValues: [String: ArgumentKind]
    public let arguments: [ArgumentKind]
    public let repeatingArgument: ArgumentKind?
    public let children: [CommandNode]
    public let destructivePolicy: DestructivePolicy?
    public let passthroughCompletion: PassthroughCompletion?

    public init(
        _ name: String, _ summary: String, aliases: [String] = [], options: [String] = [],
        optionValues: [String: ArgumentKind] = [:], arguments: [ArgumentKind] = [],
        repeatingArgument: ArgumentKind? = nil, children: [CommandNode] = [],
        destructivePolicy: DestructivePolicy? = nil,
        passthroughCompletion: PassthroughCompletion? = nil
    ) {
        self.name = name
        self.summary = summary
        self.aliases = aliases
        self.options = options
        self.optionValues = optionValues
        self.arguments = arguments
        self.repeatingArgument = repeatingArgument
        self.children = children
        self.destructivePolicy = destructivePolicy
        self.passthroughCompletion = passthroughCompletion
    }

    public var names: [String] { [name] + aliases }

    public func child(_ name: String) -> CommandNode? {
        children.first { $0.names.contains(name) }
    }
}

public struct CommandSpec: Equatable, Sendable {
    public let options: [String]
    public let optionValues: [String: ArgumentKind]
    public let arguments: [ArgumentKind]
    public let repeatingArgument: ArgumentKind?
    public let destructivePolicy: DestructivePolicy?
    public let passthroughCompletion: PassthroughCompletion?

    public init(
        options: [String] = [], optionValues: [String: ArgumentKind] = [:],
        arguments: [ArgumentKind] = [], repeatingArgument: ArgumentKind? = nil,
        destructivePolicy: DestructivePolicy? = nil,
        passthroughCompletion: PassthroughCompletion? = nil
    ) {
        self.options = options
        self.optionValues = optionValues
        self.arguments = arguments
        self.repeatingArgument = repeatingArgument
        self.destructivePolicy = destructivePolicy
        self.passthroughCompletion = passthroughCompletion
    }
}

public enum CommandTree {
    public static let inherited = ["-h", "--help", "--version"]
    public static let common = ["--json"] + inherited

    typealias Spec = CommandSpec

    static let specs: [String: Spec] = [
        "ed": Spec(options: ["--help", "--version"]),
        "ed guide": Spec(options: ["--json"], arguments: [.guideTopic]),
        "ed version": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed status": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed completions install": Spec(
            options: ["--json", "--shell"], optionValues: ["--shell": .shell]),
        "ed completions source": Spec(
            options: ["--json", "--shell"], optionValues: ["--shell": .shell]),
        "ed install": Spec(options: ["--json", "--directory"]),
        "ed uninstall": Spec(options: ["--json"]),
        "ed config ls": Spec(
            options: ["--json", "--group", "--changed"], optionValues: ["--group": .group]),
        "ed config get": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.configKey]),
        "ed config set": Spec(options: ["--json"], arguments: [.configKey, .configValue]),
        "ed config unset": Spec(options: ["--json"], arguments: [.configKey]),
        "ed config describe": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.configKey]),
        "ed config export": Spec(options: ["--defaults"]),
        "ed config import": Spec(options: ["--json", "--dry-run"], arguments: [.localPath]),
        "ed app info": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed app diagnostics": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed app paths": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed app links": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed app open-path": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.appPath]),
        "ed app open-link": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.appLink]),
        "ed agent status": Spec(options: common),
        "ed agent jobs": Spec(options: common),
        "ed agent restart": Spec(options: common),
        "ed agent logs": Spec(options: ["--json", "--last"]),
        "ed app actions": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed app clean-keys": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed app test-notification": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed app open": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed app quit": Spec(
            options: ["--json", "--help", "--yes"], destructivePolicy: .previewThenYes),
        "ed app check-updates": Spec(options: ["--json", "--help", "--no-wait"]),
        "ed app updates": Spec(options: ["--json", "--help", "--limit"]),
        "ed app relaunch": Spec(
            options: ["--json", "--help", "--yes"], destructivePolicy: .previewThenYes),
        "ed app clear-updates": Spec(
            options: ["--json", "--help", "--yes"], destructivePolicy: .previewThenYes),
        "ed app reveal": Spec(options: ["--json", "--help", "--tab"]),
        "ed app snapshot": Spec(options: ["--json", "--help", "--dir"]),
        "ed extensions ls": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed extensions enable": Spec(options: ["--json"], arguments: [.extensionID]),
        "ed extensions disable": Spec(options: ["--json"], arguments: [.extensionID]),
        "ed extensions info": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.extensionID]),
        "ed extensions status": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.extensionID]),
        "ed extensions setup": Spec(
            options: ["--json", "--help", "--dry-run", "--install-tools"], arguments: [.extensionID]
        ),
        "ed extensions verify": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.extensionID]),
        "ed extensions doctor": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.extensionID]),
        "ed lid-awake status": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed lid-awake on": Spec(
            options: ["--json", "--help", "--for", "--until-lid-reopens", "--yes"],
            destructivePolicy: .previewThenYes),
        "ed lid-awake off": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed lid-awake battery": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed lid-awake restore-on-quit": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.free],
            destructivePolicy: .previewThenYes),
        "ed permissions ls": Spec(options: ["--json", "--help", "--attention"]),
        "ed permissions request": Spec(options: ["--json"], arguments: [.permission]),
        "ed permissions refresh": Spec(options: ["--json"]),
        "ed permissions settings": Spec(options: ["--json"], arguments: [.permission]),
        "ed usage limits": Spec(options: ["--json", "--help", "--refresh"]),
        "ed usage summary": Spec(
            options: ["--json", "--range", "--source", "--machine"],
            optionValues: ["--machine": .machine, "--range": .usageRange, "--source": .usageSource]),
        "ed usage daily": Spec(
            options: ["--json", "--range", "--source", "--machine"],
            optionValues: ["--machine": .machine, "--range": .usageRange, "--source": .usageSource]),
        "ed usage models": Spec(
            options: ["--json", "--range", "--source", "--machine"],
            optionValues: ["--machine": .machine, "--range": .usageRange, "--source": .usageSource]),
        "ed usage projects list": Spec(
            options: ["--json", "--range", "--limit"], optionValues: ["--range": .usageRange]),
        "ed usage projects show": Spec(
            options: ["--json", "--range"], optionValues: ["--range": .usageRange],
            arguments: [.usageProject]),
        "ed usage projects open": Spec(
            options: ["--json", "--range"], optionValues: ["--range": .usageRange],
            arguments: [.usageProject]),
        "ed usage projects copy-link": Spec(
            options: ["--json", "--range"], optionValues: ["--range": .usageRange],
            arguments: [.usageProject]),
        "ed usage projects copy-chat": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.usageChat]),
        "ed usage sources": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed usage export": Spec(
            options: [
                "--json", "--help", "--range", "--source", "--machine", "--card", "-o", "--output",
            ],
            optionValues: [
                "--card": .usageShareCard, "--machine": .machine, "--output": .localPath,
                "--range": .usageRange, "--source": .usageSource, "-o": .localPath,
            ]),
        "ed usage machines ls": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed usage machines collect": Spec(
            options: ["--json", "--verbose", "--once", "--timeout"], arguments: [.machine]),
        "ed usage machines enable": Spec(options: ["--json"], arguments: [.machine]),
        "ed usage machines disable": Spec(options: ["--json"], arguments: [.machine]),
        "ed usage machines forget": Spec(options: ["--json"], arguments: [.machine]),
        "ed usage refresh": Spec(options: ["--json", "--follow", "--machines", "--no-machines"]),
        "ed system stats": Spec(options: ["--json", "-f", "--follow", "--interval", "--processes"]),
        "ed system disks": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed music": Spec(
            options: ["--json", "--help", "--player"], optionValues: ["--player": .musicPlayer]),
        "ed music status": Spec(
            options: ["--json", "--help", "--player"], optionValues: ["--player": .musicPlayer]),
        "ed music players": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed music play": Spec(
            options: ["--json", "--help", "--player"], optionValues: ["--player": .musicPlayer]),
        "ed music pause": Spec(
            options: ["--json", "--help", "--player"], optionValues: ["--player": .musicPlayer]),
        "ed music stop": Spec(
            options: ["--json", "--help", "--player"], optionValues: ["--player": .musicPlayer]),
        "ed music toggle": Spec(
            options: ["--json", "--help", "--player"], optionValues: ["--player": .musicPlayer]),
        "ed music next": Spec(
            options: ["--json", "--help", "--player"], optionValues: ["--player": .musicPlayer]),
        "ed music previous": Spec(
            options: ["--json", "--help", "--player"], optionValues: ["--player": .musicPlayer]),
        "ed music volume": Spec(
            options: ["--json", "--help", "--player"], optionValues: ["--player": .musicPlayer]),
        "ed music open-current": Spec(
            options: ["--json", "--help", "--player"], optionValues: ["--player": .musicPlayer]),
        "ed music reveal-current": Spec(
            options: ["--json", "--help", "--player"], optionValues: ["--player": .musicPlayer]),
        "ed music library": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.localPath]),
        "ed music start": Spec(options: ["--json", "--help", "--folder"], arguments: [.free]),
        "ed music favorite": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.musicTrack]),
        "ed music unfavorite": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.musicTrack]),
        "ed music reveal": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.musicTrack]),
        "ed music open": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed music rescan": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed music seek": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed music shuffle": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed music repeat": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed music ls": Spec(
            options: ["--json", "--help", "--folders", "--recursive", "--search"],
            arguments: [.free]),
        "ed music mkdir": Spec(options: ["--json", "--help", "--under"], arguments: [.free]),
        "ed music mv": Spec(options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed music rename": Spec(options: ["--json", "--help", "--folder"], arguments: [.free]),
        "ed music rm": Spec(
            options: ["--json", "--help", "--folder", "--yes"], arguments: [.free],
            destructivePolicy: .previewThenYes),
        "ed calendar ls": Spec(options: ["--json", "--days"]),
        "ed calendar open": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed calendar join": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.calendarEvent]),
        "ed calendar directions": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.calendarEvent]),
        "ed presenter status": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed presenter start": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed presenter stop": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed herdr ls": Spec(options: ["--json", "-h", "--help", "--version", "--machine"]),
        "ed herdr command": Spec(
            options: ["--json", "-h", "--help", "--version", "--machine", "--session"],
            arguments: [.free]),
        "ed herdr attach": Spec(
            options: ["--json", "-h", "--help", "--version", "--machine", "--session"],
            arguments: [.free]),
        "ed tools ls": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed tools install": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.tool]),
        "ed apps ls": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed apps quit": Spec(
            options: ["--json", "--help", "--all", "--force", "--yes"], arguments: [.runningApp],
            destructivePolicy: .previewThenYes),
        "ed download ls": Spec(options: ["--json", "--help", "--active", "--limit"]),
        "ed download status": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed download add": Spec(
            options: ["--json", "--help", "--kind", "--prefix"],
            optionValues: ["--kind": .downloadKind], arguments: [.free]),
        "ed download retry": Spec(
            options: ["--json", "--help", "--all"], arguments: [.historyIndex]),
        "ed download rm": Spec(
            options: ["--json", "-h", "--help", "--version", "--yes"], arguments: [.historyIndex],
            destructivePolicy: .previewThenYes),
        "ed download clear": Spec(
            options: ["--json", "--help", "--yes"], destructivePolicy: .previewThenYes),
        "ed download cancel": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.historyIndex]),
        "ed download open": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.historyIndex]),
        "ed download reveal": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.historyIndex]),
        "ed download tool": Spec(options: ["--json", "--help", "--update"]),
        "ed clipboard ls": Spec(options: ["--json", "--help", "--pinned", "--search", "--limit"]),
        "ed clipboard stats": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed clipboard get": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.historyIndex]),
        "ed clipboard copy": Spec(
            options: ["--json", "--help", "--plain"], arguments: [.historyIndex]),
        "ed clipboard pin": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.historyIndex]),
        "ed clipboard unpin": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.historyIndex]),
        "ed clipboard rm": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.historyIndex],
            destructivePolicy: .previewThenYes),
        "ed clipboard clear": Spec(
            options: ["--json", "--help", "--keep-pinned", "--yes"],
            destructivePolicy: .previewThenYes),
        "ed attention status": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed attention summary": Spec(
            options: ["--json", "--help", "--range"], optionValues: ["--range": .attentionRange]),
        "ed attention timeline": Spec(
            options: ["--json", "--help", "--range", "--limit"],
            optionValues: ["--range": .attentionRange]),
        "ed attention music": Spec(
            options: ["--json", "--help", "--range", "--limit"],
            optionValues: ["--range": .attentionRange]),
        "ed attention categories ls": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed attention categories set": Spec(
            options: ["--json", "--help", "--name"],
            arguments: [.attentionEntity, .attentionCategory]),
        "ed attention focus status": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed attention focus start": Spec(options: ["--json", "--help", "--for", "--name"]),
        "ed attention focus stop": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed attention doctor": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed color pick": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed color copy": Spec(
            options: ["--json", "--help", "--format"], optionValues: ["--format": .colorFormat],
            arguments: [.colorIndex]),
        "ed color ls": Spec(
            options: ["--json", "--help", "--format", "--limit"],
            optionValues: ["--format": .colorFormat]),
        "ed color clear": Spec(options: ["--json", "--yes"], destructivePolicy: .previewThenYes),
        "ed emoji pick": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed emoji ls": Spec(
            options: ["--json", "--help", "--frequent", "--search", "--group", "--limit"],
            optionValues: ["--group": .emojiGroup]),
        "ed emoji insert": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.emojiCharacter]),
        "ed emoji tone": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.emojiTone]),
        "ed emoji clear": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed shelf ls": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed shelf path": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.shelfItem]),
        "ed shelf add": Spec(options: ["--json"], arguments: [.localPath]),
        "ed shelf add-text": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed shelf update": Spec(
            options: ["--json", "--help", "--x", "--y"], arguments: [.shelfItem]),
        "ed shelf rm": Spec(
            options: ["--json", "--yes"], arguments: [.shelfItem], repeatingArgument: .shelfItem,
            destructivePolicy: .previewThenYes),
        "ed shelf clear": Spec(options: ["--json", "--yes"], destructivePolicy: .previewThenYes),
        "ed shelf purge": Spec(
            options: ["--json", "--yes"], arguments: [.shelfKeepDuration],
            destructivePolicy: .previewThenYes),
        "ed shelf open": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.shelfItem],
            repeatingArgument: .shelfItem),
        "ed shelf reveal": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.shelfItem],
            repeatingArgument: .shelfItem),
        "ed shelf share": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.shelfItem],
            repeatingArgument: .shelfItem),
        "ed cleaner scan": Spec(
            options: ["--json", "--help", "--category", "--root"],
            optionValues: ["--category": .cleanerCategory]),
        "ed cleaner categories": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed cleaner clean": Spec(
            options: ["--json", "--help", "--category", "--root", "--yes"],
            optionValues: ["--category": .cleanerCategory], destructivePolicy: .previewThenYes),
        "ed cleaner drives": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed brew status": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed brew ls": Spec(
            options: ["--json", "--help", "--kind", "--outdated"],
            optionValues: ["--kind": .homebrewKind]),
        "ed brew search": Spec(
            options: ["--json", "--help", "--kind"], optionValues: ["--kind": .homebrewKind],
            arguments: [.free]),
        "ed brew install": Spec(
            options: ["--json", "--help", "--kind"], optionValues: ["--kind": .homebrewKind],
            arguments: [.free]),
        "ed brew upgrade": Spec(
            options: ["--json", "--help", "--kind"], optionValues: ["--kind": .homebrewKind],
            arguments: [.free]),
        "ed brew uninstall": Spec(
            options: ["--json", "--help", "--kind", "--yes"],
            optionValues: ["--kind": .homebrewKind], arguments: [.free],
            destructivePolicy: .previewThenYes),
        "ed maintenance inventory": Spec(options: ["--json", "--help", "--no-updates"]),
        "ed maintenance scan": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.localPath]),
        "ed maintenance remove": Spec(
            options: ["--json", "--help", "--only-app", "--yes"], arguments: [.localPath],
            destructivePolicy: .previewThenYes),
        "ed maintenance install": Spec(
            options: ["--json", "--help", "--system", "--replace", "--keep-image", "--yes"],
            arguments: [.localPath], destructivePolicy: .previewThenYes),
        "ed maintenance updates": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed maintenance update": Spec(
            options: ["--json", "--help", "--yes", "--concurrency", "--retries"],
            repeatingArgument: .free, destructivePolicy: .previewThenYes),
        "ed maintenance history": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed maintenance backup-updates": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.localPath]),
        "ed quinjet projects": Spec(
            options: ["--json", "--help", "--machine"], optionValues: ["--machine": .quinjetMachine]
        ),
        "ed quinjet worktrees": Spec(
            options: ["--json", "--help", "--machine"],
            optionValues: ["--machine": .quinjetMachine], arguments: [.quinjetPath]),
        "ed quinjet open": Spec(
            options: [
                "--json", "--help", "--machine", "--theme", "--appearance", "--cmux", "--embedded",
            ],
            optionValues: [
                "--appearance": .quinjetAppearance, "--machine": .quinjetMachine,
                "--theme": .quinjetTheme,
            ], arguments: [.quinjetPath]),
        "ed quinjet launch": Spec(
            options: [
                "--json", "--help", "--machine", "--theme", "--appearance", "--cmux", "--embedded",
            ],
            optionValues: [
                "--appearance": .quinjetAppearance, "--machine": .quinjetMachine,
                "--theme": .quinjetTheme,
            ], arguments: [.quinjetPath]),
        "ed quinjet status": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.quinjetSession]),
        "ed quinjet sessions": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed quinjet new": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed quinjet focus": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.quinjetSession]),
        "ed quinjet close": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.quinjetSession],
            destructivePolicy: .previewThenYes),
        "ed quinjet restart": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.quinjetSession]),
        "ed quinjet switch": Spec(
            options: ["--json", "-h", "--help", "--version"],
            arguments: [.quinjetSession, .quinjetPath]),
        "ed database connections list": Spec(
            options: [
                "--json", "--help", "--search", "--product", "--environment", "--group", "--tag",
                "--favorites-only", "--order", "--limit", "--offset",
            ],
            optionValues: [
                "--environment": .free, "--group": .free, "--limit": .free, "--offset": .free,
                "--order": .free, "--product": .free, "--search": .free, "--tag": .free,
            ]),
        "ed database connections get": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed database connections add": Spec(
            options: [
                "--json", "--help", "--product", "--host", "--port", "--path", "--username",
                "--database", "--authentication-database", "--password-stdin", "--tls",
                "--environment", "--environment-label", "--protection", "--read-only",
                "--production-policy",
            ],
            optionValues: [
                "--authentication-database": .free, "--database": .free, "--environment": .free,
                "--environment-label": .free, "--host": .free, "--path": .free, "--port": .free,
                "--product": .free, "--production-policy": .free, "--protection": .free,
                "--read-only": .free, "--username": .free,
            ], arguments: [.free]),
        "ed database connections test": Spec(
            options: ["--json", "--help", "--timeout-milliseconds"],
            optionValues: ["--timeout-milliseconds": .free], arguments: [.free]),
        "ed database connections edit": Spec(
            options: [
                "--json", "--help", "--environment", "--environment-label", "--protection",
                "--read-only", "--production-policy", "--group", "--clear-group", "--tag",
                "--clear-tags", "--color", "--clear-color", "--favorite", "--not-favorite",
            ],
            optionValues: [
                "--color": .free, "--environment": .free, "--environment-label": .free,
                "--group": .free, "--production-policy": .free, "--protection": .free,
                "--read-only": .free, "--tag": .free,
            ], arguments: [.free]),
        "ed database connections duplicate": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free, .free]),
        "ed database connections rename": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free, .free]),
        "ed database connections delete": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.free],
            destructivePolicy: .previewThenYes),
        "ed database saved-queries list": Spec(
            options: [
                "--json", "--help", "--search", "--connection", "--language", "--tag",
                "--favorites-only", "--order", "--limit", "--offset",
            ],
            optionValues: [
                "--connection": .free, "--language": .free, "--limit": .free, "--offset": .free,
                "--order": .free, "--search": .free, "--tag": .free,
            ]),
        "ed database saved-queries get": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed database saved-queries save": Spec(
            options: [
                "--json", "--help", "--id", "--connection", "--language", "--file", "--tag",
                "--favorite",
            ],
            optionValues: [
                "--connection": .free, "--file": .free, "--id": .free, "--language": .free,
                "--tag": .free,
            ], arguments: [.free]),
        "ed database saved-queries duplicate": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free, .free]),
        "ed database saved-queries rename": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free, .free]),
        "ed database saved-queries delete": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.free],
            destructivePolicy: .previewThenYes),
        "ed database capabilities": Spec(
            options: ["--json", "--help", "--refresh"], arguments: [.free]),
        "ed database connect": Spec(
            options: ["--json", "--help", "--timeout-milliseconds"],
            optionValues: ["--timeout-milliseconds": .free], arguments: [.free]),
        "ed database disconnect": Spec(
            options: ["--json", "--help", "--timeout-milliseconds"],
            optionValues: ["--timeout-milliseconds": .free], arguments: [.free]),
        "ed database browse": Spec(
            options: [
                "--json", "--ndjson", "--help", "--kind", "--path", "--limit", "--continuation",
                "--timeout-milliseconds",
            ],
            optionValues: [
                "--continuation": .free, "--kind": .free, "--limit": .free, "--path": .free,
                "--timeout-milliseconds": .free,
            ], arguments: [.free]),
        "ed database query": Spec(
            options: [
                "--json", "--ndjson", "--help", "--language", "--file", "--kind", "--path",
                "--limit", "--continuation", "--timeout-milliseconds",
            ],
            optionValues: [
                "--continuation": .free, "--file": .free, "--kind": .free, "--language": .free,
                "--limit": .free, "--path": .free, "--timeout-milliseconds": .free,
            ], arguments: [.free]),
        "ed database mutations row-request": Spec(
            options: ["--json", "--help", "--action", "--path", "--identity", "--values"],
            optionValues: [
                "--action": .free, "--identity": .free, "--path": .free, "--values": .free,
            ], arguments: [.free]),
        "ed database mutations key-request": Spec(
            options: [
                "--json", "--help", "--action", "--product", "--logical-database", "--key",
                "--value", "--ttl-milliseconds",
            ],
            optionValues: [
                "--action": .free, "--key": .free, "--logical-database": .free, "--product": .free,
                "--ttl-milliseconds": .free, "--value": .free,
            ], arguments: [.free]),
        "ed database mutations document-request": Spec(
            options: [
                "--json", "--help", "--product", "--action", "--path", "--document",
                "--document-id", "--id-kind", "--sequence-number", "--primary-term",
            ],
            optionValues: [
                "--action": .free, "--document": .free, "--document-id": .free, "--id-kind": .free,
                "--path": .free, "--primary-term": .free, "--product": .free,
                "--sequence-number": .free,
            ], arguments: [.free]),
        "ed database mutations preview": Spec(
            options: ["--json", "--help", "--request", "--timeout-milliseconds"],
            optionValues: ["--request": .free, "--timeout-milliseconds": .free]),
        "ed database mutations apply": Spec(
            options: [
                "--json", "--help", "--yes", "--request", "--confirmation",
                "--timeout-milliseconds",
            ],
            optionValues: [
                "--confirmation": .free, "--request": .free, "--timeout-milliseconds": .free,
            ], destructivePolicy: .previewThenYes),
        "ed database mutations status": Spec(
            options: ["--json", "--help", "--receipt", "--timeout-milliseconds"],
            optionValues: ["--receipt": .free, "--timeout-milliseconds": .free]),
        "ed database mutations cancel": Spec(
            options: ["--json", "--help", "--yes", "--receipt", "--timeout-milliseconds"],
            optionValues: ["--receipt": .free, "--timeout-milliseconds": .free],
            destructivePolicy: .previewThenYes),
        "ed database mutations outcome": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed database operations list": Spec(
            options: [
                "--json", "--help", "--connection", "--state", "--kind", "--before", "--limit",
            ],
            optionValues: [
                "--before": .free, "--connection": .free, "--kind": .free, "--limit": .free,
                "--state": .free,
            ]),
        "ed database operations get": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed database operations cancel": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed machines": Spec(arguments: [.machine]),
        "ed machines ls": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed machines show": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines add": Spec(
            options: [
                "--json", "--help", "--host", "--port", "--user", "--key", "--alias", "--mac",
                "--password-stdin", "--key-passphrase-stdin",
            ], arguments: [.free]),
        "ed machines edit": Spec(
            options: [
                "--json", "--help", "--name", "--host", "--port", "--user", "--key", "--agent",
                "--mac", "--sudo-password-stdin", "--forget-sudo-password", "--password-stdin",
                "--key-passphrase-stdin",
            ], arguments: [.machine]),
        "ed machines rm": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine],
            destructivePolicy: .previewThenYes),
        "ed machines forwards ls": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines forwards add": Spec(
            options: ["--json", "--help", "--local", "--remote", "--remote-host", "--title"],
            arguments: [.machine]),
        "ed machines forwards on": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines forwards off": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines forwards open": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines forwards rm": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines snippets ls": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines snippets add": Spec(
            options: ["--json", "--help", "--shared"], arguments: [.machine, .free, .free],
            passthroughCompletion: PassthroughCompletion(afterPositionals: 2)),
        "ed machines snippets rm": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines snippets run": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines power status": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines power reboot": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine],
            destructivePolicy: .previewThenYes),
        "ed machines power shutdown": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine],
            destructivePolicy: .previewThenYes),
        "ed machines power wake": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines thermal status": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines thermal set": Spec(
            options: ["--json", "--help", "--minutes"], arguments: [.machine, .free]),
        "ed machines control status": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines control brightness": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines control volume": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines control mute": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .onOff]),
        "ed machines control wifi": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine, .onOff],
            destructivePolicy: .previewThenYes),
        "ed machines control bluetooth": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .onOff]),
        "ed machines control airplane": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine, .onOff],
            destructivePolicy: .previewThenYes),
        "ed machines control dnd": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .onOff]),
        "ed machines control caffeinate": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .onOff]),
        "ed machines control keyboard-light": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines workspace ls": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed machines workspace use": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed machines workspace new": Spec(
            options: ["--json", "--help", "--screen", "--name"], arguments: [.machine]),
        "ed machines workspace rename": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed machines workspace rm": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed machines workspace panes": Spec(options: ["--json", "--help", "--workspace"]),
        "ed machines workspace split": Spec(
            options: ["--json", "--help", "--workspace", "--side", "--screen"],
            arguments: [.historyIndex, .machine]),
        "ed machines workspace close": Spec(
            options: ["--json", "--help", "--workspace"], arguments: [.historyIndex]),
        "ed machines workspace point": Spec(
            options: ["--json", "--help", "--workspace", "--screen"],
            arguments: [.historyIndex, .machine]),
        "ed machines workspace equalize": Spec(options: ["--json", "--help", "--workspace"]),
        "ed machines broadcast": Spec(options: ["--json", "--help", "--only"], arguments: [.free]),
        "ed machines terminal broadcast": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machineOrLocal, .free]),
        "ed machines kill": Spec(
            options: ["--json", "--help", "--signal", "--yes"],
            arguments: [.machine, .historyIndex], destructivePolicy: .previewThenYes),
        "ed machines metrics": Spec(
            options: ["--json", "-f", "--follow", "--interval", "--processes"],
            arguments: [.machine]),
        "ed machines exec": Spec(
            options: ["-t", "--tty"], arguments: [.machine, .free],
            passthroughCompletion: PassthroughCompletion(
                afterPositionals: 1, remoteMachinePosition: 0)),
        "ed machines files ls": Spec(
            options: ["--json", "--help", "-a", "--all"], arguments: [.machine, .remotePath]),
        "ed machines files get": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
            arguments: [.machine, .remotePath, .localPath], destructivePolicy: .previewThenYes),
        "ed machines files preview": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files launch": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files reveal": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files get-many": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes", "--to"],
            optionValues: ["--to": .localPath], arguments: [.machine, .remotePath],
            repeatingArgument: .remotePath, destructivePolicy: .previewThenYes),
        "ed machines files transfer": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes", "--into"],
            optionValues: ["--into": .remotePath], arguments: [.machine, .machine, .remotePath],
            repeatingArgument: .remotePath, destructivePolicy: .previewThenYes),
        "ed machines files put": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
            arguments: [.machine, .localPath, .remotePath], destructivePolicy: .previewThenYes),
        "ed machines files cp": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
            arguments: [.machine, .remotePath], repeatingArgument: .remotePath,
            destructivePolicy: .previewThenYes),
        "ed machines files mv": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
            arguments: [.machine, .remotePath], repeatingArgument: .remotePath,
            destructivePolicy: .previewThenYes),
        "ed machines files rename": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files mkdir": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files search": Spec(
            options: ["--json", "--help", "--limit"], arguments: [.machine, .remotePath, .free]),
        "ed machines files info": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files undo": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines files duplicate": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files rm": Spec(
            options: ["--json", "--help", "--delete", "--yes"], arguments: [.machine, .remotePath],
            destructivePolicy: .previewThenYes),
        "ed machines docker shell": Spec(arguments: [.machine, .container]),
        "ed machines docker ps": Spec(options: ["--json", "-a", "--all"], arguments: [.machine]),
        "ed machines docker images": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines docker volumes": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines docker networks": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines docker df": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines docker logs": Spec(
            options: ["--tail", "-f", "--follow"], arguments: [.machine, .container]),
        "ed machines docker inspect": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .container]),
        "ed machines docker top": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .container]),
        "ed machines docker open": Spec(
            options: ["--json", "--help", "--port"], arguments: [.machine, .container]),
        "ed machines docker start": Spec(options: ["--json"], arguments: [.machine, .container]),
        "ed machines docker stop": Spec(options: ["--json"], arguments: [.machine, .container]),
        "ed machines docker restart": Spec(options: ["--json"], arguments: [.machine, .container]),
        "ed machines docker rm": Spec(
            options: ["--json", "--yes"], arguments: [.machine, .container],
            destructivePolicy: .previewThenYes),
        "ed machines docker pause": Spec(options: ["--json"], arguments: [.machine, .container]),
        "ed machines docker unpause": Spec(options: ["--json"], arguments: [.machine, .container]),
        "ed machines docker rmi": Spec(
            options: ["--json", "--help", "--force", "--yes"], arguments: [.machine, .free],
            destructivePolicy: .previewThenYes),
        "ed machines docker volume-rm": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine, .free],
            destructivePolicy: .previewThenYes),
        "ed machines docker prune": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine, .pruneTarget],
            destructivePolicy: .previewThenYes),
        "ed machines docker compose ls": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines docker compose up": Spec(
            options: ["--json"], arguments: [.machine, .composeProject]),
        "ed machines docker compose down": Spec(
            options: ["--json"], arguments: [.machine, .composeProject]),
        "ed machines docker compose restart": Spec(
            options: ["--json"], arguments: [.machine, .composeProject]),
        "ed machines docker compose pull": Spec(
            options: ["--json"], arguments: [.machine, .composeProject]),
        "ed machines docker compose logs": Spec(
            options: ["--tail", "-f", "--follow", "--help"], arguments: [.machine, .composeProject]),
        "ed machines services ls": Spec(options: ["--json", "--failed"], arguments: [.machine]),
        "ed machines services start": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines services stop": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines services restart": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines connect": Spec(options: ["--json"], arguments: [.machine]),
        "ed machines disconnect": Spec(options: ["--json"], arguments: [.machine]),
        "ed machines mount": Spec(
            options: ["--json", "--help", "--at", "--read-only"],
            arguments: [.machine, .remotePath]),
        "ed machines unmount": Spec(options: ["--json"], arguments: [.machine]),
        "ed machines mounts": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed machines mount-reveal": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed companion status": Spec(options: ["--json", "-h", "--help", "--version", "--endpoint"]),
        "ed companion doctor": Spec(options: ["--json", "-h", "--help", "--version", "--endpoint"]),
        "ed companion search": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--limit"],
            arguments: [.free]),
        "ed companion index": Spec(options: ["--json", "-h", "--help", "--version", "--endpoint"]),
        "ed companion ingest": Spec(options: ["--json", "--endpoint"], arguments: [.localPath]),
        "ed companion episodes": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit",
        ]),
        "ed companion episode": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--body", "--open"],
            arguments: [.free]),
        "ed companion sync": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--full"],
            arguments: [.free]),
        "ed companion observations": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit", "--kind",
        ]),
        "ed companion reflect": Spec(options: ["--json", "-h", "--help", "--version", "--endpoint"]
        ),
        "ed companion beliefs": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit",
        ]),
        "ed companion ask": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--persona"],
            arguments: [.free]),
        "ed companion council": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--personas"],
            arguments: [.free]),
        "ed companion personas": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion lenses": Spec(options: ["--json", "-h", "--help", "--version", "--endpoint"]),
        "ed companion core show": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion core set": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint"],
            arguments: [.free, .free]),
        "ed companion why": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint"], arguments: [.free]),
        "ed companion hypotheses ls": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit",
        ]),
        "ed companion hypotheses run": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion predictions": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit",
        ]),
        "ed companion commitments": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit",
        ]),
        "ed companion discrepancies ls": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit",
        ]),
        "ed companion discrepancies override": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--real"],
            arguments: [.free]),
        "ed companion calibration": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion inquire next": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--explain",
        ]),
        "ed companion inquire answer": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint"],
            arguments: [.free, .free]),
        "ed companion inquire skip": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint"], arguments: [.free]),
        "ed companion inquire mute": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint"], arguments: [.free]),
        "ed companion inquire ls": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit",
        ]),
        "ed companion entities": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit",
        ]),
        "ed companion eval run": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--persona",
        ]),
        "ed companion eval ls": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit",
        ]),
        "ed companion standup record": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--verify"],
            arguments: [.localPath]),
        "ed companion standup report": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion machines ls": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion machines add": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--transport", "--at"],
            arguments: [.free]),
        "ed companion machines probe": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint"], arguments: [.free]),
        "ed companion machines plan": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion machines profile": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint"],
            arguments: [.free, .free]),
        "ed companion baselines": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion connectors show": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion connectors set": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--github", "--notion",
        ]),
        "ed companion connectors import": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint"],
            arguments: [.free, .localPath]),
        "ed companion facts": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--as-of", "--timeline", "--limit",
        ]),
        "ed companion correct": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--retire", "--edit"],
            arguments: [.free]),
        "ed companion weekly": Spec(options: ["--json", "-h", "--help", "--version", "--endpoint"]),
        "ed companion db migrate": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion db reindex": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--yes"],
            destructivePolicy: .previewThenYes),
        "ed companion db rebuild-derived": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--yes"],
            destructivePolicy: .previewThenYes),
        "ed companion chat": Spec(
            options: [
                "--json", "-h", "--help", "--version", "--endpoint", "--conversation", "--persona",
            ], arguments: [.free]),
        "ed companion conversations": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--limit"],
            arguments: [.free]),
        "ed companion forget": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--yes"],
            arguments: [.free], destructivePolicy: .previewThenYes),
        "ed companion extract": Spec(options: ["--json", "-h", "--help", "--version", "--endpoint"]
        ),
        "ed companion claims": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit",
        ]),
        "ed companion corroborate": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion runs": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--limit",
        ]),
        "ed companion nightly": Spec(options: ["--json", "-h", "--help", "--version", "--endpoint"]
        ),
        "ed companion reason show": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion reason set": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint", "--provider", "--model", "--url",
            "--api-key",
        ]),
        "ed companion reason test": Spec(options: [
            "--json", "-h", "--help", "--version", "--endpoint",
        ]),
        "ed companion hosts": Spec(options: ["--json", "-h", "--help", "--version", "--machine"]),
        "ed companion deploy": Spec(
            options: ["--json", "-h", "--help", "--version", "--directory", "--port", "--adopt"],
            arguments: [.machine]),
        "ed companion stack status": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed companion stack up": Spec(options: ["--json", "-h", "--help", "--version", "--build"]),
        "ed companion stack down": Spec(
            options: ["--json", "-h", "--help", "--version", "--wipe", "--yes"],
            destructivePolicy: .previewThenYes),
        "ed companion stack restart": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed companion stack logs": Spec(
            options: ["--json", "-h", "--help", "--version", "--tail"], arguments: [.free]),
        "ed companion stack env": Spec(options: ["--json", "-h", "--help", "--version", "--reveal"]
        ),
        "ed companion export": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--include-media"],
            arguments: [.localPath]),
        "ed companion import": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint"], arguments: [.localPath]),
        "ed companion erase": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--yes"],
            arguments: [.free], destructivePolicy: .previewThenYes),
        "ed companion wipe": Spec(
            options: ["--json", "-h", "--help", "--version", "--endpoint", "--yes"],
            destructivePolicy: .previewThenYes),
        "help": Spec(arguments: [.free]),
    ]

    public static let root = node(for: EdRoot.self, path: ["ed"])

    public static let help = CommandNode(
        "help", "Show detailed help for a command.",
        arguments: specs["help"]?.arguments ?? [])

    public static var topLevelNames: [String] {
        root.children.flatMap(\.names) + help.names
    }

    public static func node(at path: [String]) -> CommandNode? {
        var current = root
        for name in path {
            guard let next = current.child(name) else { return nil }
            current = next
        }
        return current
    }

    static func node(for command: ParsableCommand.Type, path: [String]) -> CommandNode {
        let configuration = command.configuration
        let spec = specs[path.joined(separator: " ")] ?? Spec()
        let children = configuration.subcommands.filter { $0.configuration.shouldDisplay }
            .map { child in
                let name =
                    child.configuration.commandName ?? String(describing: child).lowercased()
                return node(for: child, path: path + [name])
            }
        return CommandNode(
            path.last ?? "ed", configuration.abstract, aliases: configuration.aliases,
            options: spec.options, optionValues: spec.optionValues, arguments: spec.arguments,
            repeatingArgument: spec.repeatingArgument, children: children,
            destructivePolicy: spec.destructivePolicy,
            passthroughCompletion: spec.passthroughCompletion)
    }
}
