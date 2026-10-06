import ArgumentParser
import EdithKit
import Foundation

struct CameraAudioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Mix your microphone, speech snippets and effects into a virtual microphone.")

    @Argument(
        help:
            "status, devices, on, off, input, output, mute, unmute, voice, levels, effects, import, record, save, play, stop, edit, remove, source or install."
    ) var action = "status"
    @Argument(help: "Device, voice preset or snippet name.") var value: String?
    @Option(help: "File to import.") var path: String?
    @Flag(help: "Import a sound effect that bypasses voice effects.") var sound = false
    @Option(help: "Clip trim start in seconds.") var start: Double = 0
    @Option(help: "Clip trim end in seconds.") var end: Double?
    @Option(help: "Clip gain from 0 to 2.") var gain: Float = 1
    @Option(help: "Microphone gain from 0 to 2.") var mic: Float?
    @Option(help: "Snippet gain from 0 to 2.") var clips: Float?
    @Option(help: "Video or screen audio gain from 0 to 2.") var source: Float?
    @Option(help: "Pitch adjustment in cents, from -1200 to 1200.") var pitch: Float?
    @Option(help: "Reverb wet mix from 0 to 100.") var reverb: Float?
    @Option(help: "Echo wet mix from 0 to 100.") var delay: Float?
    @Flag(name: .long, help: "Emit JSON.") var json = false

    func run() async throws {
        try await execute {
            if action == "devices" {
                let devices = MeetingAudioDevices.list()
                if json {
                    CLIOut.json(.array(devices.map { $0.jsonValue }))
                } else {
                    devices.forEach {
                        CLIOut.out(
                            "\($0.name): \($0.id) (in \($0.inputChannels), out \($0.outputChannels)\($0.virtual ? ", virtual" : ""))"
                        )
                    }
                }
                return
            }
            if action == "install" {
                try await MeetingMicrophone.install()
                let message =
                    "Approve Edith Microphone installation in macOS, restart your Mac, then select it in your meeting."
                if json {
                    CLIOut.json(.object(["message": .string(message)]))
                } else {
                    CLIOut.out(message)
                }
                return
            }
            if action == "source" {
                try await CameraCLI.perform(
                    .sourceAudio(try ConfigValueParser.boolean(try requiredValue())), json: json)
                return
            }
            let request: MeetingAudioRequest
            switch action {
            case "status": request = .status
            case "on", "off": request = .enable(action == "on")
            case "input": request = .input(try requiredValue())
            case "output": request = .output(try requiredValue())
            case "mute", "unmute": request = .mute(action == "mute")
            case "voice":
                guard let preset = MeetingVoicePreset(rawValue: try requiredValue()) else {
                    throw CLIFailure(
                        "Voices: \(MeetingVoicePreset.allCases.map(\.rawValue).joined(separator: ", "))."
                    )
                }
                request = .voice(preset)
            case "levels": request = .levels(mic: mic, clips: clips, source: source)
            case "effects": request = .effects(pitch: pitch, reverb: reverb, delay: delay)
            case "import":
                guard let path else { throw CLIFailure("Pass --path for the audio file.") }
                request = .importClip(
                    name: try requiredValue(),
                    path: URL(fileURLWithPath: (path as NSString).expandingTildeInPath).path,
                    speech: !sound)
            case "record": request = .recordClip(try requiredValue())
            case "save": request = .finishClip
            case "play": request = .playClip(try requiredValue())
            case "stop": request = .stopClips
            case "edit":
                request = .editClip(name: try requiredValue(), start: start, end: end, gain: gain)
            case "remove": request = .removeClip(try requiredValue())
            default: throw CLIFailure("Unknown audio action. Run ed camera audio --help.")
            }
            let snapshot = try await CameraCLI.request(
                action == "status" ? .status : .audio(request))
            if json {
                CLIOut.json(snapshot.state.audio.jsonValue(status: snapshot.audioStatus))
            } else {
                let audio = snapshot.state.audio
                CLIOut.out(
                    "meeting audio: \(snapshot.audioStatus?.running == true ? "running" : "off"), voice: \(audio.preset.title)"
                )
                if let error = snapshot.audioStatus?.failure { CLIOut.out(error) }
                audio.clips.forEach { CLIOut.out("\($0.name) (\($0.speech ? "speech" : "sound"))") }
            }
        }
    }

    private func requiredValue() throws -> String {
        guard let value else { throw CLIFailure("Pass a value after \(action).") }
        return value
    }
}
