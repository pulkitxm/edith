import Foundation
import SwiftUI
import Testing

@testable import EdithIcons

private let svgDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("svg")

private func svgLayer(_ source: String, id: String) -> String {
    guard let idRange = source.range(of: "<path id=\"\(id)\"") else { return "" }
    let tail = source[idRange.upperBound...]
    guard let data = tail.range(of: " d=\""),
        let end = tail[data.upperBound...].firstIndex(of: "\"")
    else { return "" }
    return String(tail[data.upperBound..<end])
}

@Suite struct EdithIconTests {
    @Test func everyCaseHasPrimaryDataInBothCuts() {
        for icon in EdithIcon.allCases {
            for cut in EdithIconCut.allCases {
                #expect(!icon.pathData(.primary, cut: cut).isEmpty, "\(icon) \(cut)")
                #expect(
                    !EdithIconPathParser.path(from: icon.pathData(.primary, cut: cut)).isEmpty,
                    "\(icon) \(cut)")
            }
        }
    }

    @Test func generatedDataMatchesSvgSources() throws {
        for icon in EdithIcon.allCases {
            for cut in EdithIconCut.allCases {
                let url = svgDirectory.appendingPathComponent(
                    "\(icon.rawValue).\(Int(cut.grid)).svg")
                let source = try String(contentsOf: url, encoding: .utf8)
                #expect(svgLayer(source, id: "primary") == icon.pathData(.primary, cut: cut))
                #expect(svgLayer(source, id: "secondary") == icon.pathData(.secondary, cut: cut))
            }
        }
    }

    @Test func svgDirectoryHoldsNoUnknownIcons() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: svgDirectory.path)
        let expected = EdithIcon.allCases.flatMap { icon in
            EdithIconCut.allCases.map { "\(icon.rawValue).\(Int($0.grid)).svg" }
        }
        #expect(Set(files) == Set(expected))
    }

    @Test func artworkStaysInsideTheGrid() {
        for icon in EdithIcon.allCases {
            for cut in EdithIconCut.allCases {
                let primary = EdithIconPathParser.path(from: icon.pathData(.primary, cut: cut))
                let secondary = EdithIconPathParser.path(from: icon.pathData(.secondary, cut: cut))
                let bounds = primary.boundingRect.union(
                    secondary.isEmpty ? primary.boundingRect : secondary.boundingRect)
                let grid = CGRect(x: 0, y: 0, width: cut.grid, height: cut.grid)
                #expect(grid.contains(bounds), "\(icon) \(cut) \(bounds)")
            }
        }
    }

    @Test func everySvgHoldsOnlyOutlinedPrimaryAndSecondaryPaths() throws {
        let forbidden = ["<rect", "<circle", "<ellipse", "<mask", "<image", "stroke", "gradient"]
        for file in try FileManager.default.contentsOfDirectory(atPath: svgDirectory.path) {
            let source = try String(
                contentsOf: svgDirectory.appendingPathComponent(file), encoding: .utf8)
            for token in forbidden {
                #expect(!source.contains(token), "\(file) contains \(token)")
            }
        }
    }

    @Test func opticalCutPicksTheGridThatLandsOnWholePixels() {
        #expect(EdithIconCut.optical(for: 16) == .small)
        #expect(EdithIconCut.optical(for: 17.9) == .small)
        #expect(EdithIconCut.optical(for: 18) == .regular)
        #expect(EdithIconCut.optical(for: 20) == .regular)
        #expect(EdithIconCut.optical(for: 24) == .small)
        #expect(EdithIconCut.optical(for: 28) == .regular)
        #expect(EdithIconCut.optical(for: 32) == .small)
        #expect(EdithIconCut.optical(for: 40) == .regular)
        #expect(EdithIconCut.optical(for: 128) == .regular)
    }

    @Test func shapeScalesFromTheGridOrigin() {
        let unit = EdithIconShape(.terminal, cut: .regular).path(
            in: CGRect(x: 0, y: 0, width: 20, height: 20)
        ).boundingRect
        let doubled = EdithIconShape(.terminal, cut: .regular).path(
            in: CGRect(x: 4, y: 4, width: 40, height: 40)
        ).boundingRect
        #expect(abs(doubled.minX - (unit.minX * 2 + 4)) < 0.001)
        #expect(abs(doubled.width - unit.width * 2) < 0.001)
    }

    @Test func extensionIdentifiersResolveToIcons() {
        for id in [
            "appMaintenance", "attention", "audioMixer", "bifrost", "blitztree", "calendar",
            "cleaner", "clipboard", "codeStats", "colorPicker", "companion", "database", "docs",
            "downloads", "emoji", "focusDim", "herdr", "hinge", "homebrew", "jev", "keepAwake",
            "keystrokeHighlight", "latex", "lidAwake", "machines", "micMute", "music", "notchShelf",
            "plugins", "presenter", "quinjet", "seoAudit", "socialManager", "studio", "system",
            "systemStats", "terminal", "timeLapse", "usage", "virtualCamera", "windowSweaters",
        ] {
            #expect(EdithIcon(rawValue: id) != nil, "\(id)")
        }
    }
}
