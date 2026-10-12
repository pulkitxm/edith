import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
import Vision

@MainActor
func auditHost(_ view: some View, size: CGSize) throws -> NSHostingView<AnyView> {
    _ = TestWindowHost.application
    let host = NSHostingView(
        rootView: AnyView(
            view
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.windowVisible, false)
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil }
                .frame(width: size.width, height: size.height)
                .background(DashSkin.paper(true))))
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    host.layoutSubtreeIfNeeded()
    #expect(TestWindowHost.exposedWindows.isEmpty)
    return host
}

@MainActor
func auditText(_ host: NSHostingView<AnyView>) throws -> String {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let image = try #require(bitmap.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
        separator: "\n")
}
