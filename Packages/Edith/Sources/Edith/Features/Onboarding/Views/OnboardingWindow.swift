import AppKit
import EdithKit
import SwiftUI

@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?

    static func open() {
        if let window {
            WindowPresentation.present(window)
            return
        }
        let onboardingWindow = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: PresentationMetrics.width(620),
                height: PresentationMetrics.height(560)),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        onboardingWindow.title = "Welcome to Edith"
        onboardingWindow.titleVisibility = .hidden
        onboardingWindow.titlebarAppearsTransparent = true
        onboardingWindow.titlebarSeparatorStyle = .none
        onboardingWindow.isMovableByWindowBackground = true
        onboardingWindow.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: OnboardingView(onFinish: close))
        hosting.sizingOptions = []
        onboardingWindow.contentViewController = hosting
        onboardingWindow.setContentSize(
            NSSize(width: PresentationMetrics.width(620), height: PresentationMetrics.height(560)))
        onboardingWindow.center()
        onboardingWindow.delegate = OnboardingWindowDelegate.shared
        window = onboardingWindow
        WindowPresentation.present(onboardingWindow)
    }

    static func close() {
        guard let window else {
            OnboardingFlow.skip()
            MainWindow.open()
            return
        }
        window.performClose(nil)
    }

    fileprivate static func forget() {
        window = nil
    }
}

@MainActor
private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        OnboardingFlow.skip()
        OnboardingWindow.forget()
        MainWindow.open()
    }
}
