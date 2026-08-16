import AVFoundation
import EdithKit
import Observation
import Speech
import SwiftUI

@MainActor
@Observable
final class CompanionCaptureModel {
    enum Phase {
        case idle
        case recording
        case preview
    }

    private(set) var phase = Phase.idle
    private(set) var transcript = ""
    private(set) var level: Double = 0
    private(set) var duration: TimeInterval = 0
    private(set) var remembering = false
    private(set) var outcome: String?
    private(set) var error: String?
    var note = ""
    private(set) var noteOutcome: String?
    private(set) var savingNote = false
    private(set) var waiting: [CompanionOutboxItem] = []
    private(set) var draining = false

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var speech: SFSpeechRecognizer?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var startedAt: Date?
    private var ticker: Timer?

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    func toggleRecording() async {
        switch phase {
        case .recording: stopRecording()
        case .idle, .preview: await startRecording()
        }
    }

    private func startRecording() async {
        outcome = nil
        error = nil
        let allowed = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard allowed else {
            error = "Microphone access was refused; grant it in System Settings, Privacy."
            return
        }
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            error = "No usable microphone input was found."
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-captures", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let stamp = Self.stamp()
            let url = directory.appendingPathComponent("voice-\(stamp).wav")
            file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false)
            fileURL = url
        } catch {
            self.error = "Could not start a recording file: \(error.localizedDescription)"
            return
        }

        transcript = ""
        if speechStatus == .authorized, let recognizer = SFSpeechRecognizer(),
            recognizer.isAvailable
        {
            speech = recognizer
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            speechRequest = request
            speechTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
                guard let text = result?.bestTranscription.formattedString else { return }
                Task { @MainActor in
                    self?.transcript = text
                }
            }
        } else {
            transcript = ""
        }

        let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1,
            interleaved: false)
        input.installTap(onBus: 0, bufferSize: 4096, format: mono) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.file?.write(from: buffer)
            self.speechRequest?.append(buffer)
            let rms = Self.rms(buffer)
            Task { @MainActor in
                self.level = rms
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "Could not start the microphone: \(error.localizedDescription)"
            return
        }
        startedAt = Date()
        duration = 0
        phase = .recording
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.duration = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        speechRequest?.endAudio()
        speechTask?.finish()
        ticker?.invalidate()
        level = 0
        file = nil
        phase = .preview
    }

    func discard() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        transcript = ""
        duration = 0
        phase = .idle
    }

    func remember() async {
        guard let fileURL, !remembering else { return }
        remembering = true
        defer { remembering = false }
        do {
            let data = try Data(contentsOf: fileURL)
            let outcome = try await client.ingestAudio(
                name: fileURL.lastPathComponent, data: data, mtime: Self.isoNow())
            self.outcome =
                outcome.status == "ingested"
                ? "Remembered as \(outcome.name)"
                : "Already remembered; the companion knew this one"
            try? FileManager.default.removeItem(at: fileURL)
            self.fileURL = nil
            transcript = ""
            duration = 0
            phase = .idle
            error = nil
        } catch {
            guard let kept = CompanionOutbox.keep(fileURL) else {
                self.error = error.localizedDescription
                return
            }
            self.fileURL = nil
            transcript = ""
            duration = 0
            phase = .idle
            self.error = nil
            refreshWaiting()
            outcome =
                "Saved. It'll be remembered when the companion is back. "
                + "\(waiting.count) waiting."
            _ = kept
        }
    }

    func refreshWaiting() {
        waiting = CompanionOutbox.waiting()
    }

    func drainOutbox() async {
        guard !draining, !waiting.isEmpty else { return }
        draining = true
        defer { draining = false }
        let client = client
        let result = await CompanionOutbox.drain { item, data in
            try await client.ingestAudio(
                name: item.name, data: data, mtime: Self.iso(item.recordedAt)
            ).status
        }
        refreshWaiting()
        guard !result.isEmpty else { return }
        outcome = result.summary
    }

    func rememberNote() async {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !savingNote else { return }
        savingNote = true
        defer { savingNote = false }
        do {
            let outcomes = try await client.ingest(files: [
                CompanionIngestFile(
                    name: "note-\(Self.stamp()).md", text: text, mtime: Self.isoNow())
            ])
            noteOutcome =
                outcomes.first?.status == "ingested"
                ? "Remembered" : "Already remembered; nothing new in it"
            note = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func isoNow() -> String {
        iso(Date())
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            sum += samples[index] * samples[index]
        }
        return Double(min(1, sqrt(sum / Float(count)) * 6))
    }
}

