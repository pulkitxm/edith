import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Edith
@testable import EdithDatabase

@Suite struct DatabaseSafetyReviewTests {
    private static let connectionID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "F34F9B50-1D07-4D62-97A1-99048B32E80E")!)
    private static let issuedAt = Date(timeIntervalSince1970: 2_000)

    @Test func rendersEveryRequiredSafetyFieldFromAuthorityPreview() async throws {
        let preview = try await Self.authorityPreview()
        let presentation = DatabaseSafetyReviewPresentation(preview: preview)
        let facts = Dictionary(
            uniqueKeysWithValues: presentation.connectionFacts.map { ($0.id, $0.value) })
        let behavior = Dictionary(
            uniqueKeysWithValues: presentation.behaviorFacts.map { ($0.id, $0.value) })

        #expect(presentation.actionTitle == "Review bulk deletion")
        #expect(presentation.actionButtonTitle == "Delete records")
        #expect(presentation.risk == .high)
        #expect(facts["connection"] == "\"Primary orders\"")
        #expect(facts["environment"] == "Production (\"customer-a\") · confirmation required")
        #expect(facts["context"] == "\"orders\"")
        #expect(facts["schema"] == "\"public\"")
        #expect(facts["target"] == "Table: \"orders\" / \"public\" / \"invoices\"")
        #expect(presentation.selectionTitle == "Predicate")
        #expect(presentation.selectionDetail.contains("\"state\" = \"cancelled\""))
        #expect(presentation.selectionDetail.contains("\"tenant_id\" = 9"))
        #expect(presentation.selectionDetail.contains("case sensitivity: product default"))
        #expect(presentation.impactTitle == "Estimated impact: 42")
        #expect(presentation.impactDetail == "About 42 matching invoices")
        #expect(behavior["transaction"] == "Transactional")
        #expect(behavior["rollback"] == "Available")
        #expect(behavior["execution"] == "Synchronous")
        #expect(presentation.requestTitle == "PostgreSQL SQL")
        #expect(presentation.requestCommand == "DELETE FROM invoices WHERE state = $1")
        #expect(presentation.requestParameters == "\"state\": string")
        #expect(
            presentation.warnings.first?.message
                == "This operation targets a production connection.")
        #expect(presentation.warnings.last?.message == "This changes production data.")
        #expect(
            presentation.confirmationInstruction
                == "Type the exact connection and target identity to authorize this operation.")
        #expect(
            presentation.confirmationText
                == "connection[14:Primary orders] target[table[6:orders|6:public|8:invoices]]")
    }

    @Test func requiresExactTextAndStopsExpiredOrTerminalPreviews() {
        let presentation = DatabaseSafetyReviewPresentation(preview: Self.preview())
        let correct = presentation.confirmationText
        let active = Self.issuedAt.addingTimeInterval(30)

        #expect(
            presentation.confirmationState(input: "", now: active, phase: .ready) == .empty)
        #expect(
            presentation.confirmationState(
                input: correct.uppercased(), now: active, phase: .ready) == .mismatch)
        #expect(
            presentation.confirmationState(
                input: " \(correct)", now: active, phase: .ready) == .mismatch)
        #expect(
            presentation.confirmationState(input: correct, now: active, phase: .ready) == .ready)
        #expect(presentation.canConfirm(input: correct, now: active, phase: .ready))
        #expect(
            presentation.confirmationState(
                input: correct, now: presentation.expiresAt, phase: .ready) == .expired)
        #expect(
            presentation.confirmationState(
                input: correct, now: active, phase: .executing) == .executing)
        #expect(
            presentation.confirmationState(
                input: correct, now: active, phase: .failed("rejected")) == .failed)
        #expect(
            presentation.confirmationState(
                input: correct, now: active, phase: .partiallyApplied("review changes"))
                == .partiallyApplied)
        #expect(
            presentation.confirmationState(
                input: correct, now: active, phase: .succeeded("done")) == .completed)
        #expect(!presentation.canConfirm(input: correct, now: active, phase: .failed("rejected")))
        let partialPhase = DatabaseSafetyReviewPhase.partiallyApplied("review changes")
        #expect(partialPhase.preservesUnresolvedOperation)
        #expect(partialPhase.blocksInteractiveDismissal)
        #expect(!partialPhase.allowsOperationCancellation)
        #expect(!partialPhase.allowsReconciliation)
    }

    @Test func freshTokenClearsConfirmationEvenWhenDisplayDigestMatches() throws {
        let first = Self.preview(token: "first.signature")
        let second = Self.preview(
            issuedAt: Self.issuedAt.addingTimeInterval(5),
            token: "second.signature")
        var state = DatabaseSafetyReviewInteractionState(preview: first)
        state.confirmationInput = "connection target"
        let firstRefreshCandidate = state.beginRefresh()
        let firstRefresh = try #require(firstRefreshCandidate)
        let submitted = state.beginSubmission()
        #expect(submitted)

        #expect(first.effect.displayDigest == second.effect.displayDigest)
        let replaced = state.replacePreview(second)
        #expect(replaced)
        #expect(state.confirmationInput.isEmpty)
        #expect(state.refreshLocked)
        #expect(state.submissionLocked)
        #expect(state.previewIdentity.token == second.token)
        let replacedAgain = state.replacePreview(second)
        #expect(!replacedAgain)
        state.finishRefresh(UUID())
        #expect(state.refreshLocked)
        state.finishRefresh(firstRefresh)
        #expect(!state.refreshLocked)
        let secondRefreshCandidate = state.beginRefresh()
        let secondRefresh = try #require(secondRefreshCandidate)
        state.finishRefresh(firstRefresh)
        #expect(state.refreshLocked)
        state.finishRefresh(secondRefresh)
        #expect(!state.refreshLocked)
        state.finishSubmission()
        #expect(!state.submissionLocked)
    }

    @Test func rendersEveryImpactAccuracyWithAndWithoutAValue() {
        let cases: [(DatabaseCountAccuracy, String)] = [
            (.unknown, "Unknown impact"),
            (.exact, "Exact impact"),
            (.estimated, "Estimated impact"),
            (.lowerBound, "Minimum impact"),
            (.upperBound, "Maximum impact"),
        ]

        for (accuracy, title) in cases {
            #expect(
                DatabaseSafetyReviewPresentation(
                    preview: Self.preview(count: .init(accuracy: accuracy))
                ).impactTitle == title)
            #expect(
                DatabaseSafetyReviewPresentation(
                    preview: Self.preview(count: .init(value: 42, accuracy: accuracy))
                ).impactTitle == "\(title): 42")
        }
    }

    @Test func marksUnrestrictedNonrollbackWorkAsCritical() {
        let preview = Self.preview(
            action: .truncate,
            scope: .entireObject,
            predicate: nil,
            transactionBehavior: .nontransactional,
            rollbackAvailability: .unavailable,
            executionMode: .asynchronous)
        let presentation = DatabaseSafetyReviewPresentation(preview: preview)

        #expect(presentation.risk == .critical)
        #expect(presentation.actionButtonTitle == "Truncate object")
        #expect(presentation.selectionTitle == "Entire object")
        #expect(presentation.selectionDetail.contains("No predicate limits this operation"))
        #expect(
            presentation.behaviorFacts.map(\.value)
                == ["Not transactional", "Unavailable", "Asynchronous"])
    }

    @Test func neutralizesHostileIdentifiersAndPreservesFilterSemantics() {
        let hostile = "scope / fake\nEnvironment: local\u{00AD}\u{202E}\u{FEFF}\u{E0001}"
        let preview = Self.preview(
            predicate: .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath([hostile, "state"]),
                    operation: .equal,
                    values: [.string("cancelled")],
                    caseSensitivity: .insensitive)),
            connectionName: hostile,
            environmentLabel: hostile,
            context: DatabaseMutationContext(kind: .database, value: hostile, schema: hostile),
            objectPath: ["orders", hostile, "invoices"],
            nativeIdentifier: hostile,
            parameterName: hostile,
            warningMessage: hostile)
        let presentation = DatabaseSafetyReviewPresentation(preview: preview)
        let rendered =
            presentation.connectionFacts.map(\.value).joined(separator: " ")
            + presentation.selectionDetail
            + (presentation.requestParameters ?? "")
            + presentation.warnings.map(\.message).joined(separator: " ")

        #expect(!rendered.contains("\n"))
        #expect(!rendered.unicodeScalars.contains("\u{202E}"))
        #expect(!rendered.unicodeScalars.contains("\u{00AD}"))
        #expect(!rendered.unicodeScalars.contains("\u{FEFF}"))
        #expect(!rendered.unicodeScalars.contains("\u{E0001}"))
        #expect(rendered.contains("\\n"))
        #expect(rendered.contains("\\u{00AD}"))
        #expect(rendered.contains("\\u{202E}"))
        #expect(rendered.contains("\\u{FEFF}"))
        #expect(rendered.contains("\\u{E0001}"))
        #expect(presentation.selectionDetail.contains("case sensitivity: insensitive"))
        #expect(presentation.connectionFacts.last?.value.contains("native identity") == true)
    }

    @Test func boundsMaximumPresentationWorkAndReflowsAtLargeScale() {
        let predicates = (0..<2_000).map { index in
            DatabaseFilter.predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath(["payload", "field-\(index)"]),
                    operation: .contains,
                    values: [.string(String(repeating: "x", count: 32))],
                    caseSensitivity: .sensitive))
        }
        let preview = Self.preview(
            predicate: .all(predicates),
            command: String(repeating: "x", count: 65_536),
            body: .object(
                (0..<1_000).map { index in
                    DatabaseObjectField(
                        name: "field-\(index)",
                        value: .string(String(repeating: "y", count: 64)))
                }))
        let clock = ContinuousClock()
        let start = clock.now
        let presentation = DatabaseSafetyReviewPresentation(preview: preview)
        let elapsed = start.duration(to: clock.now)
        let constrained = DatabaseSafetyReviewLayout(width: 320, zoom: 1.6)
        let wide = DatabaseSafetyReviewLayout(width: 1_400, zoom: 1)

        #expect(elapsed < .seconds(2))
        #expect(presentation.selectionDetail.count <= 4_096)
        #expect(presentation.requestCommand.count == 4_096)
        #expect((presentation.requestBody?.count ?? 0) <= 4_096)
        #expect(!constrained.usesWideHeader)
        #expect(!constrained.usesPairedCards)
        #expect(!constrained.usesInlineFooterActions)
        #expect(wide.usesWideHeader)
        #expect(wide.usesPairedCards)
        #expect(wide.usesInlineFooterActions)
        #expect(DatabaseSafetyReviewLayout.minimumSheetWidth == 320)
        #expect(DatabaseSafetyReviewLayout.minimumSheetHeight == 320)
    }

    @MainActor @Test func hostsScrollableSheetAndMaterializesSafetyControlsAtMinimumSize() throws {
        _ = NSApplication.shared
        let preview = Self.preview(
            confirmationText: String(repeating: "required-confirmation-", count: 160))
        let sheet = DatabaseSafetyReviewSheet(
            preview: preview,
            phase: .ready,
            refreshPreview: {},
            reconcile: {},
            confirm: { _ in },
            cancelOperation: {},
            dismiss: {})
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let descendants = Self.descendantViews(of: host)
        let scrollViews = descendants.compactMap { $0 as? NSScrollView }
        let controls = descendants.compactMap { $0 as? NSControl }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)

        #expect(bitmap.pixelsWide >= 320)
        #expect(bitmap.pixelsHigh >= 320)
        #expect(bitmap.pixelsWide == bitmap.pixelsHigh)
        #expect(scrollViews.count >= 3)
        #expect(controls.count >= 3)
    }

    @Test func partiallyAppliedSheetExposesTheAcknowledgementActionPresentation() throws {
        let partialPhase = DatabaseSafetyReviewPhase.partiallyApplied(
            "Review the changed records.")
        let acknowledgement = try #require(
            DatabaseSafetyReviewSheet.acknowledgementAction(for: partialPhase))

        #expect(acknowledgement.title == "Acknowledge partial result")
        #expect(
            acknowledgement.accessibilityHint
                == "Clears mutation tracking only after you have reviewed the partially applied database changes"
        )
        #expect(acknowledgement.isEnabled)
        #expect(DatabaseSafetyReviewSheet.acknowledgementAction(for: .ready) == nil)
    }

    @MainActor
    private static func descendantViews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendantViews(of: $0) }
    }

    private static func authorityPreview() async throws -> DatabaseDestructivePreview {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = try SQLiteDatabaseMetadataStore(
            path: directory.appendingPathComponent("metadata.sqlite").path)
        let connection = try connection()
        try await metadata.seedConnection(connection)
        let owner = try await DatabaseRuntimeOwnerFactory.claimReadyOwner(
            from: metadata,
            claimedAt: issuedAt)
        let authority = try DatabaseConfirmationAuthority(
            signingKey: Data(repeating: 7, count: 32),
            metadataStore: metadata,
            secretStore: InMemoryDatabaseSecretStore(),
            runtimeOwner: owner.owner.token,
            currentDate: { issuedAt })
        let target = target()
        let predicate = DatabaseFilter.all([
            .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("state"),
                    operation: .equal,
                    values: [.string("cancelled")])),
            .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("tenant_id"),
                    operation: .equal,
                    values: [.signedInteger(9)])),
        ])
        let plan = DatabaseDestructivePlan(
            request: DatabaseDestructiveRequest(
                target: target,
                predicate: predicate,
                payload: .relational(
                    product: .postgresql,
                    statement: "DELETE FROM invoices WHERE state = $1",
                    parameters: [
                        DatabaseMutationParameter(name: "state", value: .string("cancelled"))
                    ])),
            action: .deleteMany,
            scope: .predicate,
            impact: DatabaseMutationImpact(
                count: .init(value: 42, accuracy: .estimated),
                description: "About 42 matching invoices"),
            transactionBehavior: .transactional,
            rollbackAvailability: .available,
            executionMode: .synchronous,
            warnings: [
                DatabaseWarning(
                    code: "production",
                    message: "This changes production data.",
                    severity: .high,
                    target: target)
            ])
        return try await authority.issuePreview(for: plan)
    }

    private static func connection() throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: connectionID,
            displayName: "Primary orders",
            productHint: .postgresql,
            location: .network([
                DatabaseNetworkEndpoint(host: "127.0.0.1", port: try DatabasePort(5_432))
            ]),
            username: "edith",
            namespaces: DatabaseNamespaceDefaults(schema: "public", database: "orders"),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(kind: .none),
            tls: DatabaseTLSConfiguration(mode: .disabled, verification: .none),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                poolSize: try DatabasePoolSize(4)),
            productionPolicy: .requireMutationPreview,
            environment: DatabaseEnvironmentMetadata(
                kind: .production,
                label: "customer-a",
                protection: .confirmationRequired),
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_500))
    }

    private static func target(
        objectPath: [String] = ["orders", "public", "invoices"],
        nativeIdentifier: String? = nil
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(
                kind: .table,
                path: objectPath,
                nativeIdentifier: nativeIdentifier))
    }

    private static func preview(
        action: DatabaseDestructiveAction = .deleteMany,
        scope: DatabaseMutationScope = .predicate,
        predicate: DatabaseFilter? = .predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("state"),
                operation: .equal,
                values: [.string("cancelled")])),
        count: DatabaseCountMetadata = .init(value: 42, accuracy: .estimated),
        transactionBehavior: DatabaseTransactionBehavior = .transactional,
        rollbackAvailability: DatabaseRollbackAvailability = .available,
        executionMode: DatabaseExecutionMode = .synchronous,
        command: String = "DELETE FROM invoices WHERE state = $1",
        body: DatabaseValue? = nil,
        issuedAt: Date = issuedAt,
        token: String = "payload.signature",
        connectionName: String = "Primary orders",
        environmentLabel: String = "production",
        context: DatabaseMutationContext = DatabaseMutationContext(
            kind: .database,
            value: "orders",
            schema: "public"),
        objectPath: [String] = ["orders", "public", "invoices"],
        nativeIdentifier: String? = nil,
        parameterName: String = "state",
        warningMessage: String = "This changes production data.",
        confirmationText: String = "connection target"
    ) -> DatabaseDestructivePreview {
        let target = target(objectPath: objectPath, nativeIdentifier: nativeIdentifier)
        let connection = DatabaseConnectionIdentity(
            id: connectionID,
            displayName: connectionName,
            productHint: .postgresql,
            environment: DatabaseEnvironmentMetadata(
                kind: .production,
                label: environmentLabel,
                protection: .confirmationRequired))
        let effect = DatabaseDestructiveEffect(
            action: action,
            connection: connection,
            context: context,
            target: target,
            selectedRecords: [],
            predicate: predicate,
            scope: scope,
            impact: DatabaseMutationImpact(
                count: count,
                description: "About 42 matching invoices"),
            transactionBehavior: transactionBehavior,
            rollbackAvailability: rollbackAvailability,
            executionMode: executionMode,
            executionDigest: "execution-digest",
            displayDigest: "display-digest")
        let request = DatabaseMutationPreview(
            product: .postgresql,
            kind: .sql,
            command: command,
            parameters: [
                DatabaseMutationParameterPreview(name: parameterName, valueKind: .string)
            ],
            body: body)
        return DatabaseDestructivePreview(
            effect: effect,
            request: request,
            warnings: [
                DatabaseWarning(
                    code: "production",
                    message: warningMessage,
                    severity: .high,
                    target: target)
            ],
            requiredConfirmation: DatabaseRequiredConfirmation(
                strength: .connectionAndTarget,
                text: confirmationText),
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(60),
            token: DatabaseConfirmationToken(rawValue: token))
    }
}
