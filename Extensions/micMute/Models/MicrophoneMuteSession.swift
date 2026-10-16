import Foundation

struct MicrophoneControl: Hashable {
    enum Kind { case mute, volume }
    let device: UInt32
    let element: UInt32
    let kind: Kind
    var mutedValue: Float { kind == .mute ? 1 : 0 }
}

struct MicrophoneAccess {
    var controls: () -> [MicrophoneControl]
    var read: (MicrophoneControl) -> Float?
    var write: (MicrophoneControl, Float) -> Bool
}

@MainActor
final class MicrophoneMuteSession {
    private let access: MicrophoneAccess
    private(set) var saved: [MicrophoneControl: Float] = [:]

    init(access: MicrophoneAccess) { self.access = access }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        var success = true
        for control in access.controls() {
            if control.kind == .mute {
                if !access.write(control, muted ? 1 : 0) { success = false }
            } else if muted {
                guard let original = saved[control] ?? access.read(control) else {
                    success = false
                    continue
                }
                if access.write(control, 0) {
                    saved[control] = original
                } else {
                    success = false
                }
            }
        }
        if !muted {
            for (control, value) in saved where control.kind == .volume {
                if access.write(control, value) {
                    saved[control] = nil
                } else {
                    success = false
                }
            }
        }
        return success
    }
}
