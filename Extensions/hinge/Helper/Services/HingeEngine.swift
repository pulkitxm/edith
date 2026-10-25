#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import EdithExtensionSupport
import Foundation

@MainActor
final class HingeEngine: FeatureModule {
    private let fixture: WorkerFixtureAdmission?
    private var desktop: LiveDesktop?
    private var stopped = false

    var systemResourceCount: Int { desktop == nil ? 0 : 1 }

    convenience init() { self.init(fixture: nil) }

    init(fixture: WorkerFixtureAdmission?) {
        precondition(fixture == nil || fixture?.extensionID == "hinge")
        self.fixture = fixture
        guard fixture == nil else { return }
        let desktop = LiveDesktop()
        self.desktop = desktop
        installHotKey()
        desktop.reloadPreferences()
        if HingeState.isActive() {
            desktop.setEnabled(true)
        }
    }

    func cancelPendingWork() {
        guard !stopped else { return }
        stopped = true
        guard fixture == nil else { return }
        HotKeyRegistrar.clear(HotKeyCatalog.hinge)
    }

    func shutdown() {
        cancelPendingWork()
        desktop?.shutDown()
        desktop = nil
    }

    func drain() async {
        cancelPendingWork()
    }

    func calibrate() {
        desktop?.setOpenPosition()
    }

    func applySettings() {
        guard !stopped, let desktop else { return }
        installHotKey()
        desktop.reloadPreferences()
        let active = HingeState.isActive()
        if active != desktop.isEnabled {
            desktop.setEnabled(active)
        }
    }

    private func installHotKey() {
        HotKeyRegistrar.install(HotKeyCatalog.hinge) {
            HingeState.setActive(!HingeState.isActive())
            IPC.post(IPC.Name.settingsChanged)
        }
    }
}
