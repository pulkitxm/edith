import Foundation

extension VideoEditorModel {
    func setFrameSampling(_ mode: VideoFrameSampling, clipID: String) async throws {
        guard let snapshot = project, selectedClipID == clipID else {
            throw VideoEditorService.Failure(
                "invalid_frame_sampling", "Select a video clip before changing frame sampling.")
        }
        let pendingID = "frame-sampling-\(UUID().uuidString)"
        setPendingViewEdit(pendingID, hasChanges: true)
        defer { setPendingViewEdit(pendingID, hasChanges: false) }
        var candidate = snapshot
        try candidate.setFrameSampling(mode, clipID: clipID)
        if mode == .nearest {
            if let facade {
                let resource = try await facade.upload(StudioUIVideoProject(candidate))
                let _: [String: String] = try await facade.perform(
                    "studio.ui.media.frameSampling",
                    object: ["project": try facade.object(resource)])
            } else {
                try await candidate.validateFrameSampling()
            }
        }
        try Task.checkCancellation()
        guard let current = project, current.id == snapshot.id,
            current.fileURL == snapshot.fileURL, selectedClipID == clipID,
            NSDictionary(dictionary: current.root).isEqual(to: snapshot.root)
        else {
            throw VideoEditorService.Failure(
                "project_changed",
                "The project or selection changed while checking frame sampling. Retry the change.")
        }
        errorMessage = nil
        mutate { $0 = candidate }
        rebuild()
    }
}
