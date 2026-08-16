import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
final class CompanionChatModel {
    struct DisplayMessage: Identifiable, Equatable {
        let id: String
        let role: String
        var content: String
        var citations: [CompanionAskCitation]
        var streaming: Bool
        var stopped = false
        var model: String?
        var createdAt: String?
    }

    struct ChatFailure: Equatable {
        let message: String
        let retryText: String?
    }

    private(set) var conversations: [CompanionConversation] = []
    private(set) var messages: [DisplayMessage] = []
    private(set) var activeConversationId: String?
    var draft = ""
    private(set) var streaming = false
    private(set) var model: String?
    private(set) var failure: ChatFailure?
    private(set) var loaded = false
    private(set) var loadError: String?
    private(set) var personas: [CompanionPersona] = []
    var persona: String?
    private(set) var council: CompanionCouncil?
    private(set) var councilRunning = false
    private(set) var councilQuestion: String?
    private(set) var focusTick = 0
    private var streamTask: Task<Void, Never>?

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    func loadPersonas() async {
        personas = (try? await client.personas()) ?? []
    }

    var councilSubject: String? {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return messages.last(where: { $0.role == "user" })?.content
    }

    func askCouncil() async {
        guard !councilRunning, !streaming else { return }
        guard let question = councilSubject else {
            failure = ChatFailure(
                message: "Type a question first, then ask for a second opinion.",
                retryText: nil)
            return
        }
        councilRunning = true
        councilQuestion = question
        defer { councilRunning = false }
        do {
            let outcome = try await client.council(question: question, personas: [])
            council = outcome
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == question {
                draft = ""
            }
            failure = nil
        } catch {
            failure = ChatFailure(message: error.localizedDescription, retryText: nil)
            councilQuestion = nil
        }
    }

    func dismissCouncil() {
        council = nil
        councilQuestion = nil
    }

    func loadConversations() async {
        do {
            conversations = try await client.conversations(limit: 50)
            loaded = true
            loadError = nil
        } catch {
            if !loaded { loadError = error.localizedDescription }
        }
    }

    func open(_ id: String) async {
        if streaming { stop() }
        activeConversationId = id
        do {
            let detail = try await client.conversation(id: id)
            messages = detail.messages.map {
                DisplayMessage(
                    id: $0.id, role: $0.role, content: $0.content,
                    citations: $0.citations ?? [], streaming: false,
                    model: $0.model, createdAt: $0.createdAt)
            }
            failure = nil
            focusTick += 1
        } catch {
            failure = ChatFailure(message: error.localizedDescription, retryText: nil)
        }
    }

    func newChat() {
        guard !streaming else { return }
        activeConversationId = nil
        messages = []
        failure = nil
        focusTick += 1
    }

    func delete(_ id: String) async {
        do {
            _ = try await client.deleteConversation(id: id)
        } catch {
            failure = ChatFailure(message: error.localizedDescription, retryText: nil)
        }
        if activeConversationId == id { newChat() }
        await loadConversations()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streaming else { return }
        draft = ""
        failure = nil
        streaming = true
        let userId = "local-\(UUID().uuidString)"
        messages.append(
            DisplayMessage(
                id: userId, role: "user", content: text, citations: [], streaming: false))
        let replyId = "reply-\(UUID().uuidString)"
        messages.append(
            DisplayMessage(
                id: replyId, role: "assistant", content: "", citations: [], streaming: true,
                model: model))
        streamTask = Task {
            await stream(text: text, userId: userId, replyId: replyId)
        }
    }

    func retry() {
        guard let failure, let text = failure.retryText else { return }
        draft = text
        self.failure = nil
        send()
    }

    func stop() {
        streamTask?.cancel()
    }

