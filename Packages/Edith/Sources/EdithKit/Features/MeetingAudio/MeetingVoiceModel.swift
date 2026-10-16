import Foundation
import ExtensionMarketplace

public struct MeetingVoiceModel: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var encoderPath: String
    public var voicePath: String
}

public final class MeetingVoiceInference {
    private typealias Create =
        @convention(c) (
            UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int
        ) -> UnsafeMutableRawPointer?
    private typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Convert =
        @convention(c) (
            UnsafeMutableRawPointer?, UnsafePointer<Float>?, Int, Float,
            UnsafeMutablePointer<Float>?, Int, UnsafeMutablePointer<Int32>?,
            UnsafeMutablePointer<CChar>?, Int
        ) -> Int32
    private let library: ExtensionNativeLibrary
    private let destroy: Destroy
    private let conversion: Convert
    private let handle: UnsafeMutableRawPointer

    public init(model: MeetingVoiceModel) throws {
        library = try ExtensionNativeLibrary.load(
            id: "audioMixer", store: MarketplaceServices.store,
            hostABI: MarketplaceConfiguration.hostABI, verify: MarketplaceServices.verifyBundle)
        let create = try library.symbol("MeetingVoiceCreate", as: Create.self)
        destroy = try library.symbol("MeetingVoiceDestroy", as: Destroy.self)
        conversion = try library.symbol("MeetingVoiceConvert", as: Convert.self)
        var error = [CChar](repeating: 0, count: 2048)
        guard
            let handle = create(model.encoderPath, model.voicePath, &error, error.count)
        else {
            throw MeetingAudioLibrary.error(String(cString: error))
        }
        self.handle = handle
    }

    deinit { destroy(handle) }

    public func convert(_ samples: [Float], transpose: Float = 0) throws -> (
        samples: [Float], rate: Int
    ) {
        guard transpose.isFinite, samples.allSatisfy(\.isFinite) else {
            throw MeetingAudioLibrary.error(
                "Voice conversion requires finite audio and pitch values.")
        }
        var output = [Float](repeating: 0, count: 96000)
        var rate: Int32 = 0
        var error = [CChar](repeating: 0, count: 2048)
        let count = samples.withUnsafeBufferPointer { audio in
            conversion(
                handle, audio.baseAddress, audio.count, transpose, &output, output.count, &rate,
                &error, error.count)
        }
        guard count > 0 else { throw MeetingAudioLibrary.error(String(cString: error)) }
        return (Array(output.prefix(Int(count))), Int(rate))
    }
}

public enum MeetingVoiceLibrary {
    public static var directory: URL {
        MeetingAudioLibrary.directory.appendingPathComponent("voices", isDirectory: true)
    }

    public static func importing(name: String, encoder: String, voice: String) throws
        -> MeetingVoiceModel
    {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingAudioLibrary.error("Give the voice model a name.")
        }
        let model = MeetingVoiceModel(name: name, encoderPath: encoder, voicePath: voice)
        for path in [encoder, voice] {
            let url = URL(fileURLWithPath: path)
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard url.pathExtension.lowercased() == "onnx", attributes.isRegularFile == true,
                let size = attributes.fileSize, size > 0, size <= 512 * 1024 * 1024
            else {
                throw MeetingAudioLibrary.error("Choose ONNX model files smaller than 512 MB.")
            }
        }
        let destination = directory.appendingPathComponent(model.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let encoderURL = destination.appendingPathComponent("encoder.onnx")
            let voiceURL = destination.appendingPathComponent("voice.onnx")
            try FileManager.default.copyItem(atPath: encoder, toPath: encoderURL.path)
            try FileManager.default.copyItem(atPath: voice, toPath: voiceURL.path)
            let owned = MeetingVoiceModel(
                id: model.id, name: name, encoderPath: encoderURL.path, voicePath: voiceURL.path)
            let inference = try MeetingVoiceInference(model: owned)
            _ = try inference.convert([Float](repeating: 0, count: 10240))
            return owned
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
