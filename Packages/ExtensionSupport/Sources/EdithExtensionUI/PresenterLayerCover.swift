import AppKit
import CoreImage
import QuartzCore

@MainActor
public enum PresenterLayerCover {
    nonisolated static let dimName = "edith.presenterCover.dim"
    nonisolated static let blurRadius = 28.0
    nonisolated static let dimOpacity: Float = 0.45

    public static func apply(_ on: Bool, to layer: CALayer, in view: NSView, dark: Bool = true) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let dim = layer.sublayers?.first { $0.name == dimName }
        guard on else {
            layer.filters = nil
            dim?.removeFromSuperlayer()
            return
        }
        view.layerUsesCoreImageFilters = true
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(UIScale.pt(blurRadius), forKey: kCIInputRadiusKey)
        layer.filters = blur.map { [$0] }
        let overlay = dim ?? CALayer()
        overlay.name = dimName
        overlay.backgroundColor = (dark ? NSColor.black : NSColor.white).cgColor
        overlay.opacity = dimOpacity
        overlay.frame = layer.bounds
        overlay.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        overlay.zPosition = .greatestFiniteMagnitude
        if overlay.superlayer == nil { layer.addSublayer(overlay) }
    }

    public static func covers(_ layer: CALayer) -> Bool {
        let blurred = (layer.filters as? [CIFilter])?.contains { $0.name == "CIGaussianBlur" }
        return blurred == true && layer.sublayers?.contains { $0.name == dimName } == true
    }
}
