import CoreFoundation
import Foundation
import Testing
@testable import VirtualCameraExtension

struct MeetingAudioPropertyTests {
    @Test func retainedStringIsConsumedAndReleased() {
        weak var released: AnyObject?
        autoreleasepool {
            let object = NSMutableString(string: "Synthetic microphone " + UUID().uuidString)
            released = object
            let result = MeetingAudioDevices.readString { size, output in
                #expect(size == MemoryLayout<Unmanaged<CFString>?>.size)
                output.storeBytes(
                    of: Unmanaged.passRetained(object as CFString),
                    as: Unmanaged<CFString>?.self)
                return 0
            }
            #expect(result == object as String)
        }
        #expect(released == nil)
    }

    @Test func nullErrorAndMalformedSizeDoNotProduceStrings() {
        #expect(MeetingAudioDevices.readString { _, _ in 0 } == nil)
        #expect(MeetingAudioDevices.readString { _, _ in -1 } == nil)
        #expect(MeetingAudioDevices.readString { size, _ in size = 0; return 0 } == nil)
        #expect(MeetingAudioDevices.readString { size, _ in size += 1; return 0 } == nil)
    }
}
