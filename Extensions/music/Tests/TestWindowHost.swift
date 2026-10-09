import EdithExtensionSupport
import AppKit

@MainActor
enum TestWindowHost {
    static var application: NSApplication { NSApplication.shared }
}

import Testing

@Suite(.serialized) struct MusicExtensionTests {}
