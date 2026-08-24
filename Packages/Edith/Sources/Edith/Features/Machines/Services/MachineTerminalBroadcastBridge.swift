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
        send: @MainActor (TerminalSessionHolder, String) -> Void = {
            $0.terminalView.send(txt: $1)
        }
    ) -> [String: Any] {
        let requestID = info[MachineTerminalBroadcastIPC.requestIDKey] as? String ?? ""
        guard
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
            let tabCount = TerminalTabRegistry.broadcast(
                plan, machineID: machineID, send: send)
        else {
            return failure(
                requestID: requestID, code: MachineTerminalBroadcastIPC.noOpenTabsCode,
                message: "That machine has no open terminal tabs.")
        }
        return [
            MachineTerminalBroadcastIPC.requestIDKey: requestID,
            MachineTerminalBroadcastIPC.okKey: true,
            MachineTerminalBroadcastIPC.machineIDKey: machineID.uuidString,
            MachineTerminalBroadcastIPC.commandKey: plan.command,
            MachineTerminalBroadcastIPC.tabCountKey: tabCount,
        ]
    }

    private static func failure(
        requestID: String, code: String, message: String
    ) -> [String: Any] {
        [
            MachineTerminalBroadcastIPC.requestIDKey: requestID,
            MachineTerminalBroadcastIPC.okKey: false,
            MachineTerminalBroadcastIPC.errorCodeKey: code,
            MachineTerminalBroadcastIPC.errorKey: message,
        ]
    }
}