    private func stream(text: String, userId: String, replyId: String) async {
        var failed: String?
        do {
            var buffer = ""
            var lastFlush = ContinuousClock.now
            for try await event in client.chat(
                message: text, conversationId: activeConversationId, persona: persona)
            {
                if Task.isCancelled { break }
                switch event {
                case let .meta(conversationId, model):
                    activeConversationId = conversationId
                    self.model = model
                    update(replyId) { $0.model = model }
                case let .delta(delta):
                    buffer += delta
                    let now = ContinuousClock.now
                    if lastFlush.duration(to: now) > .milliseconds(60) {
                        let chunk = buffer
                        buffer = ""
                        lastFlush = now
                        update(replyId) { $0.content += chunk }
                    }
                case let .citations(citations):
                    update(replyId) { $0.citations = citations }
                case .done:
                    break
                case let .failure(message):
                    failed = message
                }
            }
            if !buffer.isEmpty {
                let chunk = buffer
                update(replyId) { $0.content += chunk }
            }
        } catch is CancellationError {
        } catch {
            failed = friendlyChatError(error)
        }
        let cancelled = Task.isCancelled
        streaming = false
        streamTask = nil
        update(replyId) {
            $0.streaming = false
            $0.stopped = cancelled
        }
        let empty = messages.first(where: { $0.id == replyId })?.content.isEmpty ?? true
        if empty {
            messages.removeAll { $0.id == replyId }
            if let failed {
                messages.removeAll { $0.id == userId }
                draft = text
                failure = ChatFailure(message: failed, retryText: text)
                focusTick += 1
            } else if cancelled {
                messages.removeAll { $0.id == userId }
                draft = text
                focusTick += 1
            }
        } else if let failed {
            failure = ChatFailure(message: failed, retryText: nil)
        }
        await loadConversations()
    }

    private func friendlyChatError(_ error: Error) -> String {
        if let clientError = error as? CompanionClientError {
            switch clientError {
            case let .badResponse(status, detail) where status == 412:
                return detail.isEmpty
                    ? "No reasoning provider is configured; set one in Settings." : detail
            case let .badResponse(status, detail):
                return detail.isEmpty ? "The companion answered HTTP \(status)." : detail
            case .unreachable:
                return "The companion is not reachable right now."
            }
        }
        return error.localizedDescription
    }

