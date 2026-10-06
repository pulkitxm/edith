import AVFoundation
import AudioToolbox

public final class MeetingVoiceEffects {
    public let pitch = AVAudioUnitTimePitch()
    public let equalizer = AVAudioUnitEQ(numberOfBands: 2)
    public let distortion = AVAudioUnitDistortion()
    public let delay = AVAudioUnitDelay()
    public let reverb = AVAudioUnitReverb()
    public let compressor = AVAudioUnitEffect(
        audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0,
            componentFlagsMask: 0))

    public var nodes: [AVAudioNode] { [pitch, equalizer, distortion, delay, reverb] }

    public init() {
        reverb.loadFactoryPreset(.smallRoom)
        delay.delayTime = 0.18
        delay.feedback = 15
        AudioUnitSetParameter(
            compressor.audioUnit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -18,
            0)
        AudioUnitSetParameter(
            compressor.audioUnit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 6, 0)
        AudioUnitSetParameter(
            compressor.audioUnit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0,
            0.005, 0)
        AudioUnitSetParameter(
            compressor.audioUnit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0,
            0.08, 0)
    }

    public func apply(_ state: MeetingAudioState) {
        pitch.pitch = state.preset.pitch + state.pitch
        pitch.rate = 1
        for band in equalizer.bands { band.bypass = true }
        equalizer.globalGain = 0
        distortion.wetDryMix = 0
        delay.wetDryMix = state.delay
        reverb.wetDryMix = state.reverb
        if state.preset == .telephone || state.preset == .radio {
            let high = equalizer.bands[0]
            high.filterType = .highPass
            high.frequency = state.preset == .telephone ? 300 : 100
            high.bypass = false
            let low = equalizer.bands[1]
            low.filterType = .lowPass
            low.frequency = state.preset == .telephone ? 3400 : 8000
            low.bypass = false
        }
        if state.preset == .robot || state.preset == .alien {
            distortion.loadFactoryPreset(
                state.preset == .robot ? .speechRadioTower : .speechCosmicInterference)
            distortion.wetDryMix = state.preset == .robot ? 35 : 25
        }
        if state.preset == .echo { delay.wetDryMix = max(state.delay, 25) }
        if state.preset == .cinematic { reverb.wetDryMix = max(state.reverb, 8) }
    }
}
