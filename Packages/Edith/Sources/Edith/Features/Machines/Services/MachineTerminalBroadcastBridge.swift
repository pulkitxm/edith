import EdithKit
import Foundation

@MainActor
enum MachineTerminalBroadcastBridge {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = IPC.observe(
            IPC.Name.requestMachineTerminalBroadcast,
            info: { info in
                MainActor.assumeIsolated {
                    IPC.post(
                        IPC.Name.machineTerminalBroadcastResult,
                        userInfo: response(to: info))
                }
            })
    }

    static func response(
        to info: [AnyHashable: Any],
        isLive: @MainActor (TerminalSessionHolder) -> Bool = { $0.started },
        send: @MainActor (TerminalSessionHolder, String) -> Void = {
            $0.terminalView.send(txt: $1)
        }
    ) -> [String: Any] {
        let requestID = info[MachineTerminalBroadcastIPC.requestIDKey] as? String ?? ""
        guard
            !requestID.isEmpty,
            UUID(uuidString: requestID) != nil,
            let rawMachineID = info[MachineTerminalBroadcastIPC.machineIDKey] as? String,
            let machineID = UUID(uuidString: rawMachineID),
            let command = info[MachineTerminalBroadcastIPC.commandKey] as? String
        else {
            return failure(
                requestID: requestID, code: MachineTerminalBroadcastIPC.invalidRequestCode,
                message: "The terminal broadcast request was invalid.")
        }
        let plan: MachineBroadcastPlan
        switch MachineBroadcastOperationExecution.plan(command: command) {
        case let .success(value):
            plan = value
        case let .failure(error):
            return failure(
                requestID: requestID, code: MachineTerminalBroadcastIPC.invalidRequestCode,
                message: error.localizedDescription)
        }
        guard
            let delivery = TerminalTabRegistry.broadcast(
                plan, machineID: machineID, isLive: isLive, send: send)
        else {
            return failure(
                requestID: requestID, code: MachineTerminalBroadcastIPC.noOpenTabsCode,
                message: "That machine has no open terminal tabs.")
        }
        guard delivery.sent > 0 else {
            return failure(
                requestID: requestID, code: MachineTerminalBroadcastIPC.noLiveTabsCode,
                message: TerminalTabRegistry.failureMessage(for: delivery), delivery: delivery)
        }
        guard delivery.unavailable == 0 else {
            return failure(
                requestID: requestID, code: MachineTerminalBroadcastIPC.partialDeliveryCode,
                message: TerminalTabRegistry.failureMessage(for: delivery), delivery: delivery)
        }
        return [
            MachineTerminalBroadcastIPC.requestIDKey: requestID,
            MachineTerminalBroadcastIPC.okKey: true,
            MachineTerminalBroadcastIPC.machineIDKey: machineID.uuidString,
            MachineTerminalBroadcastIPC.commandKey: plan.command,
            MachineTerminalBroadcastIPC.tabCountKey: delivery.sent,
            MachineTerminalBroadcastIPC.unavailableTabCountKey: delivery.unavailable,
        ]
    }

    private static func failure(
        requestID: String, code: String, message: String,
        delivery: MachineTerminalBroadcastDelivery? = nil
    ) -> [String: Any] {
        var response: [String: Any] = [
            MachineTerminalBroadcastIPC.requestIDKey: requestID,
            MachineTerminalBroadcastIPC.okKey: false,
            MachineTerminalBroadcastIPC.errorCodeKey: code,
            MachineTerminalBroadcastIPC.errorKey: message,
        ]
        if let delivery {
            response[MachineTerminalBroadcastIPC.tabCountKey] = delivery.sent
            response[MachineTerminalBroadcastIPC.unavailableTabCountKey] = delivery.unavailable
        }
        return response
    }
}
