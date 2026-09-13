import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithAgent
@testable import EdithKit

@Suite(.serialized) struct MediaToolkitWorkflowTests {
    @Test func imageConversionRunsThroughTheAgentTaskQueue() async throws {
        let defaults = SharedDefaults.store
        let suiteKey = "suiteMediaEnabled"
        let abilityKey = AppStorageKeys.Tabs.mediaToolkitEnabled
        let suiteBefore = defaults.object(forKey: suiteKey)
        let abilityBefore = defaults.object(forKey: abilityKey)
        defaults.set(true, forKey: suiteKey)
        defaults.set(true, forKey: abilityKey)
        defer {
            defaults.set(suiteBefore, forKey: suiteKey)
            defaults.set(abilityBefore, forKey: abilityKey)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("sample.png")
        let context = try #require(
            CGContext(
                data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                input as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let service = try AgentTaskService(directory: nil)
        await MediaToolkitWorkflow.register(on: service)
        let payload = MediaImageTaskRequest(
            inputs: [input], destination: root.appendingPathComponent("output"),
            options: MediaImageOptions(format: .jpeg, maxDimension: 40))
        let request = AgentTaskSubmission(
            operation: MediaToolkitOperation.convertImages.descriptor.id.rawValue,
            title: "Convert sample image", payload: try AgentPayload.encode(payload))
        _ = try await service.submit(request)
        var status = try await service.status(request.id)
        for _ in 0..<250 where !status.snapshot.state.isTerminal {
            try await Task.sleep(for: .milliseconds(20))
            status = try await service.status(request.id)
        }
        #expect(status.snapshot.state == .succeeded)
        let result = try AgentPayload.decode([MediaImageResult].self, from: #require(status.result))
        let output = try #require(result.first?.outputURL)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 40)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 20)
        #expect(FileManager.default.fileExists(atPath: input.path))
        await service.shutdown()
    }
}
