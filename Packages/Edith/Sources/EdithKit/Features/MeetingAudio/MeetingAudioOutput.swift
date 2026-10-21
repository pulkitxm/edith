@preconcurrency import AVFoundation
import AudioToolbox

final class MeetingAudioOutput {
    static let maximumFrameCount: AVAudioFrameCount = 4096

    private final class Renderer {
        let render: AVAudioEngineManualRenderingBlock
        init(_ render: @escaping AVAudioEngineManualRenderingBlock) { self.render = render }
    }

    private var unit: AudioUnit?
    private let renderer: Renderer

    init(device: AudioDeviceID, engine: AVAudioEngine) throws {
        renderer = Renderer(engine.manualRenderingBlock)
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0,
            componentFlagsMask: 0)
        var instance: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
            AudioComponentInstanceNew(component, &instance) == noErr, let instance
        else { throw MeetingAudioLibrary.error("Cannot route the audio device.") }
        unit = instance
        var device = device
        let result = AudioUnitSetProperty(
            instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else {
            stop()
            throw MeetingAudioLibrary.error("Cannot select this audio device (\(result)).")
        }
        var format = engine.manualRenderingFormat.streamDescription.pointee
        var frames = UInt32(Self.maximumFrameCount)
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frames, data in
                guard let data else { return noErr }
                var status = noErr
                let result = Unmanaged<Renderer>.fromOpaque(refCon).takeUnretainedValue()
                    .render(frames, data, &status)
                if result != .success {
                    for buffer in UnsafeMutableAudioBufferListPointer(data) {
                        if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
                    }
                }
                return noErr
            }, inputProcRefCon: Unmanaged.passUnretained(renderer).toOpaque())
        guard
            AudioUnitSetProperty(
                instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr,
            AudioUnitSetProperty(
                instance, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                &frames, UInt32(MemoryLayout<UInt32>.size)) == noErr,
            AudioUnitSetProperty(
                instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
            AudioUnitInitialize(instance) == noErr
        else {
            stop()
            throw MeetingAudioLibrary.error("Cannot route the audio device.")
        }
    }

    deinit { stop() }

    func start() throws {
        guard let unit, AudioOutputUnitStart(unit) == noErr else {
            throw MeetingAudioLibrary.error("Cannot start the meeting audio output.")
        }
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }
}
