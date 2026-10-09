import Combine
import EdithExtensionSupport
import EdithExtensionUI
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
    @State private var confirmingActivation = false
    @ObservedObject var operations: LidAwakeOperationModel

    private var activeBinding: Binding<Bool> {
        Binding(
            get: { active },
            set: { wanted in
                if wanted {
                    confirmingActivation = true
                } else {
                    operations.perform(.off)
                }
            })
    }

    private var sessionBinding: Binding<LidAwakeSession> {
        Binding(
            get: { LidAwakeSession(rawValue: sessionRaw) ?? .indefinite },
            set: { session in
                $sessionRaw.lidAwakeSetting(LidAwakeState.sessionKey).wrappedValue =
                    session.rawValue
                if active { operations.perform(.on(session)) }
            })
    }

    private var batteryBinding: Binding<Int> {
        Binding(
            get: { LidAwakeState.normalizedBatteryThreshold(batteryThreshold) },
            set: { threshold in
                applySetting(.setBatteryThreshold(threshold))
            })
    }

    var body: some View {
        Group {
            Section {
                Toggle(isOn: activeBinding) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Keep running with lid closed")
                        InfoDot(
                            "Closing the lid normally sleeps the Mac even when Keep awake is on. This turns that pathway off, so the Mac keeps running with the lid shut - no external display or charger needed."
                        )
                    }
                }
                Text(
                    "The first activation may open Login Items for one-time approval of Edith's background helper. After that, shelf toggles are silent."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                Picker("Session", selection: sessionBinding) {
                    ForEach(LidAwakeSession.allCases, id: \.self) { session in
                        Text(session.title).tag(session)
                    }
                }
                Picker("Auto-pause below", selection: batteryBinding) {
                    Text("Off").tag(0)
                    Text("10% battery").tag(10)
                    Text("20% battery").tag(20)
                    Text("30% battery").tag(30)
                }
                Text(
                    "When the Mac is on battery and reaches this floor, lid awake pauses until it is charged again. Starting it manually below the floor overrides the pause for that discharge."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                Label(
                    "Sleep is restored before disabling, updating, or quitting Edith",
                    systemImage: "checkmark.shield"
                )
                .font(.edithText(.caption))
                Text(
                    "While this is on the Mac stays awake with a closed lid, so it keeps drawing power and shedding heat. Do not put it in a bag like this."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                if operations.applying {
                    HStack {
                        SkeletonGroup {
                            SkeletonBlock(width: 184, height: 9, corner: 4)
                        }
                    }
                    .settingsCaption()
                    .accessibilityLabel("Applying system sleep state")
                }
                if let error = operations.errorMessage ?? operations.lastSnapshot?.lastError {
                    Text(error)
                        .settingsCaption()
                        .foregroundStyle(.red)
                }
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
        .disabled(operations.applying)
        .opacity(enabled ? 1 : 0.5)
        .onAppear {
            active = SharedDefaults.store.bool(forKey: LidAwakeState.activeKey)
            operations.refreshStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name(LidAwakeNotifications.changed))
        ) { _ in
            active = SharedDefaults.store.bool(forKey: LidAwakeState.activeKey)
            operations.refreshStatus()
        }
        .alert("Keep running with the lid closed?", isPresented: $confirmingActivation) {
            Button("Turn On") {
                operations.perform(.on(LidAwakeState.session()))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                LidAwakeOperationExecution.preview(for: .on(LidAwakeState.session()))?.warning
                    ?? "")
        }
    }

    private func applySetting(_ request: LidAwakeRequest) {
        guard LidAwakeOperationExecution.applySetting(request) else { return }
        switch request {
        case .setBatteryThreshold(let threshold):
            batteryThreshold = threshold
        case .setRestoreOnQuit(let enabled):
            restoreOnQuit = enabled
        case .status, .on, .off, .enableExtension, .disableExtension:
            break
        }
        NotificationCenter.default.post(
            name: Notification.Name("lidAwakeSettingsChanged"), object: nil)
    }
}
