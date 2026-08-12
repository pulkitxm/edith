import EdithKit
import SwiftUI

@MainActor
final class CompanionChatModel: ObservableObject {
    struct DisplayMessage: Identifiable, Equatable {
        let id: String
        let role: String
        var content: String
        var citations: [CompanionAskCitation]
        var streaming: Bool
    }

    @Published private(set) var conversations: [CompanionConversation] = []
    @Published private(set) var messages: [DisplayMessage] = []
    @Published private(set) var activeConversationId: String?
    @Published var draft = ""
    @Published private(set) var streaming = false
    @Published private(set) var model: String?
    @Published private(set) var error: String?
    @Published private(set) var loaded = false
    @Published private(set) var personas: [CompanionPersona] = []
    @Published var persona: String?
    @Published private(set) var council: CompanionCouncil?
    @Published private(set) var councilRunning = false
    @Published private(set) var councilQuestion: String?

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    func loadPersonas() async {
        personas = (try? await client.personas()) ?? []
    }

    func askCouncil() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !councilRunning, !streaming else { return }
        guard !text.isEmpty else {
            error = "Type the question first, then ask for a second opinion."
            return
        }
        councilRunning = true
        councilQuestion = text
        defer { councilRunning = false }
        do {
            let outcome = try await client.council(question: text, personas: [])
            council = outcome
            draft = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
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
        } catch {
            if !loaded { self.error = error.localizedDescription }
        }
    }

    func open(_ id: String) async {
        activeConversationId = id
        do {
            let detail = try await client.conversation(id: id)
            messages = detail.messages.map {
                DisplayMessage(
                    id: $0.id, role: $0.role, content: $0.content,
                    citations: $0.citations ?? [], streaming: false)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func newChat() {
        guard !streaming else { return }
        activeConversationId = nil
        messages = []
    }

    func delete(_ id: String) async {
        _ = try? await client.deleteConversation(id: id)
        if activeConversationId == id { newChat() }
        await loadConversations()
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streaming else { return }
        draft = ""
        streaming = true
        error = nil
        defer { streaming = false }
        messages.append(
            DisplayMessage(
                id: "local-\(UUID().uuidString)", role: "user", content: text,
                citations: [], streaming: false))
        let replyId = "reply-\(UUID().uuidString)"
        messages.append(
            DisplayMessage(
                id: replyId, role: "assistant", content: "", citations: [], streaming: true))
        do {
            for try await event in client.chat(
                message: text, conversationId: activeConversationId, persona: persona)
            {
                switch event {
                case let .meta(conversationId, model):
                    activeConversationId = conversationId
                    self.model = model
                case let .delta(delta):
                    update(replyId) { $0.content += delta }
                case let .citations(citations):
                    update(replyId) { $0.citations = citations }
                case .done:
                    update(replyId) { $0.streaming = false }
                case let .failure(message):
                    error = message
                    update(replyId) { $0.streaming = false }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        update(replyId) { $0.streaming = false }
        if let index = messages.firstIndex(where: { $0.id == replyId }),
            messages[index].content.isEmpty
        {
            messages.remove(at: index)
        }
        await loadConversations()
    }

    private func update(_ id: String, _ change: (inout DisplayMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }
}

struct CompanionChatScreen: View {
    @ObservedObject var model: CompanionChatModel
    @ObservedObject var home: CompanionHomeModel
    var openEpisode: (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @State private var caretDim = false
    @FocusState private var composerFocused: Bool

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: UIScale.pt(0)) {
            if !compact {
                rail
                Divider().opacity(0.35)
            }
            thread
        }
        .task {
            if requestsEnabled {
                await model.loadConversations()
                await model.loadPersonas()
            }
        }
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
                .foregroundStyle(DashSkin.accent(dark))
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
            ScrollView {
                VStack(spacing: UIScale.pt(4)) {
                    ForEach(model.conversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            active: conversation.id == model.activeConversationId,
                            dark: dark,
                            open: { Task { await model.open(conversation.id) } },
                            delete: { Task { await model.delete(conversation.id) } })
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UIScale.pt(10))
        .frame(width: UIScale.pt(210))
    }

    private var thread: some View {
        VStack(spacing: UIScale.pt(0)) {
            if model.messages.isEmpty {
                greeting
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                            ForEach(model.messages) { message in
                                messageView(message)
                            }
                            Color.clear.frame(height: UIScale.pt(1)).id("bottom")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PageMetrics.gutter(compact))
                        .padding(.top, UIScale.pt(10))
                    }
                    .onChange(of: model.messages.last?.content) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: model.messages.count) {
                        withAnimation(Motion.animation(Motion.glide, reduceMotion: reduceMotion)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            if let error = model.error {
                Text(error)
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PageMetrics.gutter(compact))
                    .padding(.top, UIScale.pt(6))
            }
            councilPanel
            personaBar
            composer
        }
    }

    private var greeting: some View {
        VStack(spacing: UIScale.pt(12)) {
            Spacer()
            Text("What do you want to remember?")
                .font(DashSkin.serif(UIScale.pt(22), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
            HStack(spacing: UIScale.pt(8)) {
                ForEach(
                    ["How was my week?", "What am I avoiding?", "What did I write about last?"],
                    id: \.self
                ) { suggestion in
                    Button {
                        model.draft = suggestion
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
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func messageView(_ message: CompanionChatModel.DisplayMessage) -> some View {
        if message.role == "user" {
            Text(message.content)
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(DashSkin.ink(dark))
                .textSelection(.enabled)
                .padding(.horizontal, UIScale.pt(12))
                .padding(.vertical, UIScale.pt(8))
                .background(
                    DashSkin.accent(dark).opacity(0.13),
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: UIScale.pt(14), bottomLeadingRadius: UIScale.pt(14),
                        bottomTrailingRadius: UIScale.pt(4), topTrailingRadius: UIScale.pt(14))
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                Text(assistantEyebrow)
                    .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(DashSkin.inkFaint(dark))
                MarkdownBody(text: message.content, dark: dark, size: 13, bodyInk: true)
                if message.streaming {
                    RoundedRectangle(cornerRadius: UIScale.pt(1))
                        .fill(DashSkin.accent(dark))
                        .frame(width: UIScale.pt(7), height: UIScale.pt(14))
                        .opacity(caretDim ? 0.15 : 1)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                                caretDim = true
                            }
                        }
                }
                if !message.citations.isEmpty {
                    citationChips(message.citations)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var assistantEyebrow: String {
        let model = model.model.map { " · \($0)" } ?? ""
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

    private var personaBar: some View {
        HStack(spacing: UIScale.pt(6)) {
            personaChip(id: nil, label: "Default")
            ForEach(model.personas, id: \.id) { persona in
                personaChip(id: persona.id, label: persona.label)
            }
            Spacer(minLength: 0)
            Button(model.councilRunning ? "Asking three lenses…" : "Second opinion") {
                Task { await model.askCouncil() }
            }
            .buttonStyle(.plain)
            .font(.system(size: UIScale.pt(11.5), weight: .medium))
            .foregroundStyle(
                model.councilRunning ? DashSkin.inkFaint(dark) : DashSkin.accent(dark)
            )
            .pointerCursor()
            .disabled(model.councilRunning || model.streaming)
            .help(
                model.councilRunning
                    ? "Analyst, coach and skeptic are answering; this takes a minute"
                    : "Type a question, then ask analyst, coach and skeptic at once")
        }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
            .padding(.horizontal, PageMetrics.gutter(compact))
            .padding(.bottom, UIScale.pt(8))
        } else if let council = model.council {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                ForEach(council.answers, id: \.persona) { answer in
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(answer.label)
                            .font(.system(size: UIScale.pt(12), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                        Text(answer.answer)
                            .font(.system(size: UIScale.pt(12.5)))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                    }
                }
                Divider().opacity(0.3)
                Text("the crux: \(council.crux)")
                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                if !council.cruxQuestion.isEmpty {
                    Text(council.cruxQuestion)
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                Button("Close") { model.dismissCouncil() }
                    .buttonStyle(.plain)
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.accent(dark))
                    .pointerCursor()
            }
            .padding(UIScale.pt(12))
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
            .padding(.horizontal, PageMetrics.gutter(compact))
            .padding(.bottom, UIScale.pt(8))
        }
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: UIScale.pt(10)) {
            Image(systemName: "bubble.left")
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            TextField("Talk to your memory…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: UIScale.pt(13.5)))
                .foregroundStyle(DashSkin.ink(dark))
                .tint(DashSkin.accent(dark))
                .focused($composerFocused)
                .focusEffectDisabled()
                .onSubmit { Task { await model.send() } }
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: UIScale.pt(24)))
                    .foregroundStyle(
                        model.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.streaming
                            ? DashSkin.inkFaint(dark) : DashSkin.accent(dark))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(model.streaming)
            .help("Send")
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
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.vertical, UIScale.pt(12))
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
                    .font(DashSkin.serif(UIScale.pt(15), weight: .semibold))
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
                Button("Open in Library") {
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
        Button(action: open) {
            HStack(spacing: UIScale.pt(4)) {
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
                Spacer(minLength: 0)
                if hovering {
                    Button(action: delete) {
                        Image(systemName: "xmark")
                            .font(.system(size: UIScale.pt(9), weight: .bold))
                            .foregroundStyle(DashSkin.inkFaint(dark))
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
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
        HStack(spacing: spacing) {
            content
        }
    }
}
