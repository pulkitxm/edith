import Foundation
import Testing
@testable import EdithKit

@Suite struct EdithButtonStyleTests {
    @Test func visibleBoundsAndHitBoundsAreIdenticalForEveryRole() {
        let label = CGSize(width: 62, height: 14)
        let roles: [EdithButtonRole] = [
            .primary, .secondary, .borderless, .toolbar, .destructive, .row, .iconOnly,
            .selection,
        ]

        for role in roles {
            let metrics = EdithButtonMetrics.metrics(for: role)
            let size = metrics.visibleSize(label: label)
            let points = [
                CGPoint(x: size.width / 2, y: size.height / 2),
                CGPoint(x: 0, y: 0),
                CGPoint(x: size.width, y: 0),
                CGPoint(x: 0, y: size.height),
                CGPoint(x: size.width, y: size.height),
                CGPoint(x: size.width / 2, y: 0),
                CGPoint(x: size.width / 2, y: size.height),
                CGPoint(x: 0, y: size.height / 2),
                CGPoint(x: size.width, y: size.height / 2),
                CGPoint(x: metrics.horizontalPadding + 4, y: size.height / 2),
            ]

            #expect(points.allSatisfy { metrics.contains($0, label: label) })
            #expect(!metrics.contains(CGPoint(x: -0.1, y: size.height / 2), label: label))
            #expect(
                !metrics.contains(CGPoint(x: size.width + 0.1, y: size.height / 2), label: label))
        }
    }

    @Test func featureOwnedRolesPreserveTheirLabelSize() {
        for role in [EdithButtonRole.iconOnly, .toolbar, .borderless] {
            let label = CGSize(width: 10, height: 10)
            let size = EdithButtonMetrics.metrics(for: role).visibleSize(
                label: label)
            #expect(role.usesFeatureAppearance)
            #expect(size == label)
        }
    }

    @Test func chromedRolesKeepTheirMinimumTarget() {
        for role in [
            EdithButtonRole.primary, .secondary, .destructive, .row, .selection,
        ] {
            let size = EdithButtonMetrics.metrics(for: role).visibleSize(
                label: CGSize(width: 10, height: 10))
            #expect(!role.usesFeatureAppearance)
            #expect(size.width >= 32)
            #expect(size.height >= 32)
        }
    }

    @Test func styleKeepsPaddingAndFramingInsideTheContentShape() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/EdithKit/UI/UIPrimitives.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let bodyStart = try #require(source.range(of: "private struct EdithButtonBody"))
        let foregroundStart = try #require(
            source.range(
                of: "private var foreground", range: bodyStart.upperBound..<source.endIndex))
        let body = String(source[bodyStart.lowerBound..<foregroundStart.lowerBound])
        let horizontalPadding = try #require(body.range(of: ".padding(.horizontal"))
        let frame = try #require(
            body.range(of: ".frame(", range: horizontalPadding.upperBound..<body.endIndex))
        let background = try #require(
            body.range(of: ".background(", range: frame.upperBound..<body.endIndex))
        let contentShape = try #require(
            body.range(
                of: ".contentShape(Rectangle())",
                range: background.upperBound..<body.endIndex)
        )

        #expect(horizontalPadding.lowerBound < frame.lowerBound)
        #expect(frame.lowerBound < background.lowerBound)
        #expect(background.lowerBound < contentShape.lowerBound)
        #expect(!body.contains(".pointerCursor()"))
    }
}
