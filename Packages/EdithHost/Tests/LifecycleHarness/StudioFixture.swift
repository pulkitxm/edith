import AVFoundation
import CoreGraphics
import CoreText
import EdithExtensionSupport
import EdithHostCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension HostLifecycleHarness {
    @MainActor static func verifyStudio(
        _ endpoint: ExtensionPeerEndpoint, fixture: URL, seed: Bool
    ) async throws {
        let directory = fixture.appendingPathComponent("studio-fixtures", isDirectory: true)
        let image = directory.appendingPathComponent("synthetic-image.png")
        let pdf = directory.appendingPathComponent("synthetic-report.pdf")
        let project = directory.appendingPathComponent("synthetic-video.openscreen")
        let movie = directory.appendingPathComponent("synthetic-video.mp4")
        let frame = directory.appendingPathComponent("synthetic-frame.png")
        func invoke(_ command: String, _ input: [String: Any]) async throws -> Data {
            try await endpoint.invoke(
                command, payload: JSONSerialization.data(withJSONObject: input), timeout: 25)
        }
        if seed {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try studioImage().write(to: image)
            try studioPDF(pdf)
            _ = try await invoke("studio.library.add", ["paths": [image.path, pdf.path]])
            _ = try await invoke(
                "studio.edit.create",
                [
                    "path": project.path, "title": "Synthetic Studio video",
                ])
            _ = try await invoke(
                "studio.edit.apply",
                [
                    "path": project.path, "overwrite": true,
                    "plan": [
                        "version": 1,
                        "operations": [
                            [
                                "addStill": [
                                    "path": image.path, "name": "Synthetic still", "duration": 0.5,
                                ]
                            ]
                        ],
                    ],
                ])
            _ = try await invoke("studio.edit.register", ["path": project.path])
            _ = try await invoke(
                "studio.edit.frame",
                [
                    "path": project.path, "frame": 0, "output": frame.path,
                ])
            _ = try await invoke(
                "studio.edit.render",
                [
                    "path": project.path, "output": movie.path,
                ])
            let asset = AVURLAsset(url: movie)
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty, duration.isFinite, duration > 0, duration <= 1 else {
                throw HostWorkerError.invalidResponse
            }
            let pixels = CGImageSourceCreateWithURL(frame as CFURL, nil)
            guard let pixels, CGImageSourceCreateImageAtIndex(pixels, 0, nil) != nil else {
                throw HostWorkerError.invalidResponse
            }
            let output = directory.appendingPathComponent("processed", isDirectory: true)
            for (tool, source) in [("image.resize", image), ("pdf.to-text", pdf)] {
                let data = try await invoke(
                    "studio.tools.run",
                    [
                        "toolID": tool, "paths": [source.path], "output": output.path,
                    ])
                guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let files = result["outputs"] as? [[String: Any]],
                    let path = files.first?["url"] as? String, let url = URL(string: path),
                    FileManager.default.fileExists(atPath: url.path)
                else { throw HostWorkerError.invalidResponse }
                if tool == "pdf.to-text" {
                    guard
                        try String(contentsOf: url, encoding: .utf8).contains(
                            "Synthetic Studio report")
                    else {
                        throw HostWorkerError.invalidResponse
                    }
                } else {
                    guard let result = CGImageSourceCreateWithURL(url as CFURL, nil),
                        CGImageSourceCreateImageAtIndex(result, 0, nil) != nil
                    else { throw HostWorkerError.invalidResponse }
                }
            }
            try JSONSerialization.data(withJSONObject: [
                "image": try Data(contentsOf: image).base64EncodedString(),
                "pdf": try Data(contentsOf: pdf).base64EncodedString(),
                "project": try Data(contentsOf: project).base64EncodedString(),
            ]).write(to: directory.appendingPathComponent("retained.json"))
        }
        let retained =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("retained.json")))
            as? [String: String]
        guard retained?["image"] == (try Data(contentsOf: image)).base64EncodedString(),
            retained?["pdf"] == (try Data(contentsOf: pdf)).base64EncodedString(),
            retained?["project"] == (try Data(contentsOf: project)).base64EncodedString()
        else { throw HostWorkerError.invalidResponse }
        let library =
            try JSONSerialization.jsonObject(
                with: await invoke("studio.library.list", [:])) as? [[String: Any]]
        guard library?.count == 2,
            Set(
                library?.compactMap {
                    ($0["url"] as? String).flatMap(URL.init(string:))?.lastPathComponent
                } ?? [])
                == Set([image.lastPathComponent, pdf.lastPathComponent])
        else { throw HostWorkerError.invalidResponse }
        let shown =
            try JSONSerialization.jsonObject(
                with: await invoke("studio.edit.show", ["path": project.path])) as? [String: Any]
        guard (shown?["project"] as? [String: Any])?["title"] as? String == "Synthetic Studio video"
        else {
            throw HostWorkerError.invalidResponse
        }
        var tile = SurfaceTile(.ability("studio"))
        tile.itemLimit = 3
        tile.sourceIDs = ["image"]
        tile.contentKinds = ["files"]
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let snapshot = try SurfaceSnapshot.decode(
            await endpoint.invoke(
                "surface.snapshot", payload: request.encoded(providerID: "studio")),
            providerID: "studio")
        guard snapshot.rows.count == 1, snapshot.rows[0].title == image.lastPathComponent,
            snapshot.rows[0].sourceID == "image", snapshot.metrics.first?.value == "1",
            !String(decoding: try snapshot.encoded(), as: UTF8.self).contains(directory.path)
        else { throw HostWorkerError.invalidResponse }
        let action = try snapshot.rows[0].actions.first.unwrapStudioFixture()
        _ = try await endpoint.invoke(
            "surface.perform",
            payload: SurfaceActionRequest(
                snapshot: request, actionID: action.id
            ).encoded(providerID: "studio"))
    }

    private static func studioImage() throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw HostWorkerError.invalidResponse }
        context.setFillColor(CGColor(srgbRed: 0.75, green: 0.25, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        guard let image = context.makeImage() else { throw HostWorkerError.invalidResponse }
        let data = NSMutableData()
        guard
            let output = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { throw HostWorkerError.invalidResponse }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw HostWorkerError.invalidResponse }
        return data as Data
    }

    private static func studioPDF(_ url: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else {
            throw HostWorkerError.invalidResponse
        }
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "Synthetic Studio report",
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                        "Helvetica" as CFString, 24, nil)
                ]))
        context.textPosition = CGPoint(x: 72, y: 680)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }
}

private extension Optional {
    func unwrapStudioFixture() throws -> Wrapped {
        guard let value = self else { throw HostWorkerError.invalidResponse }
        return value
    }
}
