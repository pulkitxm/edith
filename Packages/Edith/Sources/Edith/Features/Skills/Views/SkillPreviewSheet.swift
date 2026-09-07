import EdithKit
import SwiftUI

struct SkillPreviewSheet: View {
    let skill: EdithSkill
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var document: SkillDocument?
    @State private var error: String?
    @State private var mode = Mode.preview
    @State private var copied = false
    @State private var refreshID = UUID()

    init(skill: EdithSkill) {
        self.skill = skill
        _document = State(initialValue: SkillDocumentStore.shared.cachedDocument(for: skill))
    }

    private enum Mode: String, CaseIterable {
        case preview = "Preview"
        case markdown = "Markdown"
    }

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(14)) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit()
                    .frame(width: UIScale.pt(44), height: UIScale.pt(44))
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(skill.name)
                        .font(.system(size: UIScale.pt(20), weight: .semibold))
                    Text("SKILL.md")
                        .font(.system(size: UIScale.pt(11), design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close preview")
                .keyboardShortcut(.cancelAction)
            }
            .padding(UIScale.pt(24))
            HStack {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: UIScale.pt(210))
                Spacer()
                if mode == .markdown {
                    Label("Read-only", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    guard let document else { return }
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(document.markdown, forType: .string)
                } label: {
                    Label(
                        copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                }
                .disabled(document == nil)
                .help("Copy the complete skill Markdown, including its metadata")
            }
            .padding(.horizontal, UIScale.pt(24))
            .padding(.bottom, UIScale.pt(16))
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: UIScale.pt(740), height: UIScale.pt(650))
        .task(id: refreshID) {
            guard document == nil else { return }
            error = nil
            copied = false
            do {
                document = try await SkillDocumentStore.shared.load(skill)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let document {
            if mode == .preview {
                ScrollView {
                    MarkdownBody(
                        text: document.body, dark: dark, size: 13, bodyInk: true,
                        documentStyle: true
                    )
                    .frame(maxWidth: UIScale.pt(620), alignment: .leading)
                    .padding(UIScale.pt(32))
                    .frame(maxWidth: .infinity)
                }
            } else {
                CodePreview(
                    text: document.markdown, language: "markdown", truncated: false, dark: dark
                )
                .id(document.markdown)
                .padding(UIScale.pt(12))
                .accessibilityLabel("Read-only skill Markdown")
            }
        } else if let error {
            VStack(spacing: UIScale.pt(12)) {
                Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.secondary)
                Text(error).multilineTextAlignment(.center)
                    .font(.callout).frame(maxWidth: UIScale.pt(380))
                Button("Try again") { refreshID = UUID() }
            }
        } else {
            SkeletonGroup {
                VStack(alignment: .leading, spacing: UIScale.pt(24)) {
                    SkeletonBlock(width: 280, height: 24)
                    skeletonParagraph
                    SkeletonBlock(width: 210, height: 18)
                    skeletonParagraph
                    SkeletonBlock(height: 80, corner: 10)
                    skeletonParagraph
                    Spacer(minLength: 0)
                }
                .padding(UIScale.pt(32))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading skill")
        }
    }

    private var skeletonParagraph: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            SkeletonBlock(height: 12)
            SkeletonBlock(height: 12)
            SkeletonBlock(width: 390, height: 12)
        }
    }
}
