import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import Observation
import Speech
import SwiftUI

final class CompanionRecordingResources {
    let engine = AVAudioEngine()
    var file: AVAudioFile?
    var speech: SFSpeechRecognizer?
    var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    var speechTask: SFSpeechRecognitionTask?
    var ticker: Timer?
    var hasTap = false
    private let callbackLock = NSLock()
    private var accepting = true
    private var activeCallbacks = 0
    private var callbackWaiter: CheckedContinuation<Void, Never>?
    @MainActor private var drain: Task<Void, Never>?
    let updates = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var updateTask: Task<Void, Never>?

    enum Update: Sendable {
        case transcript(String)
        case level(Double)
    }

    func callback(_ body: () -> Void) {
        let admitted = callbackLock.withLock { () -> Bool in
            guard accepting else { return false }
            activeCallbacks += 1
            return true
        }
        guard admitted else { return }
        defer {
            let waiter = callbackLock.withLock { () -> CheckedContinuation<Void, Never>? in
                activeCallbacks -= 1
                guard !accepting, activeCallbacks == 0 else { return nil }
                defer { callbackWaiter = nil }
                return callbackWaiter
            }
            waiter?.resume()
        }
        body()
    }

    @MainActor func stopAndWait() async {
        if let drain { await drain.value; return }
        stop()
        let task = Task { [self] in await waitForReturn() }
        drain = task
        await task.value
    }

    @MainActor private func waitForReturn() async {
        await withCheckedContinuation { continuation in
            let empty = callbackLock.withLock { () -> Bool in
                guard activeCallbacks != 0 else { return true }
                callbackWaiter = continuation
                return false
            }
            if empty { continuation.resume() }
        }
        while let speechTask, speechTask.state != .completed {
            try? await Task.sleep(for: .milliseconds(10))
        }
        updates.continuation.finish()
        await updateTask?.value
        speechRequest = nil; speechTask = nil; speech = nil; file = nil
    }

    func stop() {
        callbackLock.withLock { accepting = false }
        if hasTap { engine.inputNode.removeTap(onBus: 0) }
        hasTap = false
        engine.stop()
        speechRequest?.endAudio()
        speechTask?.cancel()
        ticker?.invalidate()
        ticker = nil
    }

    deinit { stop() }
}

@MainActor
@Observable
final class CompanionCaptureModel {
    enum Phase: String, Codable {
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

    @ObservationIgnored private var recordingResources: CompanionRecordingResources?
    @ObservationIgnored private let recordingFactory:
        @MainActor () throws -> CompanionRecordingResources
    @ObservationIgnored private let remote: CompanionUIBridge?
    private let commandTasks = CompanionTaskOwner()
    @ObservationIgnored private var remoteTask: Task<Void, Never>?
    private var remoteStopped = false
    private var recordingDrains: [UUID: Task<Void, Never>] = [:]
    private var remotePolling: Task<Void, Never>?
    private var fileURL: URL?
    private var startedAt: Date?
    private var startGeneration = 0
    private var starting = false
    private var captureActive = false
    @ObservationIgnored private nonisolated(unsafe) var outboxObserver: NSObjectProtocol?

    let transport: CompanionTransport

