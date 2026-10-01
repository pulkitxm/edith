import EdithKit
import Foundation

@MainActor
enum HerdrLayoutBridge {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = IPC.observe(IPC.Name.requestHerdrLayoutAction) { info in
            MainActor.assumeIsolated {
                Task { await receive(info) }
            }
        }
    }

    static func reply(
        to info: [AnyHashable: Any], store: HerdrStore = .shared, now: Date = Date()
    ) -> [String: Any]? {
        let requestID = info[HerdrLayoutIPC.requestIDKey] as? String
        guard let runtime = HerdrLayoutRuntimeRequest(payload: info) else {
            guard let requestID else { return nil }
            return [
                HerdrLayoutIPC.okKey: false, HerdrLayoutIPC.requestIDKey: requestID,
                HerdrLayoutIPC.errorKey: "The layout request is invalid.",
            ]
        }
        guard runtime.isLive(at: now) else {
            return store.layoutSnapshot().resultPayload(
                requestID: runtime.requestID,
                error: "The layout request expired before it ran.")
        }
        let error = store.performLayout(runtime.request)
        return store.layoutSnapshot().resultPayload(
            requestID: runtime.requestID, error: error)
    }

    private static func receive(_ info: [AnyHashable: Any]) async {
        let store = HerdrStore.shared
        if store.hosts.isEmpty { await store.refresh() }
        guard let payload = reply(to: info, store: store) else { return }
        IPC.post(IPC.Name.herdrLayoutActionResult, userInfo: payload)
    }
}

extension HerdrStore {
    func performLayout(_ request: HerdrLayoutRequest) -> String? {
        switch request {
        case .status:
            return nil
        case let .closeTab(id):
            revealHerdr()
            return closeTabConfirmed(id)
        case let .closeOthers(id):
            revealHerdr()
            return closeOthersConfirmed(besides: id)
        case let .closeRight(id):
            revealHerdr()
            return closeRightConfirmed(of: id)
        case .closeAll:
            revealHerdr()
            closeAllConfirmed()
            return nil
        case let .gather(id):
            revealHerdr()
            return gatherConfirmed(into: id)
        case let .separate(id):
            revealHerdr()
            return separateConfirmed(id)
        case let .split(agent, side):
            guard let side = InsertSide(rawValue: side) else { return "unknown side \(side)" }
            revealHerdr()
            return splitAgent(agent, side: side)
        case let .move(agent, tab):
            revealHerdr()
            return moveAgent(agent, into: tab)
        case let .swap(first, second):
            revealHerdr()
            return swapAgents(first, second)
        case let .save(tab, name):
            revealHerdr()
            return saveArrangementConfirmed(of: tab, named: name)
        case let .deleteLayout(token):
            revealHerdr()
            return deleteArrangement(matching: token)
        case let .apply(tab, name):
            revealHerdr()
            return applyArrangement(name, to: tab)
        case let .even(id):
            revealHerdr()
            return evenConfirmed(id)
        case let .newTerminal(owner):
            revealHerdr()
            _ = openTerminalNow(in: owner)
            return nil
        }
    }

    private func revealHerdr() {
        SharedDefaults.store.set(
            MainDestination.herdr.rawValue, forKey: AppStorageKeys.General.mainWindowSection)
        MainWindow.open()
    }
}
