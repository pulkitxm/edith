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
        #expect(
            MeetingAudioDevices.readString { size, _ in
                size = 0; return 0
            } == nil)
        #expect(
            MeetingAudioDevices.readString { size, _ in
                size += 1; return 0
            } == nil)
    }

    @Test func malformedSuccessfulRetainedOutputsAreReleasedExactlyOnce() {
        let expectedSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        for returnedSize in [0, expectedSize - 1, expectedSize + 1, UInt32.max] {
            weak var released: AnyObject?
            autoreleasepool {
                let object = NSMutableString(string: "Synthetic microphone " + UUID().uuidString)
                released = object
                let retained = Unmanaged.passRetained(object as CFString)
                let result = MeetingAudioDevices.readString { size, output in
                    #expect(size == expectedSize)
                    output.storeBytes(of: retained, as: Unmanaged<CFString>?.self)
                    size = returnedSize
                    return 0
                }
                #expect(result == nil)
                #expect(object.length > 0)
            }
            #expect(released == nil)
        }
    }

    @Test func failedGetterDoesNotConsumeUnspecifiedOutputOwnership() {
        let expectedSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        for returnedSize in [0, expectedSize, expectedSize + 1] {
            weak var released: AnyObject?
            var retained: Unmanaged<CFString>?
            autoreleasepool {
                let object = NSMutableString(string: "Synthetic failed output " + UUID().uuidString)
                released = object
                retained = Unmanaged.passRetained(object as CFString)
                let result = MeetingAudioDevices.readString { size, output in
                    output.storeBytes(of: retained, as: Unmanaged<CFString>?.self)
                    size = returnedSize
                    return -1
                }
                #expect(result == nil)
            }
            #expect(released != nil)
            retained?.release()
            #expect(released == nil)
        }
    }
}