    init(
        remote: CompanionUIBridge? = nil,
        recordingFactory: @escaping @MainActor () throws -> CompanionRecordingResources = {
            CompanionRecordingResources()
        }, observeOutbox: Bool = true, transport: CompanionTransport = .shared
    ) {
        self.transport = transport
        self.remote = remote
        self.recordingFactory = recordingFactory
        guard remote == nil, observeOutbox else { return }
        outboxObserver = IPC.observe(CompanionBackgroundOperation.outboxChanged) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.commandTasks.launch { [self] in await self.refreshWaiting() }
            }
        }
    }

    deinit {
        if let outboxObserver { IPC.stopObserving(outboxObserver) }
    }

    func cancelPendingCommands() {
        remoteStopped = true
        commandTasks.cancel()
        startGeneration += 1
        remoteTask?.cancel(); remotePolling?.cancel()
        if let outboxObserver { IPC.stopObserving(outboxObserver) }
        outboxObserver = nil
        retireRecording()
    }

    func cancelAndWait() async {
        cancelPendingCommands()
        await commandTasks.drain()
        await recordingResources?.stopAndWait()
        while let task = recordingDrains.values.first { await task.value }
    }

    func shutdown() {
        cancelPendingCommands()
        if remote != nil {
            remoteStopped = true; remotePolling?.cancel(); remotePolling = nil;
            remoteTask?.cancel(); remoteTask = nil; return
        }
        setCaptureActive(false)
        if let outboxObserver { IPC.stopObserving(outboxObserver) }
        outboxObserver = nil
        recordingResources?.stop()
        recordingResources = nil
    }

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil), transport: transport)
    }

    func toggleRecording() async {
        _ = try? await commandTasks.perform { [self] in await toggleRecordingWork() }
    }

    private func toggleRecordingWork() async {
        if remote != nil { await remoteAction("toggle"); return }
        guard captureActive, !starting, !remembering else { return }
        switch phase {
        case .recording: stopRecording()
        case .idle, .preview: await startRecording()
        }
    }

    private func startRecording() async {
        starting = true
        startGeneration += 1
        let generation = startGeneration
        defer { if generation == startGeneration { starting = false } }
        outcome = nil
        error = nil
        let allowed = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard generation == startGeneration, !Task.isCancelled else { return }
        guard allowed else {
            error = "Microphone access was refused; grant it in System Settings, Privacy."
            return
        }
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard generation == startGeneration, !Task.isCancelled else { return }

        let recording: CompanionRecordingResources
        do {
            guard recordingDrains.count < 8 else { return }
            retireRecording()
            recording = try recordingFactory()
            recordingResources = recording
        } catch {
            self.error = "Could not initialize the microphone: \(error.localizedDescription)"
            return
        }
        let input = recording.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            error = "No usable microphone input was found."
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-captures", isDirectory: true)
        let previousURL = fileURL
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let stamp = Self.stamp()
            let url = directory.appendingPathComponent("voice-\(stamp)-\(UUID().uuidString).wav")
            recording.file = try AVAudioFile(
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

        if speechStatus == .authorized, let recognizer = SFSpeechRecognizer(),
            recognizer.isAvailable
        {
            recording.speech = recognizer
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            recording.speechRequest = request
            recording.speechTask = recognizer.recognitionTask(with: request) {
                [weak recording] result, _ in
                guard let recording else { return }
                recording.callback {
                    if let text = result?.bestTranscription.formattedString {
                        recording.updates.continuation.yield(.transcript(text))
                    }
                }
            }
        }

        let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1,
            interleaved: false)
        recording.updateTask = Task { [weak self, recording] in
            for await update in recording.updates.stream {
                guard let self, !commandTasks.closed, startGeneration == generation,
                    phase == .recording
                else { continue }
                switch update {
                case .transcript(let text): transcript = text
                case .level(let value): level = value
                }
            }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: mono) {
            [weak recording] buffer, _ in
            guard let recording else { return }
            recording.callback {
                try? recording.file?.write(from: buffer)
                recording.speechRequest?.append(buffer)
                recording.updates.continuation.yield(.level(Self.rms(buffer)))
            }
        }
        recording.hasTap = true

        do {
            recording.engine.prepare()
            try recording.engine.start()
        } catch {
            recording.stop()
            await recording.stopAndWait()
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            fileURL = previousURL
            self.error = "Could not start the microphone: \(error.localizedDescription)"
            return
        }
        if let previousURL { try? FileManager.default.removeItem(at: previousURL) }
        transcript = ""
        startedAt = Date()
        duration = 0
        phase = .recording
        recording.ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.commandTasks.closed, self.phase == .recording,
                    let startedAt = self.startedAt
                else {
                    return
                }
                self.duration = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func retireRecording() {
        guard let owner = recordingResources else { return }
        owner.stop()
        let id = UUID()
        recordingDrains[id] = Task { [self, owner] in
            defer { recordingDrains[id] = nil }
            await owner.stopAndWait()
        }
        recordingResources = nil
    }

    private func waitForRecordings() async {
        while let task = recordingDrains.values.first { await task.value }
    }

    private func stopRecording() {
        startGeneration += 1
        retireRecording()
        if let startedAt { duration = Date().timeIntervalSince(startedAt) }
        startedAt = nil
        level = 0
        phase = .preview
    }

    func setCaptureActive(_ active: Bool) {
        guard !commandTasks.closed else { return }
        if remote != nil {
            remoteTask?.cancel(); remotePolling?.cancel(); remotePolling = nil
            remoteTask = commandTasks.launch { [self] in
                await remoteAction(active ? "activate" : "deactivate")
            }
            if active {
                remotePolling = commandTasks.launch { [weak self] in
                    while !Task.isCancelled {
                        guard let self, !remoteStopped else { return }
                        await remoteAction("snapshot")
                        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                    }
                }
            }
            return
        }
        captureActive = active
        if !active { leaveCapture() }
    }

    private func leaveCapture() {
        startGeneration += 1
        starting = false
        if phase == .recording { stopRecording() }
    }

    func discard() {
        guard !commandTasks.closed else { return }
        if remote != nil {
            remoteTask = commandTasks.launch { [self] in await remoteAction("discard") }; return
        }
        leaveCapture()
        _ = commandTasks.launch { [self] in
            await waitForRecordings()
            guard !commandTasks.closed else { return }
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            fileURL = nil; transcript = ""; duration = 0; phase = .idle
        }
    }

    func remember() async {
        _ = try? await commandTasks.perform { [self] in await rememberWork() }
    }

    private func rememberWork() async {
        if remote != nil { await remoteAction("remember"); return }
        guard let fileURL, !remembering else { return }
        leaveCapture()
        remembering = true
        defer { remembering = false }
        await waitForRecordings()
        guard !commandTasks.closed else { return }
        let kept = await Task.detached(priority: .utility) {
            CompanionOutbox.keep(fileURL)
        }.value
        guard kept != nil else {
            error = "Could not save the recording for delivery. The preview is still available."
            return
        }
        self.fileURL = nil
        transcript = ""
        duration = 0
        phase = .idle
        error = nil
        await refreshWaiting()
        outcome = "Saved for background delivery. \(waiting.count) waiting."
        await drainOutbox()
    }

    func refreshWaiting() async {
        _ = try? await commandTasks.perform { [self] in await refreshWaitingWork() }
    }

    private func refreshWaitingWork() async {
        if remote != nil { await remoteAction("snapshot"); return }
        waiting = await Task.detached(priority: .utility) {
            CompanionOutbox.waiting()
        }.value
    }

    func drainOutbox() async {
        _ = try? await commandTasks.perform { [self] in await drainOutboxWork() }
    }

    private func drainOutboxWork() async {
        if remote != nil { await remoteAction("drain"); return }
        guard !draining, !waiting.isEmpty else { return }
        draining = true
        defer { draining = false }
        do {
            try await CompanionBackgroundOperation.requestRefresh()
            error = nil
            outcome = "Saved recordings will be sent in the background when the companion is ready."
        } catch {
            self.error = "Recordings are saved. \(error.localizedDescription)"
        }
        await refreshWaiting()
    }

    func rememberNote() async {
        _ = try? await commandTasks.perform { [self] in await rememberNoteWork() }
    }

    private func rememberNoteWork() async {
        if remote != nil { await remoteAction("note"); return }
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

    private func remoteAction(_ action: String) async {
        guard let remote, !remoteStopped else { return }
        do {
            let value = try await remote.capture(action, note: note)
            guard !remoteStopped, !Task.isCancelled else { return }
            phase = value.phase; transcript = value.transcript; level = value.level;
            duration = value.duration
            remembering = value.remembering; outcome = value.outcome; error = value.error
            note = value.note; noteOutcome = value.noteOutcome; savingNote = value.savingNote
            waiting = value.waiting; draining = value.draining
        } catch { if !remoteStopped, !Task.isCancelled { self.error = error.localizedDescription } }
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
    var isActive = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionGeneration) private var generation
    @State private var refreshedGeneration = -1
    @State private var pulsing = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        PageScaffold(pinnedHeader: true, header: {}) {
            if !model.waiting.isEmpty {
                waitingBanner
            }
            PageColumns {
                speakCard
                writeCard
            }
        }
        .pageTask(id: generation, active: isActive) {
            guard isActive, refreshedGeneration != generation else { return }
            await model.refreshWaiting()
            if !Task.isCancelled { refreshedGeneration = generation }
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
                title: "Send now", busy: model.draining, busyTitle: "Requesting…"
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
        PageCard(title: "Speak", note: speakNote, fill: true) {
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
        .buttonStyle(.edith(.borderless))
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
        .frame(maxWidth: UIScale.pt(220))
        .frame(height: UIScale.pt(5))
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
        PageCard(title: "Write", note: "a quick note straight to memory", fill: true) {
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
