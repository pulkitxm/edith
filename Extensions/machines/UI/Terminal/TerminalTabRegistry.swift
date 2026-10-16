import EdithExtensionSupport
import Foundation

@MainActor
enum TerminalTabRegistry {
    static weak var active: TerminalTabsModel?
    private static var models: [UUID: [WeakTerminalTabsModel]] = [:]

    static func register(_ model: TerminalTabsModel, machineID: UUID) {
        active = model
        var available = models[machineID, default: []].filter { $0.value != nil }
        if !available.contains(where: { $0.value === model }) {
            available.append(WeakTerminalTabsModel(model))
        }
        models[machineID] = available
    }

    static func unregister(_ model: TerminalTabsModel, machineID: UUID) {
        let available = models[machineID, default: []].filter {
            $0.value != nil && $0.value !== model
        }
        if available.isEmpty {
            models.removeValue(forKey: machineID)
        } else {
            models[machineID] = available
        }
        if active === model { active = nil }
    }

    static func broadcast(
        _ plan: MachineBroadcastPlan, machineID: UUID,
        isLive: @MainActor (TerminalSessionHolder) -> Bool = { $0.started },
        send: @MainActor (TerminalSessionHolder, String) -> Void = {
            $0.sendInput($1)
        }
    ) -> MachineTerminalBroadcastDelivery? {
        let available = models[machineID, default: []].compactMap(\.value)
        guard !available.isEmpty else {
            models.removeValue(forKey: machineID)
            return nil
        }
        models[machineID] = available.map(WeakTerminalTabsModel.init)
        let delivery = available.reduce(
            MachineTerminalBroadcastDelivery(sent: 0, unavailable: 0)
        ) { total, model in
            let next = model.sendBroadcast(plan, isLive: isLive, send: send)
            return MachineTerminalBroadcastDelivery(
                sent: total.sent + next.sent,
                unavailable: total.unavailable + next.unavailable)
        }
        return delivery.total > 0 ? delivery : nil
    }

    static func failureMessage(for delivery: MachineTerminalBroadcastDelivery) -> String {
        if delivery.sent == 0 {
            let noun = delivery.unavailable == 1 ? "tab" : "tabs"
            return
                "That machine has \(delivery.unavailable) open terminal \(noun), but none are running."
        }
        let sentNoun = delivery.sent == 1 ? "tab" : "tabs"
        let unavailableNoun = delivery.unavailable == 1 ? "tab was" : "tabs were"
        return
            "Sent to \(delivery.sent) running terminal \(sentNoun). \(delivery.unavailable) unavailable \(unavailableNoun) skipped."
    }

    @discardableResult
    static func cycle(backwards: Bool) -> Bool {
        guard let active, active.tabs.count > 1 else { return false }
        active.selectNext(backwards: backwards)
        return true
    }
}

private final class WeakTerminalTabsModel {
    weak var value: TerminalTabsModel?

    init(_ value: TerminalTabsModel) {
        self.value = value
    }
}
