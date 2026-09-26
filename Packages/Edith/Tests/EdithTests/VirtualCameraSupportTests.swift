import CoreMedia
import CoreVideo
import EdithCameraSupport
import EdithCore
import Foundation
import Testing

@Suite struct VirtualCameraSupportTests {
    @Test func extensionIdentityFollowsTheApplicationSlot() {
        #expect(
            VirtualCameraIdentity.extensionIdentifier(forApplication: "com.pulkit.edith")
                == "com.pulkit.edith.camera")
        #expect(
            VirtualCameraIdentity.application(forExtension: "com.pulkit.edith.dev.main.camera")
                == "com.pulkit.edith.dev.main")
        #expect(
            VirtualCameraIdentity.application(forExtension: "com.example.other")
                == "com.example.other")
        #expect(
            VirtualCameraIdentity.deviceName(forApplication: "com.pulkit.edith") == "Edith Camera")
        #expect(
            VirtualCameraIdentity.deviceName(forApplication: "com.pulkit.edith.dev.virtual-camera")
                == "Edith Camera (virtual-camera)")
        #expect(
            VirtualCameraIdentity.deviceName(forApplication: "com.example.app") == "Edith Camera")
    }

    @Test func slotParsingMatchesTheAppIdentity() {
        for identifier in [
            "com.pulkit.edith", "com.pulkit.edith.dev.main", "com.pulkit.edith.dev.xcode",
            "com.pulkit.edith.dev.notch-browser", "com.pulkit.edith.legacy",
        ] {
            #expect(
                VirtualCameraIdentity.slot(ofApplication: identifier)
                    == AppBuildIdentity.slot(of: identifier), "\(identifier)")
        }
    }

    @Test func deviceAndStreamIDsAreStableDistinctAndNameBased() {
        let production = VirtualCameraIdentity.extensionIdentifier(
            forApplication: "com.pulkit.edith")
        let development = VirtualCameraIdentity.extensionIdentifier(
            forApplication: "com.pulkit.edith.dev.main")
        let device = VirtualCameraIdentity.deviceID(forExtension: production)
        #expect(device == VirtualCameraIdentity.deviceID(forExtension: production))
        #expect(device != VirtualCameraIdentity.deviceID(forExtension: development))
        let ids = [
            device, VirtualCameraIdentity.sourceStreamID(forExtension: production),
            VirtualCameraIdentity.sinkStreamID(forExtension: production),
        ]
        #expect(Set(ids).count == 3)
        for id in ids {
            let bytes = id.uuid
            #expect(bytes.6 >> 4 == 5)
            #expect(bytes.8 >> 6 == 2)
        }
        #expect(
            VirtualCameraIdentity.machServiceName(
                teamIdentifier: "TEAM123", extensionIdentifier: production)
                == "TEAM123.com.pulkit.edith.camera")
    }

    @Test func formatsExposeFullAndHalfHD() {
        #expect(VirtualCameraFormat.supported == [.hd1080, .hd720])
        #expect(VirtualCameraFormat.standard == .hd1080)
        #expect(VirtualCameraFormat.format(at: 1) == .hd720)
        #expect(VirtualCameraFormat.format(at: 7) == .standard)
        #expect(VirtualCameraFormat.format(at: -1) == .standard)
        #expect(VirtualCameraFormat.index(of: .hd720) == 1)
        #expect(VirtualCameraFormat.hd1080.frameDurationNanoseconds == 33_333_333)
        #expect(abs(VirtualCameraFormat.hd720.aspectRatio - 16.0 / 9.0) < 0.0001)
        #expect(VirtualCameraFormat.hd1080.label == "1920x1080 at 30 fps")
    }

    @Test func statusRoundTripsThroughTheCustomProperty() throws {
        let status = VirtualCameraExtensionStatus(
            build: "301", clients: ["com.apple.FaceTime", "us.zoom.xos"], format: .hd720,
            receivingFrames: true)
        let text = status.encoded()
        #expect(text.hasPrefix("{\"build\""))
        let decoded = try #require(VirtualCameraExtensionStatus.decode(text))
        #expect(decoded == status)
        #expect(decoded.isInUse)
        #expect(VirtualCameraExtensionStatus.decode("not json") == nil)
        #expect(VirtualCameraExtensionStatus.decode("{}") == nil)
        #expect(VirtualCameraProperty.statusKey == "4cc_edst_glob_0000")
        #expect(VirtualCameraProperty.statusCode == 0x6564_7374)
        #expect(VirtualCameraProperty.fourCharCode("glob") == 0x676C_6F62)
    }

    @Test func relayMovesFromOfflineToLiveAndStalls() {
        var relay = VirtualCameraRelay(stallAfterNanoseconds: 1_000)
        #expect(relay.feed(at: 0) == .offline)
        #expect(!relay.needsPlaceholder(at: 0))
        let client = UUID()
        let added = relay.setConsumers([(id: client, signingID: "us.zoom.xos")])
        let repeated = relay.setConsumers([(id: client, signingID: "us.zoom.xos")])
        #expect(added)
        #expect(!repeated)
        #expect(relay.needsPlaceholder(at: 0))
        relay.sinkStarted()
        #expect(relay.feed(at: 10) == .starting)
        relay.frameArrived(at: 100)
        #expect(relay.feed(at: 500) == .live)
        #expect(relay.isReceivingFrames(at: 500))
        #expect(!relay.needsPlaceholder(at: 500))
        #expect(relay.feed(at: 1_101) == .stalled)
        #expect(relay.needsPlaceholder(at: 1_101))
        relay.sinkStopped()
        #expect(relay.feed(at: 1_200) == .offline)
    }

    @Test func relayNamesConsumersOnceAndSorted() {
        var relay = VirtualCameraRelay()
        relay.setConsumers([
            (id: UUID(), signingID: "us.zoom.xos"), (id: UUID(), signingID: "com.apple.FaceTime"),
            (id: UUID(), signingID: "us.zoom.xos"), (id: UUID(), signingID: nil),
        ])
        #expect(relay.clientNames == ["com.apple.FaceTime", "unknown", "us.zoom.xos"])
        relay.setConsumers([])
        #expect(!relay.hasConsumers)
    }

    @Test func placeholderCardsDescribeEachFeed() {
        #expect(VirtualCameraPlaceholder.card(for: .offline).title == "Edith Camera is off")
        #expect(VirtualCameraPlaceholder.card(for: .starting).title == "Starting your camera")
        #expect(VirtualCameraPlaceholder.card(for: .stalled).title == "Camera paused")
        #expect(VirtualCameraPlaceholder.card(for: .live).title.isEmpty)
    }

    @Test func placeholderDrawsAGlyphAndTextIntoTheBuffer() throws {
        let buffer = try #require(VirtualCameraPlaceholder.makeBuffer(width: 640, height: 360))
        #expect(
            VirtualCameraPlaceholder.render(
                VirtualCameraPlaceholder.card(for: .offline), into: buffer))
        let corner = try pixel(buffer, x: 4, y: 4)
        let glyph = try pixel(buffer, x: 290, y: 150)
        #expect(corner.red < 60 && corner.alpha == 255)
        #expect(glyph.red > 180 && glyph.green > 180 && glyph.blue > 180)
        var rowTotals = 0
        for x in stride(from: 160, to: 480, by: 2) {
            let sample = try pixel(buffer, x: x, y: 209)
            if sample.red > 120 { rowTotals += 1 }
        }
        #expect(rowTotals > 5)
        var other: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil,
            &other)
        let yuv = try #require(other)
        #expect(!VirtualCameraPlaceholder.render(.init(title: "x", detail: "y"), into: yuv))
    }

    @Test func sampleBuffersCarryTimingAndTheImage() throws {
        let buffer = try #require(VirtualCameraPlaceholder.makeBuffer(width: 32, height: 18))
        let time = CMTime(value: 90, timescale: 30)
        let sample = try #require(
            VirtualCameraSampleBuffer.make(
                pixelBuffer: buffer, presentationTime: time, frameRate: 30))
        #expect(sample.presentationTimeStamp == time)
        #expect(sample.duration == CMTime(value: 1, timescale: 30))
        #expect(sample.imageBuffer.map { CVPixelBufferGetWidth($0) } == 32)
        #expect(VirtualCameraSampleBuffer.hostTimeNanoseconds(time) == 3_000_000_000)
        #expect(VirtualCameraSampleBuffer.hostTimeNanoseconds(.invalid) == 0)
        #expect(VirtualCameraSampleBuffer.now().seconds > 0)
    }

    struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> Pixel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
        return Pixel(red: bytes[2], green: bytes[1], blue: bytes[0], alpha: bytes[3])
    }
}
