import AVFoundation
import AudioToolbox

public final class MeetingVoiceEffects {
    public let pitch = AVAudioUnitTimePitch()
    public let equalizer = AVAudioUnitEQ(numberOfBands: 2)
    public let distortion = AVAudioUnitDistortion()
    public let delay = AVAudioUnitDelay()
    public let reverb = AVAudioUnitReverb()
    public let limiter = AVAudioUnitEffect(
        audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0,
            componentFlagsMask: 0))

    public var nodes: [AVAudioNode] { [pitch, equalizer, distortion, delay, reverb] }

    public init() {
        reverb.loadFactoryPreset(.smallRoom)
        delay.delayTime = 0.18
        delay.feedback = 15
        AudioUnitSetParameter(
            limiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
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
        pitch.bypass = pitch.pitch == 0
        equalizer.bypass = state.preset != .telephone && state.preset != .radio
        distortion.bypass = distortion.wetDryMix == 0
        delay.bypass = delay.wetDryMix == 0
        reverb.bypass = reverb.wetDryMix == 0
    }
}
