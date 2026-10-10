import Foundation

struct StudioUIVideoExport: Codable, Sendable {
    let token: UUID
    let destination: URL
    let startedAt: Date
    let format: String
    var progress: Double
    var phase: String
    var failure: String?
    var videoReport: VideoDeliveryReport?
    var audioReport: VideoAudioDeliveryReport?

    mutating func apply(_ state: StudioUIOperationState) {
        guard state.token == token else { return }
        progress = state.progress; phase = state.phase; failure = state.failure
        if let result = state.result, state.phase == "completed" {
            if format == "video" {
                videoReport = try? JSONDecoder().decode(VideoDeliveryReport.self, from: result)
            }
            if format == "audio" {
                audioReport = try? JSONDecoder().decode(VideoAudioDeliveryReport.self, from: result)
            }
        }
    }
}
