import Foundation

public enum BifrostQuery {
    public static let defaultLimit = 8
    public static let minimumResultLimit = 3
    public static let maximumResultLimit = 12
    public static let maximumQueryLength = 200

    public static func results(
        query: String, applications: [BifrostApplication],
        ledger: BifrostUsageLedger = BifrostUsageLedger(), now: Date = Date(),
        limit: Int = defaultLimit
    ) -> [BifrostResult] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumQueryLength else { return [] }
        guard !trimmed.isEmpty else {
            return frequent(applications: applications, ledger: ledger, now: now, limit: limit)
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
                query: trimmed, applications: applications, ledger: ledger, now: now,
                limit: room))
        return results
    }

    public static func matches(
        query: String, applications: [BifrostApplication], ledger: BifrostUsageLedger,
        now: Date, limit: Int
    ) -> [BifrostResult] {
        let needle = BifrostMatcher.normalize(query)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var scored: [(application: BifrostApplication, score: Int)] = []
        scored.reserveCapacity(min(applications.count, 64))
        for application in applications {
            guard let base = BifrostMatcher.score(application.searchTarget, query: needle) else {
                continue
            }
            let boost = ledger.boost(
                for: BifrostAction.launch(path: application.path).targetKey,
                now: now)
            scored.append((application, base + boost))
        }
        let ordered = order(scored)
        return ordered.prefix(limit).map(applicationResult)
    }

    static func order(
        _ scored: [(application: BifrostApplication, score: Int)]
    ) -> [(application: BifrostApplication, score: Int)] {
        scored.sorted { first, second in
            if first.score != second.score { return first.score > second.score }
            if first.application.name.count != second.application.name.count {
                return first.application.name.count < second.application.name.count
            }
            if first.application.name != second.application.name {
                return first.application.name < second.application.name
            }
            return first.application.path < second.application.path
        }
    }

    static func frequent(
        applications: [BifrostApplication], ledger: BifrostUsageLedger, now: Date, limit: Int
    ) -> [BifrostResult] {
        let byKey = Dictionary(
            applications.map { (BifrostAction.launch(path: $0.path).targetKey, $0) },
            uniquingKeysWith: { first, _ in first })
        var results: [BifrostResult] = []
        for key in ledger.ranked(now: now, limit: limit) {
            guard let application = byKey[key] else { continue }
            results.append(
                applicationResult((application, ledger.boost(for: key, now: now))))
            if results.count == limit { break }
        }
        return results
    }

    static func applicationResult(
        _ scored: (application: BifrostApplication, score: Int)
    ) -> BifrostResult {
        BifrostResult(
            id: "app:" + scored.application.path, kind: .application,
            title: scored.application.name,
            subtitle: readablePath(scored.application.path), symbolName: "app.dashed",
            iconPath: scored.application.path,
            action: .launch(path: scored.application.path), score: scored.score)
    }

    static func calculationResult(_ calculation: BifrostCalculation) -> BifrostResult {
        BifrostResult(
            id: "calc:" + calculation.expression, kind: .calculation,
            title: calculation.display,
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
