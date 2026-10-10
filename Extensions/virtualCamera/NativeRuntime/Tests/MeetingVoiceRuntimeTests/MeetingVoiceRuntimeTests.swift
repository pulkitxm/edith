import Foundation
import MeetingVoiceRuntime
import Testing

@Suite(.serialized) struct MeetingVoiceRuntimeTests {
    private func session() throws -> UnsafeMutableRawPointer {
        let root = try #require(Bundle.module.resourceURL?.appendingPathComponent("Fixtures"))
        var error = [CChar](repeating: 0, count: 256)
        let session = root.appendingPathComponent("encoder.onnx").path.withCString { encoder in
            root.appendingPathComponent("voice.onnx").path.withCString { voice in
                MeetingVoiceCreate(encoder, voice, &error, error.count)
            }
        }
        return try #require(
            session, "Synthetic voice fixtures did not create a native inference session")
    }

    @Test func actualNativeInferenceRunsSyntheticModelsAndClampsAudio() throws {
        let handle = try session()
        defer { MeetingVoiceDestroy(handle) }
        let audio = [Float](repeating: 0.1, count: 800)
        var output = [Float](repeating: 99, count: 1280)
        var error = [CChar](repeating: 0, count: 256)
        var rate: Int32 = 0
        let count = audio.withUnsafeBufferPointer { audio in
            MeetingVoiceConvert(
                handle, audio.baseAddress, audio.count, 0, &output, output.count, &rate, &error,
                error.count)
        }
        #expect(count == 1280)
        #expect(rate == 32000)
        #expect(output[0...3] == [-1, 0.25, 1, 0])
        #expect(output.allSatisfy { $0.isFinite && (-1...1).contains($0) })
    }

    @Test func invalidModelsAndErrorBuffersStayBounded() {
        var error = [CChar](repeating: 42, count: 4)
        #expect(MeetingVoiceCreate(nil, nil, &error, error.count) == nil)
        #expect(error[3] == 0)
        #expect(MeetingVoiceCreate(nil, nil, nil, 0) == nil)
        MeetingVoiceDestroy(nil)
    }

    @Test func malformedBlocksAndInsufficientOutputCannotWriteSamples() throws {
        let handle = try session()
        defer { MeetingVoiceDestroy(handle) }
        var audio = [Float](repeating: 0.1, count: 800)
        var output = [Float](repeating: 99, count: 100)
        var error = [CChar](repeating: 0, count: 256)
        var rate: Int32 = 0
        for transpose in [Float(0), Float.nan, Float.infinity] {
            let count = audio.withUnsafeBufferPointer { audio in
                MeetingVoiceConvert(
                    handle, audio.baseAddress, audio.count, transpose, &output, output.count, &rate,
                    &error, error.count)
            }
            #expect(count == -1)
            #expect(output.allSatisfy { $0 == 99 })
        }
        audio[2] = .nan
        let count = audio.withUnsafeBufferPointer { audio in
            MeetingVoiceConvert(
                handle, audio.baseAddress, audio.count, 0, &output, output.count, &rate, &error,
                error.count)
        }
        #expect(count == -1)
        #expect(output.allSatisfy { $0 == 99 })
    }
}
