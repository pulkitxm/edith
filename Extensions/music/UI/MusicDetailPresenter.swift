import AppKit
import Combine
import EdithExtensionUI
import EdithExtensionSupport
import Observation
import SwiftUI

@MainActor
@Observable
final class EmbeddedMusicDetailPresenter {
    static let shared = EmbeddedMusicDetailPresenter()

    private(set) var track: EmbeddedTrack?
    private(set) var beginRename = false
    private(set) var renameArmed = false
    private(set) var followsPlayback = false

    func show(_ track: EmbeddedTrack, renaming: Bool = false) {
        beginRename = renaming
        renameArmed = false
        followsPlayback = EmbeddedMusicRemote.shared.currentFile == track.relativePath
        self.track = track
    }

    func armRename(_ value: Bool) {
        if renameArmed != value { renameArmed = value }
    }

    func followPlayback(_ track: EmbeddedTrack) {
        guard self.track == track else { return }
        followsPlayback = true
    }

    func followCurrent() {
        guard followsPlayback, track != nil, let current = EmbeddedMusicRemote.shared.current,
            current != track
        else { return }
        beginRename = false
        renameArmed = false
        track = current
    }

    func dismiss() {
        track = nil
        beginRename = false
        renameArmed = false
        followsPlayback = false
    }
}
