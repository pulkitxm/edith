import Testing

@testable import EdithKit

@Suite struct CompanionChatLibraryOperationTests {
    @Test func everyOperationHasAUniqueCatalogEntryAndExactPlacement() {
        let operations = CompanionChatLibraryOperation.allCases
        let descriptors = operations.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == operations.count)
        #expect(Set(descriptors.map(\.cli)).count == operations.count)
        for operation in operations {
            #expect(
                UserOperationCatalog.descriptor(id: operation.descriptor.id) == operation.descriptor
            )
            #expect(
                UserOperationCatalog.descriptor(cli: operation.descriptor.cli)
                    == operation.descriptor)
            #expect(!operation.placements.isEmpty)
        }
    }

    @Test func chatPlacementsAreExactCompleteInvocations() {
        let operation = CompanionChatLibraryOperation.chat
        let invocations = operation.placements.map {
            operation.descriptor.cli + $0.exampleArguments
        }
        #expect(
            invocations
                == [
                    ["companion", "chat", "how was my week"],
                    ["companion", "chat", "and then", "--conversation", "abc"],
                ])
        #expect(operation.placements.map(\.surface) == ["Companion chat", "Companion chat"])
        #expect(
            operation.placements.map(\.action)
                == ["send a chat message", "continue a conversation"])
    }

    @Test func libraryPlacementsDoNotClaimTheMediaOpenVariant() {
        let operation = CompanionChatLibraryOperation.episode
        let invocations = operation.placements.map {
            operation.descriptor.cli + $0.exampleArguments
        }
        #expect(invocations == [["companion", "episode", "abc"]])
        #expect(!invocations.contains(["companion", "episode", "abc", "--open"]))
    }

    @Test func onlyForgetRequiresADestructivePreview() {
        for operation in CompanionChatLibraryOperation.allCases {
            if operation == .forget {
                #expect(operation.descriptor.effect == .destructive)
                #expect(operation.descriptor.requiresPreview)
                #expect(operation.previewTargets.count == 2)
            } else {
                #expect(!operation.descriptor.requiresPreview)
                #expect(operation.previewTargets.isEmpty)
            }
        }
    }

    @Test func executorCarriesArgumentsAndResultsAcrossEveryOperation() async throws {
        let conversation = CompanionConversation(
            id: "conversation-1", title: "A week", createdAt: "2026-08-01",
            lastActiveAt: "2026-08-02", messageCount: 2, lastMessage: "done")
        let message = CompanionMessage(
            id: "message-1", role: "assistant", content: "answer", citations: [],
            model: "reasoner", latencyMs: 12, createdAt: "2026-08-02")
        let detail = CompanionConversationDetail(
            id: conversation.id, title: conversation.title, createdAt: conversation.createdAt,
            messages: [message])
        let hit = CompanionSearchHit(
            chunkId: "chunk-1", episodeId: "episode-1", ord: 0, title: "Launch",
            occurredAt: "2026-08-03", kind: "markdown", snippet: "launch plan", score: 0.8)
        let episode = CompanionEpisodeDetail(
            id: "episode-1", occurredAt: "2026-08-03", ingestedAt: "2026-08-03",
            kind: "markdown", title: "Launch", body: "plan", bodyEn: nil, langs: ["en"],
            durationS: nil, mediaRef: nil, sha256: "hash", bytes: 4, chunks: 1)

        let conversations = await CompanionChatLibraryOperationExecution.conversations(
            limit: 7
        ) { limit in
            #expect(limit == 7)
            return [conversation]
        }
        #expect(conversations == [conversation])

        let loaded = await CompanionChatLibraryOperationExecution.conversation(
            id: conversation.id
        ) { id in
            #expect(id == conversation.id)
            return detail
        }
        #expect(loaded == detail)

        let deletion = await CompanionChatLibraryOperationExecution.forget(
            id: conversation.id
        ) { id in
            #expect(id == conversation.id)
            return CompanionDeletion(deleted: id)
        }
        #expect(deletion.deleted == conversation.id)

        let hits = await CompanionChatLibraryOperationExecution.search(
            query: "launch", limit: 12
        ) { query, limit in
            #expect(query == "launch")
            #expect(limit == 12)
            return [hit]
        }
        #expect(hits == [hit])

        let loadedEpisode = await CompanionChatLibraryOperationExecution.episode(
            id: episode.id
        ) { id in
            #expect(id == episode.id)
            return episode
        }
        #expect(loadedEpisode == episode)

        let outcome = await CompanionChatLibraryOperationExecution.index {
            CompanionIndexOutcome(episodesIndexed: 3, chunksCreated: 8)
        }
        #expect(outcome == CompanionIndexOutcome(episodesIndexed: 3, chunksCreated: 8))
    }

    @Test func chatExecutorPreservesConversationAndPersona() async throws {
        let stream = CompanionChatLibraryOperationExecution.chat(
            message: "and then", conversationID: "conversation-1", persona: "analyst"
        ) { message, conversationID, persona in
            #expect(message == "and then")
            #expect(conversationID == "conversation-1")
            #expect(persona == "analyst")
            return AsyncThrowingStream { continuation in
                continuation.yield(.delta("answer"))
                continuation.finish()
            }
        }
        var events: [CompanionChatEvent] = []
        for try await event in stream {
            events.append(event)
        }
        #expect(events == [.delta("answer")])
    }

    @Test func sharedTextMatchesThePlainCLIContract() {
        #expect(
            CompanionChatLibraryOperationText.forgot(
                CompanionDeletion(deleted: "conversation-1"))
                == "forgot conversation conversation-1")
        #expect(
            CompanionChatLibraryOperationText.indexed(
                CompanionIndexOutcome(episodesIndexed: 3, chunksCreated: 8))
                == "indexed 3 episodes into 8 chunks")
    }
}
