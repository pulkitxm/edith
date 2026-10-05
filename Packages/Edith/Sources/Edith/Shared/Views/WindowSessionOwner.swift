import SwiftUI

@MainActor
final class WindowSessionOwner: ObservableObject {
    let acceptsCommandVideo: Bool
    private var storedStudio: StudioModel?
    private var storedQuinjet: QuinjetPageModel?
    private var storedCapture: CompanionCaptureModel?

    init(acceptsCommandVideo: Bool = true) {
        self.acceptsCommandVideo = acceptsCommandVideo
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

    deinit {
        if let model = storedStudio { Task { @MainActor in model.closeEditors() } }
        if let model = storedQuinjet { Task { @MainActor in model.stopAll() } }
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
