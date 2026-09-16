import EdithCore
import Foundation

public enum BifrostOperation: String, CaseIterable, Sendable {
    case open
    case ls
    case calc
    case convert
    case reindex
    case clear

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .open:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "bifrost.open"),
                summary: "Open the Bifrost launcher.", cli: ["bifrost", rawValue],
                effect: .interactive)
        case .ls:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "bifrost.ls"),
                summary: "List the applications Bifrost has indexed.", cli: ["bifrost", rawValue],
                effect: .read)
        case .calc:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "bifrost.calc"),
                summary: "Evaluate an expression the way the launcher does.",
                cli: ["bifrost", rawValue], effect: .read)
        case .convert:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "bifrost.convert"),
                summary: "Convert between units the way the launcher does.",
                cli: ["bifrost", rawValue], effect: .read)
        case .reindex:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "bifrost.reindex"),
                summary: "Rebuild the Bifrost application index.", cli: ["bifrost", rawValue],
                effect: .write)
        case .clear:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "bifrost.clear"),
                summary: "Forget what Bifrost ranks as frequently opened.",
                cli: ["bifrost", rawValue], effect: .write)
        }
    }
}

public enum BifrostOperationError: LocalizedError, Equatable {
    case notAnExpression(String)
    case notAConversion(String)

    public var errorDescription: String? {
        switch self {
        case .notAnExpression(let value):
            "\u{201C}\(value)\u{201D} is not an expression Bifrost can evaluate."
        case .notAConversion(let value):
            "\u{201C}\(value)\u{201D} is not a conversion Bifrost understands."
        }
    }
}

public enum BifrostOperationExecution {
    @discardableResult
    public static func request(
        _ operation: BifrostOperation, userInfo: [String: Any]? = nil,
        post: (Notification.Name, [String: Any]?) -> Void = { IPC.post($0, userInfo: $1) }
    ) -> UserOperationDescriptor {
        switch operation {
        case .open: post(IPC.Name.requestBifrostPanel, userInfo)
        case .reindex: post(IPC.Name.requestBifrostReindex, nil)
        case .clear: post(IPC.Name.settingsChanged, nil)
        case .ls, .calc, .convert: break
        }
        return operation.descriptor
    }

    public static func calculate(_ expression: String) throws -> BifrostCalculation {
        guard let calculation = BifrostCalculator.evaluate(expression) else {
            throw BifrostOperationError.notAnExpression(expression)
        }
        return calculation
    }

    public static func convert(_ sentence: String) throws -> BifrostConversion {
        guard let conversion = BifrostConversionParser.parse(sentence) else {
            throw BifrostOperationError.notAConversion(sentence)
        }
        return conversion
    }

    public static func clear(store: UserDefaults = SharedDefaults.store) -> Int {
        var ledger = BifrostUsageLedger.load(from: store, key: AppStorageKeys.Bifrost.usage)
        let removed = ledger.entries.count
        ledger.clear()
        ledger.save(to: store, key: AppStorageKeys.Bifrost.usage)
        request(.clear)
        return removed
    }
}

public enum BifrostPanelIPC {
    public static let queryKey = "query"

    public static func openPayload(query: String) -> [String: Any]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : [queryKey: trimmed]
    }
}

public enum BifrostSummary {
    public static func availability(
        index: BifrostIndex?, store: UserDefaults = SharedDefaults.store
    ) -> String {
        guard let index, index.isUsable else {
            return "No applications indexed yet; the launcher builds its index on first use."
        }
        let ledger = BifrostUsageLedger.load(from: store, key: AppStorageKeys.Bifrost.usage)
        let applications = index.applications.count
        return
            "\(applications) applications indexed, \(ledger.entries.count) opened from the bar."
    }

    public static func resultLimit(store: UserDefaults = SharedDefaults.store) -> Int {
        let stored = store.object(forKey: AppStorageKeys.Bifrost.resultLimit) as? Int
        guard let stored else { return BifrostQuery.defaultLimit }
        return min(
            max(stored, BifrostQuery.minimumResultLimit), BifrostQuery.maximumResultLimit)
    }
}
