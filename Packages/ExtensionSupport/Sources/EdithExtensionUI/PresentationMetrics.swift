import AppKit

@MainActor
public enum PresentationMetrics {
    private static var visibleFrame: CGRect {
        NSApp.keyWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_024, height: 768)
    }

    public static func width(_ preferred: Double) -> Double {
        min(UIScale.pt(preferred), max(1, visibleFrame.width - 96))
    }

    public static func height(_ preferred: Double) -> Double {
        min(UIScale.pt(preferred), max(1, visibleFrame.height - 96))
    }
}
