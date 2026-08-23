import Combine
import EdithKit
import Foundation
import SwiftUI

struct LidAwakeRows: View {
    @AppStorage(LidAwakeState.enabledKey, store: SharedDefaults.store) private var enabled = false
    @AppStorage(LidAwakeState.restoreOnQuitKey, store: SharedDefaults.store)
    private var restoreOnQuit = true
    @AppStorage(LidAwakeState.sessionKey, store: SharedDefaults.store)
    private var sessionRaw = LidAwakeSession.indefinite.rawValue
    @AppStorage(LidAwakeState.batteryThresholdKey, store: SharedDefaults.store)
    private var batteryThreshold = 0
    @State private var active = SharedDefaults.store.bool(forKey: LidAwakeState.activeKey)

    private var activeBinding: Binding<Bool> {
        Binding(get: { active }, set: { _ in IPC.post(IPC.Name.toggleLidAwake) })
    }

    private var sessionBinding: Binding<LidAwakeSession> {
        Binding(
            get: { LidAwakeSession(rawValue: sessionRaw) ?? .indefinite },
            set: { session in
                $sessionRaw.configured(LidAwakeState.sessionKey).wrappedValue = session.rawValue
                IPC.post(
                    IPC.Name.setLidAwakeSession,
                    userInfo: ["session": session.rawValue])
            })
    }

    var body: some View {
        Group {
            Section {
                Toggle(isOn: activeBinding) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Lid awake")
                        InfoDot(
                            "Closing the lid normally sleeps the Mac even when Keep awake is on. This turns that pathway off, so the Mac keeps running with the lid shut - no external display or charger needed."
                        )
                    }
                }
                .pointerCursor()
                Text(
                    "The first activation may open Login Items for one-time approval of Edith's background helper. After that, shelf toggles are silent."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                Picker("Session", selection: sessionBinding) {
                    ForEach(LidAwakeSession.allCases, id: \.self) { session in
                        Text(session.title).tag(session)
                    }
                }
                .pointerCursor()
                Picker(
                    "Auto-pause below",
                    selection: $batteryThreshold.configured(LidAwakeState.batteryThresholdKey)
                ) {
                    Text("Off").tag(0)
                    Text("10% battery").tag(10)
                    Text("20% battery").tag(20)
                    Text("30% battery").tag(30)
                }
                .pointerCursor()
                Text(
                    "When the Mac is on battery and reaches this floor, lid awake pauses until it is charged again. Starting it manually below the floor overrides the pause for that discharge."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                Toggle(
                    isOn: $restoreOnQuit.configured(LidAwakeState.restoreOnQuitKey)
                ) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Restore normal sleep when Edith quits")
                        InfoDot(
                            "Leave this on so the Mac sleeps normally again once Edith is not running. Turning the extension off always restores it, whatever this is set to."
                        )
                    }
                }
                .pointerCursor()
                Text(
                    "While this is on the Mac stays awake with a closed lid, so it keeps drawing power and shedding heat. Do not put it in a bag like this."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
            }
            Section {
                Text(
                    "The lid-awake idea was inspired by Awayke, an MIT-licensed macOS utility by daemonphantom."
                )
                Link(
                    "View Awayke on GitHub",
                    destination: URL(string: "https://github.com/daemonphantom/Awayke")!)
            } header: {
                Text("Acknowledgement")
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onAppear { active = SharedDefaults.store.bool(forKey: LidAwakeState.activeKey) }
        .onReceive(
            DistributedNotificationCenter.default().publisher(for: IPC.Name.lidAwakeChanged)
        ) { _ in
            active = SharedDefaults.store.bool(forKey: LidAwakeState.activeKey)
        }
        .onChange(of: batteryThreshold) {
            IPC.post(IPC.Name.lidAwakeSettingsChanged)
        }
    }
}
