import SwiftUI

@MainActor
final class WindowSessionOwner: ObservableObject {
    let acceptsCommandVideo: Bool
    let scrollPositions = PageScrollPositions()
    private var storedAttention: AttentionPageModel?
    private var storedCodeStats: CodeStatsModel?
    private var storedLaTeX: LaTeXModel?
    private var storedStudio: StudioModel?
    private var storedQuinjet: QuinjetPageModel?
    private var storedCapture: CompanionCaptureModel?
    private var storedCompanion: CompanionWorkspaceSession?
    private var storedDatabase: DatabasePageSession?
    private var storedMaintenance: AppMaintenanceModel?
    private var storedHomebrew: HomebrewPageModel?
    private var storedBlitzTree: BlitzTreeModel?
    private var storedProcesses: [UUID: MachineProcessListModel] = [:]

    init(acceptsCommandVideo: Bool = true) {
        self.acceptsCommandVideo = acceptsCommandVideo
    }

    var attention: AttentionPageModel {
        if let storedAttention { return storedAttention }
        let model = AttentionPageModel()
        storedAttention = model
        return model
    }

    var codeStats: CodeStatsModel {
        if let storedCodeStats { return storedCodeStats }
        let model = CodeStatsModel()
        storedCodeStats = model
        return model
    }

    var latex: LaTeXModel {
        if let storedLaTeX { return storedLaTeX }
        let model = LaTeXModel()
        storedLaTeX = model
        return model
    }

    var studio: StudioModel {
        if let storedStudio { return storedStudio }
        let model = StudioModel()
        storedStudio = model
        return model
    }

    var quinjet: QuinjetPageModel {
        if let storedQuinjet { return storedQuinjet }
        let model = QuinjetPageModel()
        storedQuinjet = model
        return model
    }

    var capture: CompanionCaptureModel {
        if let storedCapture { return storedCapture }
        let model = CompanionCaptureModel()
        storedCapture = model
        return model
    }

    var companion: CompanionWorkspaceSession {
        if let storedCompanion { return storedCompanion }
        let session = CompanionWorkspaceSession()
        storedCompanion = session
        return session
    }

    var database: DatabasePageSession {
        if let storedDatabase { return storedDatabase }
        let session = DatabasePageSession()
        storedDatabase = session
        return session
    }

    var maintenance: AppMaintenanceModel {
        if let storedMaintenance { return storedMaintenance }
        let model = AppMaintenanceModel()
        storedMaintenance = model
        return model
    }

    var homebrew: HomebrewPageModel {
        if let storedHomebrew { return storedHomebrew }
        let model = HomebrewPageModel()
        storedHomebrew = model
        return model
    }

    var blitzTree: BlitzTreeModel {
        if let storedBlitzTree { return storedBlitzTree }
        let model = BlitzTreeModel()
        storedBlitzTree = model
        return model
    }

    func processes(for machineID: UUID) -> MachineProcessListModel {
        if let model = storedProcesses[machineID] { return model }
        let model = MachineProcessListModel()
        storedProcesses[machineID] = model
        return model
    }

    deinit {
        for model in storedProcesses.values { Task { @MainActor in model.loading.cancel() } }
        if let model = storedAttention { Task { @MainActor in model.cancelLoading() } }
        if let model = storedCodeStats { Task { @MainActor in model.cancelLoading() } }
        if let model = storedStudio { Task { @MainActor in model.closeEditors() } }
        if let model = storedQuinjet { Task { @MainActor in model.stopAll() } }
        if let model = storedMaintenance { Task { @MainActor in model.cancel() } }
        if let model = storedHomebrew { Task { @MainActor in model.cancel() } }
        if let model = storedBlitzTree { Task { @MainActor in model.cancel() } }
    }
}

private struct WindowSessionOwnerKey: EnvironmentKey {
    static let defaultValue: WindowSessionOwner? = nil
}

extension EnvironmentValues {
    var windowSessionOwner: WindowSessionOwner? {
        get { self[WindowSessionOwnerKey.self] }
        set { self[WindowSessionOwnerKey.self] = newValue }
    }
}
