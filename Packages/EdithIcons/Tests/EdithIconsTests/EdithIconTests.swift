import AppKit
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

@Suite(.serialized) struct EdithIconTests {
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
                let primary = EdithIconPathStore.path(icon, layer: .primary, cut: cut)
                let secondary = EdithIconPathStore.path(icon, layer: .secondary, cut: cut)
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

    @Test func namesResolveWithAliasesAndASafeFallback() {
        #expect(EdithIcon(name: "plus") == .plus)
        #expect(EdithIcon(name: "gear") == .permissionAutomation)
        #expect(EdithIcon.gear == .permissionAutomation)
        #expect(EdithIcon(name: "no.such.icon") == .placeholder)
        #expect(EdithIcon.named("no.such.icon") == nil)
        #expect(EdithIcon.isValid(name: "herdr"))
        #expect(!EdithIcon.isValid(name: "arrow.clockwise"))
        for icon in EdithIcon.allCases {
            #expect(EdithIcon.isValid(name: icon.rawValue))
        }
    }

    @Test func namesFileListsEveryIconAndAlias() throws {
        let url = svgDirectory.deletingLastPathComponent().appendingPathComponent("names.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let icons = json?["icons"] as? [String] ?? []
        let aliases = json?["aliases"] as? [String: String] ?? [:]
        #expect(Set(icons) == Set(EdithIcon.allCases.map(\.rawValue)))
        #expect(Set(icons).union(aliases.keys) == Set(EdithIcon.names))
    }

    @Test func symbolMapResolvesEverySymbolToARealIcon() throws {
        let url = svgDirectory.deletingLastPathComponent().appendingPathComponent("symbol-map.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let symbols = json?["symbols"] as? [String: String] ?? [:]
        #expect(symbols.count > 500)
        for (symbol, icon) in symbols {
            #expect(EdithIcon.isValid(name: icon), "\(symbol) -> \(icon)")
        }
        for override in json?["overrides"] as? [[String: String]] ?? [] {
            #expect(EdithIcon.isValid(name: override["icon"] ?? ""), "\(override)")
        }
    }

    @Test func textSizesLandOnPixelExactIcons() {
        #expect(EdithIconText.iconSize(forLineHeight: 13) == 12)
        #expect(EdithIconText.iconSize(forLineHeight: 16) == 16)
        #expect(EdithIconText.iconSize(forLineHeight: 21) == 20)
        #expect(EdithIconText.iconSize(forLineHeight: 24) == 24)
        #expect(EdithIconText.iconSize(forLineHeight: 31) == 32)
        #expect(EdithIconText.iconSize(forLineHeight: 72) == 72)
        #expect(EdithIconText.iconSize(forLineHeight: 16, scale: .small) == 12)
        #expect(EdithIconText.iconSize(forLineHeight: 16, scale: .large) == 20)
    }

    @Test func templateImagesCarryBothScales() {
        let image = EdithIcon.plus.nsImage(size: 16)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 16, height: 16))
        let widths = image.representations.map(\.pixelsWide).sorted()
        #expect(widths == [16, 32])
    }

    @Test func templateImagesKeepTwoToneAsAlpha() throws {
        let image = EdithIcon.usage.nsImage(size: 40)
        let bitmap = try #require(
            image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        let color = { (x: Int, y: Int) in bitmap.colorAt(x: x, y: y)?.alphaComponent ?? -1 }
        #expect(abs(color(10, 10) - 0.45) < 0.02)
        #expect(abs(color(10, 30) - 1) < 0.02)
    }

    @Test func parsedPathsAreSharedAcrossAThousandRows() {
        let icons = Array(EdithIcon.allCases.prefix(50))
        for icon in icons { _ = EdithIconShape(icon, cut: .small).path(in: .zero) }
        let parsed = EdithIconPathStore.parseCount
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for row in 0..<1000 {
                _ = EdithIconShape(icons[row % icons.count], cut: .small).path(in: rect)
            }
        }
        #expect(EdithIconPathStore.parseCount == parsed)
        #expect(elapsed < .milliseconds(50), "\(elapsed)")
    }

    @Test func renderedImagesAreCached() {
        let first = EdithIcon.trash.nsImage(size: 17)
        let clock = ContinuousClock()
        var last = first
        let elapsed = clock.measure {
            for _ in 0..<1000 { last = EdithIcon.trash.nsImage(size: 17) }
        }
        #expect(first === last)
        #expect(elapsed < .milliseconds(50), "\(elapsed)")
    }

    @Test func cachesAreSafeUnderConcurrentAccess() {
        let icons = EdithIcon.allCases
        DispatchQueue.concurrentPerform(iterations: 2000) { index in
            let icon = icons[index % icons.count]
            _ = EdithIconShape(icon, cut: index.isMultiple(of: 2) ? .small : .regular)
                .path(in: CGRect(x: 0, y: 0, width: 20, height: 20))
            _ = icon.nsImage(size: index.isMultiple(of: 3) ? 16 : 20)
        }
        #expect(EdithIcon.allCases.count == icons.count)
    }

    @available(macOS 14.4, *)
    @MainActor @Test func labelsKeepTheirIconInsideNativeMenus() {
        let menu = NSHostingMenu(
            rootView: Group {
                Button("Rename", edith: .edit) {}
                Button {
                } label: {
                    Label("Delete", edith: .trash)
                }
            })
        menu.update()
        #expect(menu.items.count == 2)
        #expect(menu.items.first?.title == "Rename")
        #expect(menu.items.allSatisfy { $0.image != nil })
    }

    @Test func codableCarriesTheNameAndAnUnknownNameBecomesThePlaceholder() throws {
        let encoded = try JSONEncoder().encode([EdithIcon.terminal])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["terminal"]"#)
        let decoded = try JSONDecoder().decode(
            [EdithIcon].self, from: Data(#"["terminal","gear","gearshape.fill"]"#.utf8))
        #expect(decoded == [.terminal, .gear, .placeholder])
    }

    @MainActor @Test func callSitesCompileAcrossEverySymbolShape() {
        let title = "Dynamic"
        _ = Label("Literal", edith: .plus)
        _ = Label(title, edith: .plus, tone: .muted)
        _ = Button("Literal", edith: .plus) {}
        _ = Button(title, edith: .trash, role: .destructive) {}
        _ = Text("\(Text(edith: .warning).foregroundColor(.orange)) \(title)")
        _ = EdithIconView(.check).font(.caption).foregroundStyle(.tint)
        _ = EdithIcon.close.image()
    }
}
