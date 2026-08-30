import AppKit
import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseSafetyReviewSheet: View {
    let preview: DatabaseDestructivePreview
    let phase: DatabaseSafetyReviewPhase
    let refreshPreview: () async -> Void
    let reconcile: () async -> Void
    let confirm: (String) -> Void
    let cancelOperation: () -> Void
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @FocusState private var confirmationFocused: Bool
    @State private var interaction: DatabaseSafetyReviewInteractionState
    @State private var presentation: DatabaseSafetyReviewPresentation

    init(
        preview: DatabaseDestructivePreview,
        phase: DatabaseSafetyReviewPhase,
        refreshPreview: @escaping () async -> Void,
        reconcile: @escaping () async -> Void,
        confirm: @escaping (String) -> Void,
        cancelOperation: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.preview = preview
        self.phase = phase
        self.refreshPreview = refreshPreview
        self.reconcile = reconcile
        self.confirm = confirm
        self.cancelOperation = cancelOperation
        self.dismiss = dismiss
        _interaction = State(initialValue: DatabaseSafetyReviewInteractionState(preview: preview))
        _presentation = State(initialValue: DatabaseSafetyReviewPresentation(preview: preview))
    }

    private var dark: Bool { scheme == .dark }
    private var activePhase: DatabaseSafetyReviewPhase {
        interaction.submissionLocked && phase == .ready ? .executing : phase
    }

    private var previewIsCurrent: Bool {
        interaction.previewIdentity == DatabaseSafetyPreviewIdentity(preview: preview)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    header(width: proxy.size.width)
                    Divider().opacity(0.45)
                    reviewContent(width: proxy.size.width)
                        .padding(UIScale.pt(20))
                    Divider().opacity(0.45)
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        confirmationFooter(width: proxy.size.width, now: timeline.date)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(
            minWidth: DatabaseSafetyReviewLayout.minimumSheetWidth, idealWidth: 780,
            minHeight: DatabaseSafetyReviewLayout.minimumSheetHeight, idealHeight: 720
        )
        .background(DashSkin.paper(dark))
        .interactiveDismissDisabled(activePhase.blocksInteractiveDismissal)
        .onAppear {
            announce("Destructive database operation requires review.")
        }
        .onChange(of: DatabaseSafetyPreviewIdentity(preview: preview)) { _, _ in
            if interaction.replacePreview(preview) {
                presentation = DatabaseSafetyReviewPresentation(preview: preview)
                confirmationFocused = false
                announce("The database operation preview changed. Review it again.")
            }
        }
        .onChange(of: phase) { _, newPhase in
            if case .failed = newPhase {
                interaction.finishSubmission()
            } else if case .accepted = newPhase {
                interaction.finishSubmission()
            } else if case .succeeded = newPhase {
                interaction.finishSubmission()
            } else if newPhase == .ready,
                interaction.submittedPreviewIdentity != interaction.previewIdentity
            {
                interaction.finishSubmission()
            }
            announcePhase(newPhase)
        }
    }

    @ViewBuilder
    private func header(width: CGFloat) -> some View {
        if DatabaseSafetyReviewLayout(width: Double(width), zoom: UIScale.current).usesWideHeader {
            HStack(alignment: .top, spacing: UIScale.pt(14)) {
                headerIdentity
                Spacer(minLength: UIScale.pt(12))
                headerBadges(alignment: .trailing)
            }
            .padding(.horizontal, UIScale.pt(20))
            .padding(.vertical, UIScale.pt(18))
        } else {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                headerIdentity
                headerBadges(alignment: .leading)
            }
            .padding(.horizontal, UIScale.pt(20))
            .padding(.vertical, UIScale.pt(18))
        }
    }

    private var headerIdentity: some View {
        let accent = riskColor(presentation.risk)
        return HStack(alignment: .top, spacing: UIScale.pt(14)) {
            Image(systemName: presentation.risk.symbol)
                .font(.system(size: UIScale.pt(24), weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: UIScale.pt(44), height: UIScale.pt(44))
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(presentation.actionTitle)
                    .font(DashSkin.serif(24, weight: .bold))
                    .foregroundStyle(DashSkin.ink(dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(headerContext)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(headerContext)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func headerBadges(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: UIScale.pt(7)) {
            DatabaseSafetyPill(
                title: presentation.risk.title,
                symbol: presentation.risk.symbol,
                accentColor: riskColor(presentation.risk),
                dark: dark)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let expired = timeline.date >= presentation.expiresAt
                DatabaseSafetyPill(
                    title: expirationTitle(now: timeline.date),
                    symbol: expired ? "clock.badge.xmark" : "clock.fill",
                    accentColor: expired ? DashSkin.danger : DashSkin.accent(dark),
                    dark: dark)
            }
        }
    }

    private var headerContext: String {
        let connection = presentation.connectionFacts.first { $0.id == "connection" }?.value ?? ""
        let target = presentation.connectionFacts.first { $0.id == "target" }?.value ?? ""
        return "\(connection) · \(target)"
    }

    private func reviewContent(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            if !presentation.warnings.isEmpty {
                warningsCard
            }
            DatabaseSafetyCard(title: "Execution context", symbol: "scope", dark: dark) {
                DatabaseSafetyFactsGrid(facts: presentation.connectionFacts, dark: dark)
            }
            if DatabaseSafetyReviewLayout(width: Double(width), zoom: UIScale.current)
                .usesPairedCards
            {
                HStack(alignment: .top, spacing: UIScale.pt(16)) {
                    selectionCard
                    impactCard
                }
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    selectionCard
                    impactCard
                }
            }
            DatabaseSafetyCard(
                title: "Transaction and recovery", symbol: "arrow.triangle.2.circlepath",
                dark: dark
            ) {
                DatabaseSafetyFactsGrid(facts: presentation.behaviorFacts, dark: dark)
            }
            requestCard
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var warningsCard: some View {
        DatabaseSafetyCard(
            title: "Warnings", symbol: "exclamationmark.triangle.fill", dark: dark,
            stroke: DashSkin.danger.opacity(0.42)
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                ForEach(presentation.warnings) { warning in
                    HStack(alignment: .top, spacing: UIScale.pt(9)) {
                        Image(systemName: warning.symbol)
                            .font(.system(size: UIScale.pt(13), weight: .semibold))
                            .foregroundStyle(warningColor(warning.severity))
                            .frame(width: UIScale.pt(18))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(warning.severityTitle)
                                .font(.system(size: UIScale.pt(11), weight: .semibold))
                                .foregroundStyle(DashSkin.ink(dark))
                            Text(warning.message)
                                .font(.system(size: UIScale.pt(12)))
                                .foregroundStyle(DashSkin.ink(dark))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(warning.severityTitle): \(warning.message)")
                }
            }
        }
    }

    private var selectionCard: some View {
        DatabaseSafetyCard(
            title: "Predicate or selection", symbol: "line.3.horizontal.decrease.circle", dark: dark
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Text(presentation.selectionTitle)
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(presentation.selectionDetail)
                    .font(DashSkin.mono(11))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var impactCard: some View {
        DatabaseSafetyCard(title: "Impact", symbol: "chart.bar.doc.horizontal", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Text(presentation.impactTitle)
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(presentation.impactDetail)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var requestCard: some View {
        DatabaseSafetyCard(
            title: "Generated request", symbol: "chevron.left.forwardslash.chevron.right",
            dark: dark
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                HStack(spacing: UIScale.pt(6)) {
                    Text(presentation.requestTitle)
                        .font(.system(size: UIScale.pt(11), weight: .semibold))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
                DatabaseSafetyCodeBlock(text: presentation.requestCommand, dark: dark)
                if let parameters = presentation.requestParameters {
                    DatabaseSafetyLabeledText(
                        label: "Parameters", text: parameters, monospaced: true, dark: dark)
                }
                if let body = presentation.requestBody {
                    DatabaseSafetyLabeledText(
                        label: "Request body", text: body, monospaced: true, dark: dark)
                }
            }
        }
    }

    private func confirmationFooter(width: CGFloat, now: Date) -> some View {
        let state = presentation.confirmationState(
            input: interaction.confirmationInput, now: now, phase: activePhase)
        return VStack(alignment: .leading, spacing: UIScale.pt(11)) {
            if case let .failed(message) = activePhase {
                DatabaseSafetyStatusLine(
                    text: DatabaseSafetyReviewPresentation.displayText(message, limit: 1_024),
                    symbol: "xmark.octagon.fill",
                    color: DashSkin.danger, dark: dark)
            } else if case let .outcomeUnknown(message) = activePhase {
                DatabaseSafetyStatusLine(
                    text: DatabaseSafetyReviewPresentation.displayText(message, limit: 1_024),
                    symbol: "questionmark.diamond.fill",
                    color: DashSkin.warn, dark: dark)
            } else if case let .accepted(message) = activePhase {
                DatabaseSafetyStatusLine(
                    text: DatabaseSafetyReviewPresentation.displayText(message, limit: 1_024),
                    symbol: "clock.badge.checkmark.fill",
                    color: DashSkin.warn, dark: dark)
            } else if case let .succeeded(message) = activePhase {
                DatabaseSafetyStatusLine(
                    text: DatabaseSafetyReviewPresentation.displayText(message, limit: 1_024),
                    symbol: "checkmark.circle.fill",
                    color: DashSkin.ok, dark: dark)
            }
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Text(presentation.confirmationInstruction)
                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: UIScale.pt(6)) {
                    ScrollView(.horizontal) {
                        Text(presentation.confirmationText)
                            .font(DashSkin.mono(11, weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.horizontal, UIScale.pt(9))
                            .padding(.vertical, UIScale.pt(7))
                    }
                    Button(action: copyConfirmation) {
                        Image(systemName: "doc.on.doc")
                            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy required confirmation text")
                    .help("Copy required confirmation text")
                }
                .background(
                    DashSkin.danger.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(8))
                        .strokeBorder(DashSkin.danger.opacity(0.28))
                }
                EdithTextField(
                    placeholder: "Exact confirmation text",
                    text: $interaction.confirmationInput,
                    invalid: state == .mismatch,
                    focus: $confirmationFocused,
                    onSubmit: { performConfirm(now: Date()) }
                )
                .accessibilityLabel("Exact confirmation text")
                .accessibilityValue(confirmationAccessibilityValue(state))
                .disabled(
                    state == .expired || state == .executing || state == .failed
                        || state == .outcomeUnknown || state == .completed)
            }
            if DatabaseSafetyReviewLayout(width: Double(width), zoom: UIScale.current)
                .usesInlineFooterActions
            {
                HStack(spacing: UIScale.pt(10)) {
                    confirmationStatus(state: state, now: now)
                    Spacer(minLength: UIScale.pt(12))
                    actionButtons(state: state)
                }
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    confirmationStatus(state: state, now: now)
                    actionButtons(state: state, fillsWidth: true)
                }
            }
        }
        .padding(.horizontal, UIScale.pt(20))
        .padding(.vertical, UIScale.pt(15))
        .background(DashSkin.paper2(dark))
    }

    private func confirmationStatus(
        state: DatabaseSafetyConfirmationState,
        now: Date
    ) -> some View {
        DatabaseSafetyStatusLine(
            text: confirmationStatusText(state, now: now),
            symbol: confirmationStatusSymbol(state),
            color: confirmationStatusColor(state),
            dark: dark)
    }

    @ViewBuilder
    private func actionButtons(
        state: DatabaseSafetyConfirmationState,
        fillsWidth: Bool = false
    ) -> some View {
        if fillsWidth {
            VStack(spacing: UIScale.pt(8)) {
                actionButtonContent(state: state, fillsWidth: true)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: UIScale.pt(8)) {
                actionButtonContent(state: state, fillsWidth: false)
            }
        }
    }

    @ViewBuilder
    private func actionButtonContent(
        state: DatabaseSafetyConfirmationState,
        fillsWidth: Bool
    ) -> some View {
        if activePhase.isAccepted {
            Button("Cancel mutation", action: cancelOperation)
                .buttonStyle(.edith(.secondary))
                .edithButtonTarget(.secondary)
            Button {
                Task { await reconcile() }
            } label: {
                Label("Check mutation status", systemImage: "arrow.clockwise")
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
            .buttonStyle(.edith(.primary, tint: DashSkin.warn))
            .edithButtonTarget(.primary)
        } else if state == .outcomeUnknown {
            Button("Cancel operation", action: cancelOperation)
                .buttonStyle(.edith(.secondary))
                .edithButtonTarget(.secondary)
            Button {
                Task { await reconcile() }
            } label: {
                Label("Check status", systemImage: "arrow.clockwise")
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
            .buttonStyle(.edith(.primary, tint: DashSkin.warn))
            .edithButtonTarget(.primary)
        } else if activePhase == .cancelling || activePhase == .reconciling {
            Button(action: {}) {
                HStack(spacing: UIScale.pt(6)) {
                    ProgressView()
                        .controlSize(.small)
                    Text(activePhase == .cancelling ? "Cancelling" : "Checking status")
                }
                .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
            .buttonStyle(.edith(.secondary))
            .edithButtonTarget(.secondary)
            .disabled(true)
        } else if state == .expired || state == .failed {
            Button("Cancel", action: dismiss)
                .buttonStyle(.edith(.secondary))
                .edithButtonTarget(.secondary)
                .keyboardShortcut(.cancelAction)
            Button {
                guard let requestID = interaction.beginRefresh() else { return }
                Task {
                    await refreshPreview()
                    interaction.finishRefresh(requestID)
                }
            } label: {
                Label("Create fresh preview", systemImage: "arrow.clockwise")
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
            .buttonStyle(.edith(.primary, tint: DashSkin.accent(dark)))
            .edithButtonTarget(.primary)
            .disabled(interaction.refreshLocked)
        } else if state == .completed {
            Button("Done", action: dismiss)
                .buttonStyle(
                    .edith(
                        .primary,
                        tint: activePhase.isAccepted ? DashSkin.warn : DashSkin.ok)
                )
                .edithButtonTarget(.primary)
                .keyboardShortcut(.defaultAction)
        } else {
            if activePhase == .executing {
                Button("Cancel operation", action: cancelOperation)
                    .buttonStyle(.edith(.secondary))
                    .edithButtonTarget(.secondary)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel", action: dismiss)
                    .buttonStyle(.edith(.secondary))
                    .edithButtonTarget(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            Button {
                performConfirm(now: Date())
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    if activePhase == .executing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(
                        activePhase == .executing
                            ? "Executing" : presentation.actionButtonTitle
                    )
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
            .buttonStyle(.edith(.destructive))
            .edithButtonTarget(.destructive)
            .disabled(
                !previewIsCurrent
                    || !presentation.canConfirm(
                        input: interaction.confirmationInput,
                        now: Date(),
                        phase: activePhase)
            )
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(
                "Runs the reviewed operation against the named connection and target")
        }
    }

    private func performConfirm(now: Date) {
        guard
            previewIsCurrent,
            presentation.canConfirm(
                input: interaction.confirmationInput,
                now: now,
                phase: activePhase),
            interaction.beginSubmission()
        else { return }
        confirm(interaction.confirmationInput)
    }

    private func copyConfirmation() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(presentation.confirmationText, forType: .string)
        announce("Required confirmation text copied.")
    }

    private func expirationTitle(now: Date) -> String {
        let seconds = presentation.remainingSeconds(at: now)
        return seconds == 0 ? "Preview expired" : "Expires in \(seconds)s"
    }

    private func confirmationStatusText(
        _ state: DatabaseSafetyConfirmationState,
        now: Date
    ) -> String {
        switch state {
        case .empty: expirationTitle(now: now)
        case .mismatch: "Exact text does not match"
        case .ready: "Confirmation matches"
        case .expired: "Preview expired. Generate a fresh preview."
        case .executing: "Operation is executing"
        case .outcomeUnknown: "Mutation outcome is unknown"
        case .failed: "This authorization cannot be reused"
        case .completed: activePhase.isAccepted ? "Mutation accepted" : "Operation completed"
        }
    }

    private func confirmationStatusSymbol(_ state: DatabaseSafetyConfirmationState) -> String {
        switch state {
        case .empty: "clock.fill"
        case .mismatch: "xmark.circle.fill"
        case .ready: "checkmark.circle.fill"
        case .expired: "clock.badge.xmark"
        case .executing: "bolt.circle.fill"
        case .outcomeUnknown: "questionmark.diamond.fill"
        case .failed: "lock.slash.fill"
        case .completed:
            activePhase.isAccepted ? "clock.badge.checkmark.fill" : "checkmark.seal.fill"
        }
    }

    private func confirmationStatusColor(_ state: DatabaseSafetyConfirmationState) -> Color {
        switch state {
        case .empty: DashSkin.inkFaint(dark)
        case .ready: DashSkin.ok
        case .completed: activePhase.isAccepted ? DashSkin.warn : DashSkin.ok
        case .executing: DashSkin.accent(dark)
        case .outcomeUnknown: DashSkin.warn
        case .mismatch, .expired, .failed: DashSkin.danger
        }
    }

    private func confirmationAccessibilityValue(
        _ state: DatabaseSafetyConfirmationState
    ) -> String {
        switch state {
        case .empty: "Empty"
        case .mismatch: "Does not match"
        case .ready: "Matches"
        case .expired: "Preview expired"
        case .executing: "Operation executing"
        case .outcomeUnknown: "Mutation outcome unknown"
        case .failed: "Authorization consumed"
        case .completed: activePhase.isAccepted ? "Mutation accepted" : "Operation completed"
        }
    }

    private func riskColor(_ risk: DatabaseSafetyRiskLevel) -> Color {
        switch risk {
        case .guarded: DashSkin.accent(dark)
        case .high: DashSkin.warn
        case .critical: DashSkin.danger
        }
    }

    private func warningColor(_ severity: DatabaseWarningSeverity) -> Color {
        switch severity {
        case .information: DashSkin.accent(dark)
        case .caution: DashSkin.warn
        case .high: DashSkin.danger
        }
    }

    private func announcePhase(_ phase: DatabaseSafetyReviewPhase) {
        switch phase {
        case .ready:
            break
        case .executing:
            announce("Database operation started.")
        case .cancelling:
            announce("Database operation cancellation requested.")
        case .reconciling:
            announce("Checking database operation status.")
        case let .outcomeUnknown(message):
            announce(
                "Database operation outcome is unknown. \(DatabaseSafetyReviewPresentation.displayText(message, limit: 512))"
            )
        case let .failed(message):
            announce(
                "Database operation failed. \(DatabaseSafetyReviewPresentation.displayText(message, limit: 512))"
            )
        case let .accepted(message):
            announce(
                "Database mutation accepted. \(DatabaseSafetyReviewPresentation.displayText(message, limit: 512))"
            )
        case let .succeeded(message):
            announce(
                "Database operation completed. \(DatabaseSafetyReviewPresentation.displayText(message, limit: 512))"
            )
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }
}

private struct DatabaseSafetyCard<Content: View>: View {
    let title: String
    let symbol: String
    let dark: Bool
    var stroke: Color?
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        symbol: String,
        dark: Bool,
        stroke: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.dark = dark
        self.stroke = stroke
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Label(title, systemImage: symbol)
                .font(DashSkin.serif(17))
                .foregroundStyle(DashSkin.ink(dark))
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(UIScale.pt(15))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .widgetBar(
            cornerRadius: 14,
            fill: DashSkin.paper2(dark),
            stroke: stroke ?? DashSkin.line(dark),
            shadow: .black.opacity(dark ? 0.22 : 0.04),
            shadowRadius: 8,
            shadowY: 4)
    }
}

private struct DatabaseSafetyFactsGrid: View {
    let facts: [DatabaseSafetyReviewFact]
    let dark: Bool

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: UIScale.pt(120)),
                    spacing: UIScale.pt(14),
                    alignment: .topLeading)
            ],
            alignment: .leading,
            spacing: UIScale.pt(12)
        ) {
            ForEach(facts) { fact in
                HStack(alignment: .top, spacing: UIScale.pt(8)) {
                    Image(systemName: fact.symbol)
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(16))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(fact.label)
                            .font(.system(size: UIScale.pt(10.5), weight: .medium))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                        Text(fact.value)
                            .font(.system(size: UIScale.pt(12), weight: .medium))
                            .foregroundStyle(DashSkin.ink(dark))
                            .fixedSize(horizontal: false, vertical: true)
                            .help(fact.value)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(fact.label): \(fact.value)")
            }
        }
    }
}

private struct DatabaseSafetyCodeBlock: View {
    let text: String
    let dark: Bool

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(DashSkin.mono(11))
                .foregroundStyle(DashSkin.ink(dark))
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
                .padding(UIScale.pt(11))
        }
        .frame(maxWidth: .infinity, minHeight: UIScale.pt(58), maxHeight: UIScale.pt(190))
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(9))
                .strokeBorder(DashSkin.line(dark))
        }
        .accessibilityLabel("Generated request")
        .accessibilityValue(text)
    }
}

private struct DatabaseSafetyLabeledText: View {
    let label: String
    let text: String
    let monospaced: Bool
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text(label)
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .foregroundStyle(DashSkin.inkSoft(dark))
            Text(text)
                .font(monospaced ? DashSkin.mono(10.5) : .system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(text)")
    }
}

private struct DatabaseSafetyPill: View {
    let title: String
    let symbol: String
    let accentColor: Color
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(5)) {
            Image(systemName: symbol)
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(DashSkin.ink(dark))
        }
        .font(.system(size: UIScale.pt(10.5), weight: .semibold))
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(5))
        .background(accentColor.opacity(0.1), in: Capsule())
        .overlay { Capsule().strokeBorder(accentColor.opacity(0.35)) }
        .accessibilityLabel(title)
    }
}

private struct DatabaseSafetyStatusLine: View {
    let text: String
    let symbol: String
    let color: Color
    let dark: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(6)) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
