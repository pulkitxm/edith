import Foundation

struct CLIDestructivePlan {
    let action: String
    let targets: [String]
    let confirmed: Bool
    let json: Bool
    let fields: [String: JSONValue]

    init(
        action: String, targets: [String], confirmed: Bool, json: Bool,
        fields: [String: JSONValue] = [:]
    ) {
        self.action = action
        self.targets = targets
        self.confirmed = confirmed
        self.json = json
        self.fields = fields
    }

    func shouldApply() -> Bool {
        guard !confirmed else { return true }
        emit(applied: false, changed: false)
        if !json { CLIOut.note("nothing changed; pass --yes to apply this plan") }
        return false
    }

    func finish(changed: Bool, plain: String, fields resultFields: [String: JSONValue] = [:]) {
        guard json else {
            CLIOut.out(plain)
            return
        }
        emit(applied: true, changed: changed, fields: resultFields)
    }

    private func emit(
        applied: Bool, changed: Bool, fields resultFields: [String: JSONValue] = [:]
    ) {
        var payload = fields
        for (key, value) in resultFields { payload[key] = value }
        payload["action"] = .string(action)
        payload["targets"] = .strings(targets)
        payload["applied"] = .bool(applied)
        payload["changed"] = .bool(changed)
        guard json else {
            let displayTargets = targets.map(TextTable.oneLine)
            CLIOut.out(
                displayTargets.isEmpty
                    ? "would \(TextTable.oneLine(action))"
                    : "would \(TextTable.oneLine(action)): \(displayTargets.joined(separator: ", "))"
            )
            return
        }
        CLIOut.json(.object(payload))
    }
}
