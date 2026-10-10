#if EDITH_GUI_FIXTURE
import EdithExtensionSupport
import EdithHostCore
import ExtensionMarketplace
import Foundation
import SwiftUI

@MainActor
final class HostGUIJourneyServices {
    let marketplace: HostMarketplace
    let workflowModel: HostWorkflowOnboardingModel
    var online: Bool { false }
    var activityLabel: String { "Offline" }

    init(
        identity: HostIdentity, marketplace: HostMarketplace,
        togglePanel: @escaping @MainActor () -> Void
    ) throws {
        guard HostGUIFixture.fixture?.identifier == identity.identifier,
            marketplace.identity.identifier == identity.identifier
        else { throw JourneyContractError.invalidIdentity }
        self.marketplace = marketplace
        let defaults = marketplace.surfaces.preferences
        workflowModel = HostWorkflowOnboardingModel(
            entries: marketplace.entries, defaults: defaults,
            environment: HostWorkflowEnvironment(
                available: { [weak marketplace] in marketplace?.available ?? [:] },
                installed: { [weak marketplace] in
                    Set(marketplace?.installed.keys ?? Dictionary<String, ExtensionPackage>().keys)
                },
                active: { [weak marketplace] in marketplace?.sessions.activeIDs ?? [] },
                refresh: { [weak marketplace] in
                    guard let marketplace, marketplace.operationID == nil else {
                        throw HostWorkerError.rejected
                    }
                    await marketplace.checkForUpdates()
                    try Task.checkCancellation()
                    if let error = marketplace.error { throw HostWorkflowFailure(error) }
                },
                install: { [weak marketplace] id, expected in
                    guard let marketplace, marketplace.operationID == nil, id == "calendar" else {
                        throw HostWorkerError.rejected
                    }
                    if marketplace.installed[id] == nil {
                        await marketplace.download(id: id, expectedPackage: expected)
                        try Task.checkCancellation()
                        if let error = marketplace.error { throw HostWorkflowFailure(error) }
                    }
                    guard marketplace.installed[id] != nil else { throw HostWorkerError.rejected }
                    await marketplace.enable(id: id)
                    try Task.checkCancellation()
                    if let error = marketplace.error { throw HostWorkflowFailure(error) }
                    guard marketplace.sessions.activeIDs.contains(id) else {
                        throw HostWorkerError.rejected
                    }
                },
                restore: {
                    throw HostWorkflowFailure(
                        "Cloud restore is unavailable in the isolated hosted fixture.")
                },
                changed: { defaults.synchronize() }))
    }

    func start() async {
        if workflowModel.incomplete,
            marketplace.downloadedIDs.isEmpty
                || marketplace.surfaces.preferences.bool(
                    forKey: HostWorkflowOnboardingModel.reviewPendingKey)
        {
            workflowModel.present()
        }
    }

    func settings(_ category: String, presenter: (any HostExtensionContentPresenting)?) -> AnyView?
    {
        guard category == "home-setup" else { return nil }
        return workflowModel.presented
            || (workflowModel.incomplete && marketplace.downloadedIDs.isEmpty)
            ? AnyView(
                HostWorkflowOnboardingView(
                    model: workflowModel, progress: { [marketplace] in marketplace.progress }))
            : nil
    }

    func showWelcome() {
        workflowModel.present()
        marketplace.surfaces.preferences.set(
            "home", forKey: AppStorageKeys.General.mainWindowSection)
    }

    func panelShortcutChanged() {}

    func shutdown() async {
        await workflowModel.shutdown()
        await HostGUIFixture.stop()
    }
}
#endif