struct CompanionCaptureScreen: View {
    @Bindable var model: CompanionCaptureModel
    let home: CompanionHomeModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionGeneration) private var generation
    @State private var pulsing = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            if !model.waiting.isEmpty {
                waitingBanner
            }
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                speakCard
                writeCard
            }
        }
        .pageContent(compact)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: generation) {
            model.refreshWaiting()
            if home.reachable { await model.drainOutbox() }
        }
    }

    private var waitingBanner: some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: "tray.full")
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.accent(dark))
            Text(
                model.waiting.count == 1
                    ? "1 recording is waiting for the companion"
                    : "\(model.waiting.count) recordings are waiting for the companion"
            )
            .font(.system(size: UIScale.pt(11.5)))
            .foregroundStyle(DashSkin.inkSoft(dark))
            Spacer(minLength: 0)
            CompanionButton(
                title: "Send now", busy: model.draining, busyTitle: "Sending…",
                disabled: !home.reachable
            ) {
                Task { await model.drainOutbox() }
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(8))
        .background(DashSkin.paper2(dark))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

    private var speakCard: some View {
        SkinCard(title: "Speak", note: speakNote, dark: dark, fill: true) {
            VStack(spacing: UIScale.pt(14)) {
                Spacer(minLength: 0)
                recordButton
                Text(timeLabel)
                    .font(DashSkin.mono(13))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                levelMeter
                transcriptView
                if model.phase == .preview {
                    HStack(spacing: UIScale.pt(8)) {
                        Button(model.remembering ? "Remembering…" : "Remember this") {
                            Task {
                                await model.remember()
                                await home.refresh()
                            }
                        }
                        .disabled(model.remembering)
                        Button("Discard") {
                            model.discard()
                        }
                        .disabled(model.remembering)
                    }
                }
                if let outcome = model.outcome {
                    Text(outcome)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.ok)
                }
                if let error = model.error {
                    Text(error)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.warn)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var speakNote: String {
        switch model.phase {
        case .idle: return "talk for as long as you like"
        case .recording: return "listening…"
        case .preview: return "keep it or let it go"
        }
    }

    private var recordButton: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            ZStack {
                if model.phase == .recording {
                    Circle()
                        .stroke(DashSkin.accent(dark).opacity(0.35), lineWidth: UIScale.pt(3))
                        .frame(width: UIScale.pt(84), height: UIScale.pt(84))
                        .scaleEffect(pulsing ? 1.12 : 0.95)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.9).repeatForever()) {
                                pulsing = true
                            }
                        }
                        .onDisappear { pulsing = false }
                }
                Circle()
                    .fill(model.phase == .recording ? DashSkin.accent(dark) : DashSkin.paper2(dark))
                    .frame(width: UIScale.pt(68), height: UIScale.pt(68))
                    .overlay {
                        Circle().strokeBorder(
                            model.phase == .recording
                                ? DashSkin.accent(dark) : DashSkin.lineStrong(dark))
                    }
                Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: UIScale.pt(24)))
                    .foregroundStyle(
                        model.phase == .recording ? Color.white : DashSkin.accent(dark))
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(model.phase == .recording ? "Stop recording" : "Start recording")
    }

    private var timeLabel: String {
        let total = Int(model.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var levelMeter: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DashSkin.line(dark))
                Capsule()
                    .fill(DashSkin.accent(dark))
                    .frame(width: max(0, geometry.size.width * model.level))
            }
        }
        .frame(width: UIScale.pt(220), height: UIScale.pt(5))
        .opacity(model.phase == .recording ? 1 : 0.35)
    }

    @ViewBuilder
    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(0)) {
                    if model.transcript.isEmpty {
                        Text(transcriptHint)
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Text(model.transcript)
                            .font(.system(size: UIScale.pt(12.5)))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: UIScale.pt(1)).id("live-bottom")
                }
                .padding(UIScale.pt(10))
            }
            .onChange(of: model.transcript) {
                proxy.scrollTo("live-bottom", anchor: .bottom)
            }
        }
        .frame(maxWidth: UIScale.pt(420), minHeight: UIScale.pt(110), maxHeight: UIScale.pt(180))
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(10)).strokeBorder(DashSkin.line(dark))
        }
    }

    private var transcriptHint: String {
        switch model.phase {
        case .idle: return "A live transcription appears here while you talk."
        case .recording: return "Listening; keep talking."
        case .preview: return "Nothing was transcribed live; whisper still hears it on save."
        }
    }

    private var writeCard: some View {
        SkinCard(title: "Write", note: "a quick note straight to memory", dark: dark, fill: true) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                TextEditor(text: $model.note)
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.ink(dark))
                    .scrollContentBackground(.hidden)
                    .padding(UIScale.pt(8))
                    .frame(minHeight: UIScale.pt(180))
                    .background(
                        DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(10))
                            .strokeBorder(DashSkin.line(dark))
                    }
                HStack(spacing: UIScale.pt(8)) {
                    Button(model.savingNote ? "Remembering…" : "Remember note") {
                        Task {
                            await model.rememberNote()
                            await home.refresh()
                        }
                    }
                    .disabled(
                        model.savingNote
                            || model.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let outcome = model.noteOutcome {
                        Text(outcome)
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
            }
        }
    }
}