    private func update(_ id: String, _ change: (inout DisplayMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }
}

struct CompanionChatScreen: View {
    @Bindable var model: CompanionChatModel
    let home: CompanionHomeModel
    var isActive = true
    var openEpisode: (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Environment(\.companionGeneration) private var generation
    @FocusState private var composerFocused: Bool
    @State private var anchored = true

    private var dark: Bool { scheme == .dark }
    private var columnWidth: CGFloat { UIScale.pt(728) }

    var body: some View {
        HStack(spacing: UIScale.pt(0)) {
            if !compact {
                rail
                Divider().opacity(0.35)
            }
            thread
        }
        .task(id: generation) {
            if requestsEnabled {
                await model.loadConversations()
                await model.loadPersonas()
            }
        }
        .onAppear { if isActive { composerFocused = true } }
        .onChange(of: isActive) { _, active in
            if active { composerFocused = true } else { composerFocused = false }
        }
        .onChange(of: model.focusTick) { if isActive { composerFocused = true } }
    }

    private var rail: some View {
        VStack(spacing: UIScale.pt(6)) {
            Button {
                model.newChat()
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Image(systemName: "plus")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                    Text("New chat")
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                }
                .foregroundStyle(
                    model.streaming ? DashSkin.inkFaint(dark) : DashSkin.accent(dark)
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, UIScale.pt(7))
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(9))
                        .strokeBorder(DashSkin.line(dark), style: StrokeStyle(dash: [4, 3]))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(model.streaming || !isActive)
            .modifier(ActiveShortcut(active: isActive, key: "n", modifiers: .command))
            .help("Start a fresh conversation (⌘N)")
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    if !model.loaded, model.loadError == nil {
                        ListRowsSkeleton(rows: 5, showsLeadingDot: false, dark: dark)
                    } else if let loadError = model.loadError, model.conversations.isEmpty {
                        CompanionStatusLine(text: loadError, tone: .error)
                            .padding(.horizontal, UIScale.pt(10))
                            .padding(.top, UIScale.pt(8))
                    } else if model.conversations.isEmpty {
                        Text("Nothing yet. The first chat starts the record.")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .padding(.horizontal, UIScale.pt(10))
                            .padding(.top, UIScale.pt(8))
                    } else {
                        ForEach(bucketed, id: \.label) { bucket in
                            Text(bucket.label.uppercased())
                                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                                .tracking(UIScale.pt(0.8))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .padding(.horizontal, UIScale.pt(10))
                                .padding(.top, UIScale.pt(10))
                            ForEach(bucket.items) { conversation in
                                ConversationRow(
                                    conversation: conversation,
                                    active: conversation.id == model.activeConversationId,
                                    dark: dark,
                                    open: { Task { await model.open(conversation.id) } },
                                    delete: { Task { await model.delete(conversation.id) } })
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UIScale.pt(10))
        .frame(width: UIScale.pt(230))
    }

    private struct Bucket {
        let label: String
        let items: [CompanionConversation]
    }

    private var bucketed: [Bucket] {
        let calendar = Calendar.current
        let now = Date()
        var groups: [(String, [CompanionConversation])] = [
            ("Today", []), ("Yesterday", []), ("Previous 7 days", []),
            ("Previous 30 days", []), ("Older", []),
        ]
        let parser = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for conversation in model.conversations {
            let date =
                fractional.date(from: conversation.lastActiveAt)
                ?? parser.date(from: conversation.lastActiveAt) ?? now
            let index: Int
            if calendar.isDateInToday(date) {
                index = 0
            } else if calendar.isDateInYesterday(date) {
                index = 1
            } else if date > calendar.date(byAdding: .day, value: -7, to: now) ?? now {
                index = 2
            } else if date > calendar.date(byAdding: .day, value: -30, to: now) ?? now {
                index = 3
            } else {
                index = 4
            }
            groups[index].1.append(conversation)
        }
        return groups.filter { !$0.1.isEmpty }.map { Bucket(label: $0.0, items: $0.1) }
    }

    private var thread: some View {
        VStack(spacing: UIScale.pt(0)) {
            if model.messages.isEmpty {
                greeting
            } else {
                transcript
            }
            if let failure = model.failure {
                failureStrip(failure)
            }
            councilPanel
            personaBar
            composer
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(0)) {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) {
                        index, message in
                        if let divider = dayDivider(at: index) {
                            dayDividerView(divider)
                        }
                        messageView(message)
                            .padding(.top, messageTopPadding(at: index))
                    }
                    Color.clear.frame(height: UIScale.pt(1)).id("bottom")
                }
                .frame(maxWidth: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, PageMetrics.gutter(compact))
                .padding(.top, UIScale.pt(10))
                .padding(.bottom, UIScale.pt(16))
            }
            .defaultScrollAnchor(.bottom)
            .trackScrollAnchor($anchored)
            .overlay(alignment: .bottom) {
                if !anchored {
                    jumpToLatest {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: model.messages.last?.content) {
                guard anchored else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: model.messages.count) {
                guard anchored else { return }
                withAnimation(Motion.animation(Motion.glide, reduceMotion: reduceMotion)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func jumpToLatest(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(5)) {
                Image(systemName: "arrow.down")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                Text("Latest")
                    .font(.system(size: UIScale.pt(11), weight: .medium))
            }
            .foregroundStyle(DashSkin.ink(dark))
            .padding(.horizontal, UIScale.pt(11))
            .padding(.vertical, UIScale.pt(6))
            .background(DashSkin.paper2(dark), in: Capsule())
            .overlay { Capsule().strokeBorder(DashSkin.lineStrong(dark)) }
            .shadow(color: .black.opacity(0.25), radius: UIScale.pt(8), y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .padding(.bottom, UIScale.pt(10))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func dayDivider(at index: Int) -> String? {
        let formatter = CompanionChatDates.self
        guard let day = formatter.day(model.messages[index].createdAt) else { return nil }
        guard index > 0 else { return formatter.label(day) }
        let previous = formatter.day(model.messages[index - 1].createdAt)
        return previous == day ? nil : formatter.label(day)
    }

    private func dayDividerView(_ label: String) -> some View {
        HStack(spacing: UIScale.pt(10)) {
            Rectangle().fill(DashSkin.line(dark)).frame(height: 1)
            Text(label)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .fixedSize()
            Rectangle().fill(DashSkin.line(dark)).frame(height: 1)
        }
        .padding(.vertical, UIScale.pt(16))
    }

    private func messageTopPadding(at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let message = model.messages[index]
        let previous = model.messages[index - 1]
        return previous.role == message.role ? UIScale.pt(10) : UIScale.pt(22)
    }

    private var greeting: some View {
        VStack(spacing: UIScale.pt(12)) {
            Spacer()
            Text("What do you want to remember?")
                .font(DashSkin.serif(24, weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
            Text("It answers from your own notes, days and doings.")
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            WrapHStack(spacing: UIScale.pt(8), lineSpacing: UIScale.pt(8)) {
                ForEach(
                    ["How was my week?", "What am I avoiding?", "What did I write about last?"],
                    id: \.self
                ) { suggestion in
                    Button {
                        model.draft = suggestion
                        model.send()
                    } label: {
                        Text(suggestion)
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                            .padding(.horizontal, UIScale.pt(11))
                            .padding(.vertical, UIScale.pt(5))
                            .overlay {
                                Capsule().strokeBorder(DashSkin.line(dark))
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .frame(maxWidth: UIScale.pt(500))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func messageView(_ message: CompanionChatModel.DisplayMessage) -> some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: UIScale.pt(80))
                Text(message.content)
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(DashSkin.ink(dark))
                    .textSelection(.enabled)
                    .padding(.horizontal, UIScale.pt(13))
                    .padding(.vertical, UIScale.pt(8))
                    .background(
                        DashSkin.accent(dark).opacity(0.13),
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: UIScale.pt(14),
                            bottomLeadingRadius: UIScale.pt(14),
                            bottomTrailingRadius: UIScale.pt(4),
                            topTrailingRadius: UIScale.pt(14))
                    )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                Text(eyebrow(for: message))
                    .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                    .tracking(UIScale.pt(1.1))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                MarkdownBody(text: message.content, dark: dark, size: 13, bodyInk: true)
                if message.streaming {
                    StreamingCaret(dark: dark, waiting: message.content.isEmpty)
                }
                if message.stopped {
                    Text("stopped")
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                if !message.citations.isEmpty {
                    citationChips(message.citations)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func eyebrow(for message: CompanionChatModel.DisplayMessage) -> String {
        let model = (message.model ?? self.model.model).map { " · \($0)" } ?? ""
        return "COMPANION\(model)".uppercased()
    }

    private func citationChips(_ citations: [CompanionAskCitation]) -> some View {
        FlowChips(spacing: UIScale.pt(6)) {
            ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
                CitationChip(
                    index: index + 1, citation: citation, dark: dark, open: openEpisode)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func failureStrip(_ failure: CompanionChatModel.ChatFailure) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.warn)
            Text(failure.message)
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .lineLimit(2)
            Spacer(minLength: 0)
            if failure.retryText != nil {
                CompanionButton(title: "Retry", role: .primary) {
                    model.retry()
                }
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(8))
        .background(
            DashSkin.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: UIScale.pt(10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(10))
                .strokeBorder(DashSkin.warn.opacity(0.35))
        }
        .frame(maxWidth: columnWidth)
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.top, UIScale.pt(6))
    }

    private var personaBar: some View {
        HStack(spacing: UIScale.pt(6)) {
            WrapHStack(spacing: UIScale.pt(6), lineSpacing: UIScale.pt(6)) {
                personaChip(id: nil, label: "Default")
                ForEach(model.personas, id: \.id) { persona in
                    personaChip(id: persona.id, label: persona.label)
                }
            }
            Spacer(minLength: 0)
            CompanionLinkButton(
                title: model.councilRunning ? "Asking three lenses…" : "Second opinion",
                disabled: model.councilRunning || model.streaming
                    || model.councilSubject == nil,
                help: model.councilRunning
                    ? "Analyst, coach and skeptic are answering; this takes a minute"
                    : "Ask analyst, coach and skeptic at once about the typed or last question"
            ) {
                Task { await model.askCouncil() }
            }
        }
        .frame(maxWidth: columnWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.bottom, UIScale.pt(6))
    }

    private func personaChip(id: String?, label: String) -> some View {
        let selected = model.persona == id
        return Button {
            model.persona = id
        } label: {
            Text(label)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .padding(.horizontal, UIScale.pt(9))
                .padding(.vertical, UIScale.pt(4))
                .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkFaint(dark))
                .background {
                    if selected {
                        Capsule().fill(DashSkin.paper2(dark))
                    }
                }
                .overlay {
                    if selected {
                        Capsule().strokeBorder(DashSkin.lineStrong(dark))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var councilPanel: some View {
        if model.councilRunning, model.council == nil {
            HStack(spacing: UIScale.pt(8)) {
                ProgressView().controlSize(.small)
                Text(
                    "Analyst, coach and skeptic are each answering \"\(model.councilQuestion ?? "")\""
                )
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .lineLimit(2)
            }
            .padding(UIScale.pt(12))
            .frame(maxWidth: columnWidth, alignment: .leading)
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
            .padding(.horizontal, PageMetrics.gutter(compact))
            .padding(.bottom, UIScale.pt(8))
        } else if let council = model.council {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        ForEach(council.answers, id: \.persona) { answer in
                            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                Text(answer.label)
                                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                                    .foregroundStyle(DashSkin.ink(dark))
                                Text(answer.answer)
                                    .font(.system(size: UIScale.pt(12.5)))
                                    .foregroundStyle(DashSkin.inkSoft(dark))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxHeight: UIScale.pt(220))
                Divider().opacity(0.3)
                if !council.crux.isEmpty {
                    Text("the crux: \(council.crux)")
                        .font(.system(size: UIScale.pt(12.5), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                }
                if !council.cruxQuestion.isEmpty {
                    Text(council.cruxQuestion)
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                CompanionLinkButton(title: "Close") { model.dismissCouncil() }
            }
            .padding(UIScale.pt(12))
            .frame(maxWidth: columnWidth, alignment: .leading)
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
            .padding(.horizontal, PageMetrics.gutter(compact))
            .padding(.bottom, UIScale.pt(8))
        }
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: UIScale.pt(10)) {
            TextField("Talk to your memory…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .font(.system(size: UIScale.pt(13.5)))
                .foregroundStyle(DashSkin.ink(dark))
                .tint(DashSkin.accent(dark))
                .focused($composerFocused)
                .focusEffectDisabled()
                .onSubmit { model.send() }
                .help("Return sends; Option-Return starts a new line")
            sendOrStop
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(12))
        .background(
            DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14))
        )
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(14))
                .strokeBorder(
                    composerFocused ? DashSkin.accent(dark) : DashSkin.lineStrong(dark),
                    lineWidth: UIScale.pt(composerFocused ? 1.5 : 1))
        }
        .animation(.easeOut(duration: 0.12), value: composerFocused)
        .frame(maxWidth: columnWidth)
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.vertical, UIScale.pt(12))
    }

    @ViewBuilder
    private var sendOrStop: some View {
        if model.streaming {
            Button {
                model.stop()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: UIScale.pt(24)))
                    .foregroundStyle(DashSkin.accent(dark))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .modifier(ActiveEscapeShortcut(active: isActive))
            .help("Stop generating (Esc)")
        } else {
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: UIScale.pt(24)))
                    .foregroundStyle(
                        draftEmpty ? DashSkin.inkFaint(dark) : DashSkin.accent(dark))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(draftEmpty)
            .help("Send (Return)")
        }
    }

    private var draftEmpty: Bool {
        model.draft.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct ActiveShortcut: ViewModifier {
    let active: Bool
    let key: KeyEquivalent
    let modifiers: EventModifiers

    func body(content: Content) -> some View {
        if active {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }
}

struct ActiveEscapeShortcut: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.keyboardShortcut(.escape, modifiers: [])
        } else {
            content
        }
    }
}

enum CompanionChatDates {
    static func day(_ iso: String?) -> String? {
        guard let iso, iso.count >= 10 else { return nil }
        return String(iso.prefix(10))
    }

    static func label(_ day: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let output = DateFormatter()
        output.dateFormat = "MMMM d"
        return output.string(from: date)
    }
}

private struct StreamingCaret: View {
    let dark: Bool
    var waiting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: UIScale.pt(1))
            .fill(DashSkin.accent(dark))
            .frame(width: UIScale.pt(7), height: UIScale.pt(14))
            .opacity(dim ? 0.15 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: waiting ? 0.8 : 0.5).repeatForever()) {
                    dim = true
                }
            }
    }
}

extension View {
    @ViewBuilder
    fileprivate func trackScrollAnchor(_ anchored: Binding<Bool>) -> some View {
        if #available(macOS 15.0, *) {
            onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 100
            } action: { _, isAtBottom in
                if anchored.wrappedValue != isAtBottom {
                    withAnimation(.easeOut(duration: 0.15)) {
                        anchored.wrappedValue = isAtBottom
                    }
                }
            }
        } else {
            self
        }
    }
}

private struct CitationChip: View {
    let index: Int
    let citation: CompanionAskCitation
    let dark: Bool
    let open: (String) -> Void
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: UIScale.pt(4)) {
                Text("\(index)")
                    .font(.system(size: UIScale.pt(10), weight: .bold))
                    .foregroundStyle(DashSkin.accent(dark))
                Text(
                    "\(citation.title) · \(String(citation.occurredAt.prefix(10))) · \(supportLabel)"
                )
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
            }
            .padding(.horizontal, UIScale.pt(9))
            .padding(.vertical, UIScale.pt(3))
            .background(DashSkin.paper(dark), in: Capsule())
            .overlay { Capsule().strokeBorder(DashSkin.line(dark)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Preview this citation")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                Text(citation.title)
                    .font(DashSkin.serif(15, weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("\(String(citation.occurredAt.prefix(10))) · \(supportLabel)")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                if !citation.quote.isEmpty {
                    Text("\u{201C}\(citation.quote)\u{201D}")
                        .font(.system(size: UIScale.pt(12.5)))
                        .italic()
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                CompanionButton(title: "Open in Library") {
                    showing = false
                    open(citation.episodeId)
                }
                .padding(.top, UIScale.pt(2))
            }
            .padding(UIScale.pt(14))
            .frame(minWidth: UIScale.pt(240), maxWidth: UIScale.pt(360), alignment: .leading)
        }
    }

    private var supportLabel: String {
        citation.support == "inference" ? "between the lines" : citation.support
    }
}

private struct ConversationRow: View {
    let conversation: CompanionConversation
    let active: Bool
    let dark: Bool
    let open: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: UIScale.pt(4)) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                    Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                    Text(
                        "\(String(conversation.lastActiveAt.prefix(10))) · \(conversation.messageCount) messages"
                    )
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            if hovering {
                Button(action: delete) {
                    Image(systemName: "xmark")
                        .font(.system(size: UIScale.pt(9), weight: .bold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Delete conversation")
            }
        }
        .padding(.horizontal, UIScale.pt(10))
        .padding(.vertical, UIScale.pt(6))
        .background(
            active || hovering ? DashSkin.accent(dark).opacity(0.13) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(9))
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete conversation", role: .destructive, action: delete)
        }
    }
}

struct FlowChips<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        WrapHStack(spacing: spacing, lineSpacing: spacing) {
            content
        }
    }
}
