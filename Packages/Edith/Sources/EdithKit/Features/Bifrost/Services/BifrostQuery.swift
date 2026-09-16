import Foundation

public enum BifrostQuery {
    public static let defaultLimit = 8
    public static let minimumResultLimit = 3
    public static let maximumResultLimit = 12
    public static let maximumQueryLength = 200

    public static func results(
        query: String, applications: [BifrostApplication],
        commands: [BifrostCommand] = [], ledger: BifrostUsageLedger = BifrostUsageLedger(),
        now: Date = Date(), limit: Int = defaultLimit
    ) -> [BifrostResult] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumQueryLength else { return [] }
        guard !trimmed.isEmpty else {
            return frequent(
                applications: applications, commands: commands, ledger: ledger, now: now,
                limit: limit)
        }
        var results: [BifrostResult] = []
        if let conversion = BifrostConversionParser.parse(trimmed) {
            results.append(conversionResult(conversion))
        } else if let calculation = BifrostCalculator.evaluate(trimmed) {
            results.append(calculationResult(calculation))
        }
        let room = limit - results.count
        guard room > 0 else { return results }
        results.append(
            contentsOf: matches(
                query: trimmed, applications: applications, commands: commands, ledger: ledger,
                now: now, limit: room))
        return results
    }

    public static func matches(
        query: String, applications: [BifrostApplication], commands: [BifrostCommand] = [],
        ledger: BifrostUsageLedger, now: Date, limit: Int
    ) -> [BifrostResult] {
        let needle = BifrostMatcher.normalize(query)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var scored: [Candidate] = []
        scored.reserveCapacity(min(applications.count + commands.count, 64))
        for application in applications {
            guard let base = BifrostMatcher.score(application.searchTarget, query: needle) else {
                continue
            }
            let key = BifrostAction.launch(path: application.path).targetKey
            scored.append(
                Candidate(
                    result: applicationResult(
                        application, score: base + boost(key, query, ledger, now)),
                    name: application.name, tie: application.path))
        }
        for command in commands {
            guard let base = BifrostMatcher.score(command.target, query: needle) else { continue }
            let key = BifrostAction.run(commandID: command.id).targetKey
            scored.append(
                Candidate(
                    result: commandResult(command, score: base + boost(key, query, ledger, now)),
                    name: command.title, tie: command.id))
        }
        return grouped(order(scored).prefix(limit).map(\.result))
    }

    static func grouped(_ results: [BifrostResult]) -> [BifrostResult] {
        var byKind: [BifrostResultKind: [BifrostResult]] = [:]
        for result in results { byKind[result.kind, default: []].append(result) }
        var ordered: [BifrostResult] = []
        for kind in kindOrder {
            guard let group = byKind[kind] else { continue }
            ordered.append(contentsOf: group)
        }
        return ordered
    }

    static let kindOrder: [BifrostResultKind] = [.conversion, .calculation, .application, .command]

    struct Candidate {
        let result: BifrostResult
        let name: String
        let tie: String
    }

    static func boost(
        _ key: String, _ query: String, _ ledger: BifrostUsageLedger, _ now: Date
    ) -> Int {
        ledger.boost(for: key, now: now) + ledger.queryBoost(for: key, query: query, now: now)
    }

    static func order(_ scored: [Candidate]) -> [Candidate] {
        scored.sorted { first, second in
            if first.result.score != second.result.score {
                return first.result.score > second.result.score
            }
            if first.name.count != second.name.count { return first.name.count < second.name.count }
            if first.name != second.name { return first.name < second.name }
            return first.tie < second.tie
        }
    }

    static func frequent(
        applications: [BifrostApplication], commands: [BifrostCommand],
        ledger: BifrostUsageLedger, now: Date, limit: Int
    ) -> [BifrostResult] {
        var byKey: [String: BifrostResult] = [:]
        for application in applications {
            let key = BifrostAction.launch(path: application.path).targetKey
            guard byKey[key] == nil else { continue }
            byKey[key] = applicationResult(application, score: ledger.boost(for: key, now: now))
        }
        for command in commands {
            let key = BifrostAction.run(commandID: command.id).targetKey
            guard byKey[key] == nil else { continue }
            byKey[key] = commandResult(command, score: ledger.boost(for: key, now: now))
        }
        var results: [BifrostResult] = []
        for key in ledger.ranked(now: now, limit: limit) {
            guard let result = byKey[key] else { continue }
            results.append(result)
            if results.count == limit { break }
        }
        return results
    }

    static func applicationResult(_ application: BifrostApplication, score: Int) -> BifrostResult {
        BifrostResult(
            id: "app:" + application.path, kind: .application, title: application.name,
            subtitle: readablePath(application.path), symbolName: "app.dashed",
            iconPath: application.path, action: .launch(path: application.path), score: score)
    }

    static func commandResult(_ command: BifrostCommand, score: Int) -> BifrostResult {
        BifrostResult(
            id: "command:" + command.id, kind: .command, title: command.title,
            subtitle: command.subtitle, symbolName: command.symbolName,
            action: .run(commandID: command.id), score: score)
    }

    static func calculationResult(_ calculation: BifrostCalculation) -> BifrostResult {
        BifrostResult(
            id: "calc:" + calculation.expression, kind: .calculation, title: calculation.display,
            subtitle: calculation.expression, symbolName: "function",
            action: .copy(text: calculation.copyText), score: Int.max)
    }

    static func conversionResult(_ conversion: BifrostConversion) -> BifrostResult {
        BifrostResult(
            id: "convert:" + conversion.source.id + ">" + conversion.target.id,
            kind: .conversion, title: conversion.display, subtitle: conversion.detail,
            symbolName: "arrow.left.arrow.right", action: .copy(text: conversion.copyText),
            score: Int.max)
    }

    static func readablePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        let shortened = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        return (shortened as NSString).deletingLastPathComponent
    }
}

extension BifrostCommand {
    public var target: BifrostMatchTarget { BifrostMatchTarget(searchText) }
}
