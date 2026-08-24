import EdithCore

public struct CompanionChatLibraryPlacement: Equatable, Sendable {
    public let surface: String
    public let action: String
    public let exampleArguments: [String]

    public init(surface: String, action: String, exampleArguments: [String]) {
        self.surface = surface
        self.action = action
        self.exampleArguments = exampleArguments
    }
}

public enum CompanionChatLibraryOperation: String, CaseIterable, Sendable {
    case chat
    case conversations
    case forget
    case search
    case episode
    case index

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: operationID), summary: summary, cli: cli,
            effect: effect, requiresPreview: self == .forget)
    }

    public var placements: [CompanionChatLibraryPlacement] {
        switch self {
        case .chat:
            [
                CompanionChatLibraryPlacement(
                    surface: "Companion chat", action: "send a chat message",
                    exampleArguments: ["how was my week"]),
                CompanionChatLibraryPlacement(
                    surface: "Companion chat", action: "continue a conversation",
                    exampleArguments: ["and then", "--conversation", "abc"]),
            ]
        case .conversations:
            [
                CompanionChatLibraryPlacement(
                    surface: "Companion chat", action: "list past conversations",
                    exampleArguments: [])
            ]
        case .forget:
            [
                CompanionChatLibraryPlacement(
                    surface: "Companion chat", action: "delete a conversation",
                    exampleArguments: ["abc", "--yes"])
            ]
        case .search:
            [
                CompanionChatLibraryPlacement(
                    surface: "Companion library", action: "search the memory",
                    exampleArguments: ["warden"])
            ]
        case .episode:
            [
                CompanionChatLibraryPlacement(
                    surface: "Companion library", action: "read a full episode",
                    exampleArguments: ["abc"])
            ]
        case .index:
            [
                CompanionChatLibraryPlacement(
                    surface: "Companion library", action: "index pending episodes",
                    exampleArguments: [])
            ]
        }
    }

    public var previewTargets: [String] {
        self == .forget ? ["the selected conversation", "every message in the conversation"] : []
    }

    private var operationID: String {
        switch self {
        case .chat: "companion.chat.send"
        case .conversations: "companion.conversation.list"
        case .forget: "companion.conversation.forget"
        case .search: "companion.library.search"
        case .episode: "companion.library.episode"
        case .index: "companion.library.index"
        }
    }

    private var cli: [String] {
        ["companion", rawValue]
    }

    private var summary: String {
        switch self {
        case .chat: "Send a message to a new or existing companion conversation."
        case .conversations: "List or read companion conversations."
        case .forget: "Delete a companion conversation and its messages."
        case .search: "Search indexed companion memory."
        case .episode: "Read a companion episode in full."
        case .index: "Index pending companion episodes."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .chat, .index: .write
        case .forget: .destructive
        case .conversations, .search, .episode: .read
        }
    }
}

public enum CompanionChatLibraryOperationExecution {
    public static func chat(
        message: String, conversationID: String?, persona: String?,
        using execute: (String, String?, String?) -> AsyncThrowingStream<CompanionChatEvent, Error>
    ) -> AsyncThrowingStream<CompanionChatEvent, Error> {
        execute(message, conversationID, persona)
    }

    public static func conversations(
        limit: Int,
        using execute: (Int) async throws -> [CompanionConversation]
    ) async rethrows -> [CompanionConversation] {
        try await execute(limit)
    }

    public static func conversation(
        id: String,
        using execute: (String) async throws -> CompanionConversationDetail
    ) async rethrows -> CompanionConversationDetail {
        try await execute(id)
    }

    public static func forget(
        id: String,
        using execute: (String) async throws -> CompanionDeletion
    ) async rethrows -> CompanionDeletion {
        try await execute(id)
    }

    public static func search(
        query: String, limit: Int,
        using execute: (String, Int) async throws -> [CompanionSearchHit]
    ) async rethrows -> [CompanionSearchHit] {
        try await execute(query, limit)
    }

    public static func episode(
        id: String,
        using execute: (String) async throws -> CompanionEpisodeDetail
    ) async rethrows -> CompanionEpisodeDetail {
        try await execute(id)
    }

    public static func index(
        using execute: () async throws -> CompanionIndexOutcome
    ) async rethrows -> CompanionIndexOutcome {
        try await execute()
    }
}

public enum CompanionChatLibraryOperationText {
    public static func forgot(_ deletion: CompanionDeletion) -> String {
        "forgot conversation \(deletion.deleted)"
    }

    public static func indexed(_ outcome: CompanionIndexOutcome) -> String {
        "indexed \(outcome.episodesIndexed) episodes into \(outcome.chunksCreated) chunks"
    }
}
