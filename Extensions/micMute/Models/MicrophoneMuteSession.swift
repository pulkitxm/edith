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
        if muted {
            for control in access.controls() {
                guard let original = saved[control] ?? access.read(control) else {
                    success = false
                    continue
                }
                if access.write(control, control.mutedValue) {
                    saved[control] = original
                } else {
                    success = false
                }
            }
        } else {
            for (control, value) in saved {
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
