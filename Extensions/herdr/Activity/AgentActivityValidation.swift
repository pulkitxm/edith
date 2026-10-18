import EdithExtensionSupport
import Foundation

extension AgentActivityEvent {
    var isValid: Bool {
        let values = [
            sessionID, parentSessionID, eventName, project, model, tool, detail, pane,
            permissionID, permissionInput,
        ].compactMap { $0 }
        return !sessionID.isEmpty && sessionID.utf8.count <= 4096
            && eventName.utf8.count <= 256 && receivedAt.timeIntervalSince1970.isFinite
            && values.allSatisfy { !$0.contains("\u{0}") && $0.utf8.count <= 131_072 }
            && ((try? AgentPayload.encode(self).count) ?? Int.max) <= 131_072
            && (!permissionRequest || (phase == .permission && tool != nil))
    }
}
