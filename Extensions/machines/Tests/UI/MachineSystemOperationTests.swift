@testable import MachinesExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite struct MachineSystemUIOperationTests {
    private let machine = Machine(name: "box", host: "box.example")
    @MainActor @Test func terminalBroadcastSendsOnlyToLiveTabs() throws {
        let model = TerminalTabsModel()
        let live = model.addTab(named: "One")
        model.addTab(named: "Two")
        var inputs: [String] = []
        let plan = try MachineBroadcastOperationExecution.plan(command: " uptime ").get()

        let result = model.sendBroadcast(
            plan, isLive: { $0 === live.holder }, send: { _, input in inputs.append(input) })

        #expect(result == MachineTerminalBroadcastDelivery(sent: 1, unavailable: 1))
        #expect(inputs == ["uptime\n"])
    }

    @MainActor @Test func terminalTabWaitsForGhosttyCloseConfirmation() throws {
        var decide: ((Bool) -> Void)?
        let model = TerminalTabsModel { _, completion in decide = completion }
        let first = model.addTab(named: "One")
        let second = model.addTab(named: "Two")

        model.closeTab(second.id)

        #expect(model.tabs.map(\.id) == [first.id, second.id])
        #expect(model.selected == second.id)
        let cancel = try #require(decide)
        cancel(false)
        #expect(model.tabs.map(\.id) == [first.id, second.id])
        #expect(model.selected == second.id)

        model.closeTab(second.id)
        let confirm = try #require(decide)
        confirm(true)

        #expect(model.tabs.map(\.id) == [first.id])
        #expect(model.selected == first.id)
    }

    @MainActor @Test func terminalTabWithoutALiveGhosttySurfaceClosesImmediately() {
        let model = TerminalTabsModel()
        let first = model.addTab(named: "One")
        let second = model.addTab(named: "Two")

        model.closeTab(second.id)

        #expect(model.tabs.map(\.id) == [first.id])
        #expect(model.selected == first.id)
    }

    @MainActor @Test func terminalBroadcastIPCIsCorrelatedAndScopedByMachineIdentity() throws {
        let first = TerminalTabsModel()
        let firstLive = first.addTab(named: "One")
        first.addTab(named: "Two")
        let second = TerminalTabsModel()
        let secondLive = second.addTab(named: "Three")
        let other = TerminalTabsModel()
        other.addTab(named: "Other")
        let otherID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        TerminalTabRegistry.register(first, machineID: machine.id)
        TerminalTabRegistry.register(second, machineID: machine.id)
        TerminalTabRegistry.register(other, machineID: otherID)
        defer {
            TerminalTabRegistry.unregister(first, machineID: machine.id)
            TerminalTabRegistry.unregister(second, machineID: machine.id)
            TerminalTabRegistry.unregister(other, machineID: otherID)
        }
        var inputs: [String] = []
        let requestID = UUID().uuidString
        let response = MachineTerminalBroadcastBridge.response(
            to: [
                MachineTerminalBroadcastIPC.requestIDKey: requestID,
                MachineTerminalBroadcastIPC.machineIDKey: machine.id.uuidString,
                MachineTerminalBroadcastIPC.commandKey: " uptime ",
            ], isLive: { $0 === firstLive.holder || $0 === secondLive.holder },
            send: { _, input in inputs.append(input) })

        #expect(response[MachineTerminalBroadcastIPC.requestIDKey] as? String == requestID)
        #expect(response[MachineTerminalBroadcastIPC.okKey] as? Bool == false)
        #expect(
            response[MachineTerminalBroadcastIPC.errorCodeKey] as? String
                == MachineTerminalBroadcastIPC.partialDeliveryCode)
        #expect(response[MachineTerminalBroadcastIPC.tabCountKey] as? Int == 2)
        #expect(response[MachineTerminalBroadcastIPC.unavailableTabCountKey] as? Int == 1)
        #expect(inputs == ["uptime\n", "uptime\n"])

        let missing = MachineTerminalBroadcastBridge.response(
            to: [
                MachineTerminalBroadcastIPC.requestIDKey: UUID().uuidString,
                MachineTerminalBroadcastIPC.machineIDKey: UUID().uuidString,
                MachineTerminalBroadcastIPC.commandKey: "uptime",
            ])
        #expect(missing[MachineTerminalBroadcastIPC.okKey] as? Bool == false)
        #expect(
            missing[MachineTerminalBroadcastIPC.errorCodeKey] as? String
                == MachineTerminalBroadcastIPC.noOpenTabsCode)
    }

    @MainActor @Test func terminalBroadcastRejectsMissingEmptyAndMalformedRequestIDs() {
        let model = TerminalTabsModel()
        model.addTab(named: "One")
        TerminalTabRegistry.register(model, machineID: machine.id)
        defer { TerminalTabRegistry.unregister(model, machineID: machine.id) }
        var sends = 0
        let requests: [[AnyHashable: Any]] = [
            [
                MachineTerminalBroadcastIPC.machineIDKey: machine.id.uuidString,
                MachineTerminalBroadcastIPC.commandKey: "uptime",
            ],
            [
                MachineTerminalBroadcastIPC.requestIDKey: "",
                MachineTerminalBroadcastIPC.machineIDKey: machine.id.uuidString,
                MachineTerminalBroadcastIPC.commandKey: "uptime",
            ],
            [
                MachineTerminalBroadcastIPC.requestIDKey: "request-1",
                MachineTerminalBroadcastIPC.machineIDKey: machine.id.uuidString,
                MachineTerminalBroadcastIPC.commandKey: "uptime",
            ],
        ]

        for request in requests {
            let response = MachineTerminalBroadcastBridge.response(
                to: request, isLive: { _ in true }, send: { _, _ in sends += 1 })
            #expect(response[MachineTerminalBroadcastIPC.okKey] as? Bool == false)
            #expect(
                response[MachineTerminalBroadcastIPC.errorCodeKey] as? String
                    == MachineTerminalBroadcastIPC.invalidRequestCode)
        }
        #expect(sends == 0)
    }

    @MainActor @Test func terminalBroadcastReportsAllUnavailableWithoutSending() {
        let model = TerminalTabsModel()
        model.addTab(named: "One")
        model.addTab(named: "Two")
        TerminalTabRegistry.register(model, machineID: machine.id)
        defer { TerminalTabRegistry.unregister(model, machineID: machine.id) }
        var sends = 0

        let response = MachineTerminalBroadcastBridge.response(
            to: [
                MachineTerminalBroadcastIPC.requestIDKey: UUID().uuidString,
                MachineTerminalBroadcastIPC.machineIDKey: machine.id.uuidString,
                MachineTerminalBroadcastIPC.commandKey: "uptime",
            ], isLive: { _ in false }, send: { _, _ in sends += 1 })

        #expect(response[MachineTerminalBroadcastIPC.okKey] as? Bool == false)
        #expect(
            response[MachineTerminalBroadcastIPC.errorCodeKey] as? String
                == MachineTerminalBroadcastIPC.noLiveTabsCode)
        #expect(response[MachineTerminalBroadcastIPC.tabCountKey] as? Int == 0)
        #expect(response[MachineTerminalBroadcastIPC.unavailableTabCountKey] as? Int == 2)
        #expect(sends == 0)
    }

}
