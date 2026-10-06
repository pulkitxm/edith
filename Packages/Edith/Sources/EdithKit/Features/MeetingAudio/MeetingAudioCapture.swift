@preconcurrency import AVFoundation
import Foundation

final class MeetingAudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let format: AVAudioFormat
    private let receive: (AVAudioPCMBuffer) -> Void
    private let failure: (String) -> Void
    private var converter: AVAudioConverter?

    init(
        deviceID: String, queue: DispatchQueue, format: AVAudioFormat,
        receive: @escaping (AVAudioPCMBuffer) -> Void, failure: @escaping (String) -> Void
    ) throws {
        self.format = format
        self.receive = receive
        self.failure = failure
        super.init()
        guard let device = AVCaptureDevice(uniqueID: deviceID), device.hasMediaType(.audio) else {
            throw MeetingAudioLibrary.error("The selected microphone cannot capture audio.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw MeetingAudioLibrary.error("Cannot start the selected microphone.")
        }
        session.addInput(input)
        session.addOutput(output)
    }

    func start() throws {
        session.startRunning()
        guard session.isRunning else {
            throw MeetingAudioLibrary.error("The selected microphone did not start.")
        }
    }

    func stop() { session.stopRunning() }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let input = MeetingPCM.buffer(from: sampleBuffer) else { return }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
        }
        guard let converter else { failure("Cannot convert microphone audio."); return }
        do { receive(try MeetingPCM.convert(input, using: converter)) } catch {
            failure(error.localizedDescription)
        }
    }
}
