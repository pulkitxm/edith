import EdithExtensionSupport
@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

public final class MeetingAudioMixer: @unchecked Sendable {
    public let queue = DispatchQueue(label: "com.pulkit.edith.meeting.audio", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var capture: MeetingAudioCapture?
    private var micPlayer: AVAudioPlayerNode?
    private var effects: MeetingVoiceEffects?
    private var micMixer: AVAudioMixerNode?
    private var speechMixer: AVAudioMixerNode?
    private var sourcePlayer: AVAudioPlayerNode?
    private var mediaAudio: MeetingMediaAudio?
    private var mixedOutput: (@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)?
    private var outputTap = false
    private var clipPlayers: [UUID: AVAudioPlayerNode] = [:]
    private var speechTap = false
    private var voiceStream: MeetingVoiceStream?
    private var voicePlayer: AVAudioPlayerNode?
    private var recording: AVAudioFile?
    private var recordingClip: MeetingAudioClip?
    private var state = MeetingAudioState()
    private let lock = NSLock()
    private var statusValue = MeetingAudioStatus()
    private var pendingBuffers = 0
    private var generation = 0

    public init() {}
    public var status: MeetingAudioStatus { lock.withLock { statusValue } }

    public func configure(_ state: MeetingAudioState) {
        queue.async { [weak self] in
            guard let self else { return }
            do { try self.apply(state) } catch {
                self.updateStatus { $0.failure = error.localizedDescription }
            }
        }
    }

    private func apply(_ next: MeetingAudioState) throws {
        let rebuild =
            next.inputID != state.inputID || next.outputID != state.outputID
            || next.voiceModelID != state.voiceModelID
            || next.voiceTranspose != state.voiceTranspose
        guard recording == nil || (next.enabled && !rebuild) else {
            throw MeetingAudioLibrary.error(
                "Save the recording before changing audio devices or disabling audio.")
        }
        let previous = state
        state = next
        if !next.enabled { stop(); return }
        if rebuild { stop() }
        if engine == nil {
            do { try start() } catch { state = previous; throw error }
        }
        micMixer?.outputVolume = next.muted ? 0 : next.micGain
        effects?.apply(next)
        sourcePlayer?.volume = next.sourceGain
        for (id, player) in clipPlayers {
            player.volume = (next.clips.first { $0.id == id }?.gain ?? 1) * next.clipsGain
        }
        if voiceStream?.isStopped != true { updateStatus { $0.failure = nil } }
    }

    private func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MeetingAudioLibrary.error("Allow microphone access to enable meeting audio.")
        }
        let devices = MeetingAudioDevices.list()
        let output: MeetingAudioDevice
        if let id = state.outputID {
            output = try MeetingAudioDevices.resolve(id, output: true)
        } else if let device = devices.first(where: {
            $0.id == MeetingMicrophone.id && $0.outputChannels > 0
        }) {
            output = device
        } else {
            throw MeetingAudioLibrary.error(
                "Edith Microphone is unavailable. Complete Edith’s application setup and background helper approval in Settings."
            )
        }
        let input: MeetingAudioDevice
        if let id = state.inputID {
            input = try MeetingAudioDevices.resolve(id, output: false)
        } else if let device = devices.first(where: {
            $0.objectID == MeetingAudioDevices.defaultInput()
        }) {
            input = device
        } else {
            throw MeetingAudioLibrary.error("No microphone is connected.")
        }
        guard input.objectID != output.objectID else {
            throw MeetingAudioLibrary.error(
                "The microphone and meeting output must be different devices.")
        }
        let engine = AVAudioEngine()
        try setDevice(output.objectID, unit: engine.outputNode.audioUnit)
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let effects = MeetingVoiceEffects()
        let mic = AVAudioMixerNode()
        let microphone = AVAudioPlayerNode()
        let speech = AVAudioMixerNode()
        let source = AVAudioPlayerNode()
        engine.attach(mic)
        engine.attach(microphone)
        engine.attach(speech)
        engine.attach(source)
        for node in effects.nodes { engine.attach(node) }
        engine.connect(microphone, to: mic, format: inputFormat)
        engine.connect(mic, to: speech, fromBus: 0, toBus: 0, format: inputFormat)
        self.engine = engine
        micPlayer = microphone
        self.effects = effects
        micMixer = mic
        speechMixer = speech
        var completed = false
        defer { if !completed { stop() } }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        var previous: AVAudioNode = speech
        if let id = state.voiceModelID {
            guard let model = state.voiceModels.first(where: { $0.id == id }) else {
                throw MeetingAudioLibrary.error("The selected voice model is unavailable.")
            }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let stream = try MeetingVoiceStream(
                model: model, input: format, player: player, transpose: state.voiceTranspose,
                failure: { [weak self] message in self?.updateStatus { $0.failure = message } })
            let gate = AVAudioMixerNode()
            engine.attach(gate)
            engine.connect(speech, to: gate, format: format)
            gate.outputVolume = 0
            engine.connect(gate, to: engine.mainMixerNode, fromBus: 0, toBus: 2, format: format)
            speech.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                if let copy = Self.copy(buffer) { stream.enqueue(copy) }
            }
            speechTap = true
            voiceStream = stream
            voicePlayer = player
            let resampler = AVAudioMixerNode()
            engine.attach(resampler)
            engine.connect(player, to: resampler, format: stream.outputFormat)
            previous = resampler
        }
        for node in effects.nodes {
            engine.connect(previous, to: node, format: format)
            previous = node
        }
        engine.connect(previous, to: engine.mainMixerNode, fromBus: 0, toBus: 0, format: format)
        engine.connect(source, to: engine.mainMixerNode, fromBus: 0, toBus: 1, format: format)
        engine.attach(effects.limiter)
        engine.connect(engine.mainMixerNode, to: effects.limiter, format: format)
        engine.connect(effects.limiter, to: engine.outputNode, format: nil)
        self.engine = engine
        self.effects = effects
        micMixer = mic
        speechMixer = speech
        sourcePlayer = source
        mediaAudio = MeetingMediaAudio(player: source, queue: queue)
        let generation = lock.withLock {
            self.generation += 1
            pendingBuffers = 0
            return self.generation
        }
        capture = try MeetingAudioCapture(
            deviceID: input.id,
            queue: DispatchQueue(label: "com.pulkit.edith.meeting.capture", qos: .userInteractive),
            format: inputFormat,
            receive: { [weak self] copy in
                guard let self, copy.frameLength > 0 else { return }
                let depth = self.lock.withLock {
                    guard self.generation == generation, self.pendingBuffers < 16 else { return 0 }
                    self.pendingBuffers += 1
                    return self.pendingBuffers
                }
                guard depth > 0 else { return }
                microphone.scheduleBuffer(copy, completionCallbackType: .dataPlayedBack) {
                    [weak self] _ in
                    guard let self else { return }
                    self.lock.withLock {
                        if self.generation == generation {
                            self.pendingBuffers = max(0, self.pendingBuffers - 1)
                        }
                    }
                }
                if depth >= 2 && !microphone.isPlaying { microphone.play() }
                self.queue.async { [weak self] in
                    guard let self, self.lock.withLock({ self.generation == generation }),
                        let recording = self.recording
                    else { return }
                    do { try recording.write(from: copy) } catch {
                        self.updateStatus { $0.failure = error.localizedDescription }
                    }
                }
            }, failure: { [weak self] message in self?.updateStatus { $0.failure = message } })
        effects.limiter.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak self] buffer, time in
            guard let self, let copy = Self.copy(buffer) else { return }
            let timestamp =
                time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : ProcessInfo.processInfo.systemUptime
            let handler = self.lock.withLock { self.mixedOutput }
            handler?(copy, timestamp)
        }
        outputTap = true
        effects.apply(state)
        mic.outputVolume = state.muted ? 0 : state.micGain
        state.inputID = input.id
        state.outputID = output.id
        source.volume = state.sourceGain
        do {
            try engine.start()
            try capture?.start()
        } catch { stop(); throw error }
        source.play()
        voicePlayer?.play()
        completed = true
        updateStatus {
            $0.running = true
            $0.inputName = input.name
            $0.outputName = output.name
        }
    }

    private func setDevice(_ device: AudioDeviceID, unit: AudioUnit?) throws {
        guard let unit else { throw MeetingAudioLibrary.error("Cannot route the audio device.") }
        var device = device
        let result = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else {
            throw MeetingAudioLibrary.error("Cannot select this audio device (\(result)).")
        }
    }

    public func perform(_ request: MeetingAudioRequest, state: MeetingAudioState) async throws
        -> MeetingAudioState
    {
        if request == .enable(true),
            AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MeetingAudioLibrary.error("Microphone access was denied.")
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(throwing: CancellationError()); return }
                do {
                    continuation.resume(returning: try self.performOnQueue(request, state: state))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func performOnQueue(_ request: MeetingAudioRequest, state: MeetingAudioState) throws
        -> MeetingAudioState
    {
        var next = state
        switch request {
        case .status: return next
        case .enable(let enabled): next.enabled = enabled
        case .input(let id):
            next.inputID = id.isEmpty ? nil : try MeetingAudioDevices.resolve(id, output: false).id
        case .output(let id):
            next.outputID = id.isEmpty ? nil : try MeetingAudioDevices.resolve(id, output: true).id
        case .mute(let muted): next.muted = muted
        case .voice(let preset): next.preset = preset
        case .levels(let mic, let clips, let source):
            if let mic { next.micGain = try checked(mic, range: 0...2) }
            if let clips { next.clipsGain = try checked(clips, range: 0...2) }
            if let source { next.sourceGain = try checked(source, range: 0...2) }
        case .effects(let pitch, let reverb, let delay):
            if let pitch { next.pitch = try checked(pitch, range: -1200...1200) }
            if let reverb { next.reverb = try checked(reverb, range: 0...100) }
            if let delay { next.delay = try checked(delay, range: 0...100) }
        case .importClip(let name, let path, let speech):
            try validateName(name, state: next)
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            guard file.length > 0 else {
                throw MeetingAudioLibrary.error("The audio file is empty.")
            }
            guard
                let probe = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)
            else { throw MeetingAudioLibrary.error("The audio format is not supported.") }
            try file.read(into: probe)
            guard probe.frameLength > 0 else {
                throw MeetingAudioLibrary.error("The audio file could not be decoded.")
            }
            try FileManager.default.createDirectory(
                at: MeetingAudioLibrary.directory, withIntermediateDirectories: true)
            let url = MeetingAudioLibrary.directory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(URL(fileURLWithPath: path).pathExtension)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
            next.clips.append(MeetingAudioClip(name: name, path: url.path, speech: speech))
        case .editClip(let name, let start, let end, let gain):
            let clip = try MeetingAudioLibrary.clip(name, in: next)
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: clip.path))
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard start.isFinite, start >= 0, start < duration,
                end.map({ $0.isFinite && $0 > start && $0 <= duration }) ?? true
            else {
                throw MeetingAudioLibrary.error("Choose a trim range within the clip duration.")
            }
            guard let index = next.clips.firstIndex(where: { $0.id == clip.id }) else {
                return next
            }
            next.clips[index].start = start
            next.clips[index].end = end
            next.clips[index].gain = try checked(gain, range: 0...2)
        case .recordClip(let name):
            try validateName(name, state: next)
            guard recording == nil else {
                throw MeetingAudioLibrary.error("A snippet is already recording.")
            }
            guard let engine, engine.isRunning else {
                throw MeetingAudioLibrary.error("Enable meeting audio first.")
            }
            try FileManager.default.createDirectory(
                at: MeetingAudioLibrary.directory, withIntermediateDirectories: true)
            let url = MeetingAudioLibrary.directory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("caf")
            recording = try AVAudioFile(
                forWriting: url,
                settings: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!.settings)
            let clip = MeetingAudioClip(name: name, path: url.path)
            recordingClip = clip
            next.clips.append(clip)
            updateStatus { $0.recordingName = name }
        case .finishClip:
            guard recording?.length ?? 0 > 0 else {
                throw MeetingAudioLibrary.error("No audio was captured.")
            }
            guard recordingClip != nil else {
                throw MeetingAudioLibrary.error("No snippet is recording.")
            }
            recording = nil
            recordingClip = nil
            updateStatus { $0.recordingName = nil }
        case .playClip(let name):
            try play(try MeetingAudioLibrary.clip(name, in: next), state: next)
        case .stopClips: stopClips()
        case .importVoice(let name, let encoder, let voice):
            guard
                !next.voiceModels.contains(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                })
            else {
                throw MeetingAudioLibrary.error("A voice model named \(name) already exists.")
            }
            next.voiceModels.append(
                try MeetingVoiceLibrary.importing(name: name, encoder: encoder, voice: voice))
        case .selectVoice(let name):
            if name.isEmpty {
                next.voiceModelID = nil
            } else {
                guard
                    let model = next.voiceModels.first(where: {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame
                            || $0.id.uuidString == name
                    })
                else {
                    throw MeetingAudioLibrary.error("No voice model named \(name).")
                }
                next.voiceModelID = model.id
            }
        case .modelPitch(let value): next.voiceTranspose = try checked(value, range: -24...24)
        case .removeVoice(let name):
            guard
                let model = next.voiceModels.first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString == name
                })
            else {
                throw MeetingAudioLibrary.error("No voice model named \(name).")
            }
            if next.voiceModelID == model.id { next.voiceModelID = nil }
            next.voiceModels.removeAll { $0.id == model.id }
        case .removeClip(let name):
            let clip = try MeetingAudioLibrary.clip(name, in: next)
            finishPlayer(clip.id)
            next.clips.removeAll { $0.id == clip.id }
        }
        try apply(next)
        return self.state
    }

    private func checked(_ value: Float, range: ClosedRange<Float>) throws -> Float {
        guard value.isFinite, range.contains(value) else {
            throw MeetingAudioLibrary.error(
                "Value must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return value
    }

    private func validateName(_ name: String, state: MeetingAudioState) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 60 else {
            throw MeetingAudioLibrary.error("Use a snippet name of 1 to 60 characters.")
        }
        guard !state.clips.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { throw MeetingAudioLibrary.error("That snippet name already exists.") }
    }

    private func play(_ clip: MeetingAudioClip, state: MeetingAudioState) throws {
        guard let engine, engine.isRunning, let speechMixer else {
            throw MeetingAudioLibrary.error("Enable meeting audio first.")
        }
        if clipPlayers[clip.id] != nil { return }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: clip.path))
        let start = AVAudioFramePosition(clip.start * file.processingFormat.sampleRate)
        let end = min(
            file.length,
            AVAudioFramePosition(
                (clip.end ?? Double(file.length) / file.processingFormat.sampleRate)
                    * file.processingFormat.sampleRate))
        guard end > start, end - start <= Int64(UInt32.max) else {
            throw MeetingAudioLibrary.error("Choose a shorter audio clip.")
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        if clip.speech {
            engine.connect(player, to: speechMixer, format: file.processingFormat)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        }
        player.volume = clip.gain * state.clipsGain
        clipPlayers[clip.id] = player
        updateStatus { $0.playing.append(clip.id.uuidString) }
        player.scheduleSegment(
            file, startingFrame: start, frameCount: AVAudioFrameCount(end - start), at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.finishPlayer(clip.id) }
        }
        player.play()
    }

    private func finishPlayer(_ id: UUID) {
        guard let player = clipPlayers.removeValue(forKey: id) else { return }
        player.stop()
        engine?.detach(player)
        updateStatus { $0.playing.removeAll { $0 == id.uuidString } }
    }

    private func stopClips() {
        for player in clipPlayers.values { player.stop(); engine?.detach(player) }
        clipPlayers.removeAll()
        updateStatus { $0.playing = [] }
    }

    public func setMixedOutput(
        _ output: @escaping @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void
    ) {
        lock.withLock { mixedOutput = output }
    }

    public func syncVideoAudio(path: String, time: Double, playing: Bool) {
        queue.async { [weak self] in
            guard let self, self.state.enabled else { return }
            do { try self.mediaAudio?.syncVideo(path: path, time: time, playing: playing) } catch {
                self.updateStatus { $0.sourceFailure = error.localizedDescription }
            }
        }
    }

    public func appendScreenAudio(_ sample: CMSampleBuffer) {
        guard let buffer = MeetingPCM.buffer(from: sample) else { return }
        queue.async { [weak self] in
            guard let self, self.state.enabled else { return }
            do { try self.mediaAudio?.appendScreen(buffer) } catch {
                self.updateStatus { $0.sourceFailure = error.localizedDescription }
            }
        }
    }

    public func stopSourceAudio() {
        queue.async { [weak self] in
            self?.mediaAudio?.stop()
            self?.updateStatus { $0.sourceFailure = nil }
        }
    }

    public func shutdown() { queue.async { [weak self] in self?.stop() } }

    private func stop() {
        lock.withLock {
            generation += 1
            pendingBuffers = 0
        }
        voiceStream?.stop()
        voiceStream = nil
        voicePlayer = nil
        if speechTap { speechMixer?.removeTap(onBus: 0) }
        speechTap = false
        stopClips()
        capture?.stop()
        capture = nil
        micPlayer?.stop()
        micPlayer = nil
        if outputTap { effects?.limiter.removeTap(onBus: 0) }
        outputTap = false
        mediaAudio?.stop()
        mediaAudio = nil
        engine?.stop()
        engine = nil
        effects = nil
        micMixer = nil
        speechMixer = nil
        sourcePlayer = nil
        recording = nil
        recordingClip = nil
        updateStatus { $0 = MeetingAudioStatus() }
    }

    private func updateStatus(_ change: (inout MeetingAudioStatus) -> Void) {
        lock.withLock { change(&statusValue) }
    }

    static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
        else { return nil }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in from.indices {
            guard let input = from[index].mData, let output = to[index].mData else { continue }
            memcpy(output, input, min(Int(from[index].mDataByteSize), Int(to[index].mDataByteSize)))
        }
        return copy
    }
}
