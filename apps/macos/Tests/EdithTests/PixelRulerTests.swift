import Testing

@testable import EdithKit
@testable import EdithMenuBar

@Suite struct PixelEdgeWalkerTests {
    @Test func walksRightToTheFirstEdgeBeyondTolerance() {
        let row: [Double] = [10, 10, 10, 90, 90]
        let edge = PixelEdgeWalker.walk(from: 1, step: 1, tolerance: 20) { index in
            row.indices.contains(index) ? row[index] : nil
        }
        #expect(edge == 3)
    }

    @Test func walksLeftToTheFirstEdgeBeyondTolerance() {
        let row: [Double] = [90, 90, 10, 10, 10]
        let edge = PixelEdgeWalker.walk(from: 3, step: -1, tolerance: 20) { index in
            row.indices.contains(index) ? row[index] : nil
        }
        #expect(edge == 1)
    }

    @Test func returnsNilWhenItRunsOffTheBufferWithoutFindingAnEdge() {
        let row: [Double] = [10, 11, 10, 11, 10]
        let edge = PixelEdgeWalker.walk(from: 2, step: 1, tolerance: 50) { index in
            row.indices.contains(index) ? row[index] : nil
        }
        #expect(edge == nil)
    }

    @Test func returnsNilWhenTheStartingIndexHasNoSample() {
        let edge = PixelEdgeWalker.walk(from: 0, step: 1, tolerance: 10) { _ in nil }
        #expect(edge == nil)
    }

    @Test func toleranceBoundaryCountsAsAnEdge() {
        let row: [Double] = [50, 80]
        let edge = PixelEdgeWalker.walk(from: 0, step: 1, tolerance: 30) { index in
            row.indices.contains(index) ? row[index] : nil
        }
        #expect(edge == 1)
    }

    @Test func luminanceWeightsGreenMost() {
        let white = PixelEdgeWalker.luminance(r: 255, g: 255, b: 255)
        let green = PixelEdgeWalker.luminance(r: 0, g: 255, b: 0)
        let blue = PixelEdgeWalker.luminance(r: 0, g: 0, b: 255)
        #expect(abs(white - 255) < 0.01)
        #expect(green > blue)
    }
}

@Suite struct PixelGeometryTests {
    @Test func passesPixelsThroughUnchanged() {
        #expect(PixelGeometry.measurement(devicePixels: 240, scale: 2, unit: .pixels) == 240)
    }

    @Test func convertsDevicePixelsToPointsUsingScaleFactor() {
        #expect(PixelGeometry.measurement(devicePixels: 240, scale: 2, unit: .points) == 120)
    }

    @Test func roundsFractionalPointConversions() {
        #expect(PixelGeometry.measurement(devicePixels: 241, scale: 2, unit: .points) == 121)
    }

    @Test func convertsPointsToDevicePixelsUsingScaleFactor() {
        #expect(PixelGeometry.devicePixels(forPoints: 120, scale: 2) == 240)
    }

    @Test func mixedDPIScalesIndependently() {
        #expect(PixelGeometry.measurement(devicePixels: 300, scale: 1, unit: .points) == 300)
        #expect(PixelGeometry.measurement(devicePixels: 300, scale: 1.5, unit: .points) == 200)
    }
}

@Suite struct PixelRulerCaptureHintTests {
    @Test func noHintWhenTheScreenWasCaptured() {
        #expect(PixelRulerCaptureHint.hint(granted: true, hasCapture: true) == nil)
    }

    @Test func deniedHintExplainsTheMissingPermission() {
        let hint = PixelRulerCaptureHint.hint(granted: false, hasCapture: false)
        #expect(hint?.contains("Screen Recording is off") == true)
        #expect(hint?.contains("relaunch") == true)
    }

    @Test func failedHintSuggestsReopeningOrRetoggling() {
        let hint = PixelRulerCaptureHint.hint(granted: true, hasCapture: false)
        #expect(hint?.contains("Screen capture failed") == true)
        #expect(hint?.contains("reopen") == true)
    }

    @Test func deniedAndFailedHintsDiffer() {
        let denied = PixelRulerCaptureHint.hint(granted: false, hasCapture: false)
        let failed = PixelRulerCaptureHint.hint(granted: true, hasCapture: false)
        #expect(denied != failed)
    }
}

@Suite struct PixelRulerCopyFormatTests {
    @Test func formatsWithMultiplicationSign() {
        #expect(PixelRulerCopyFormat.times.string(width: 120, height: 48) == "120 × 48")
    }

    @Test func formatsWithLowercaseX() {
        #expect(PixelRulerCopyFormat.x.string(width: 120, height: 48) == "120x48")
    }
}
