import EdithDatabase
import EdithKit
import SwiftUI

@MainActor
@Observable
final class DatabasePackInstallModel {
    private(set) var fraction = 0.0
    private(set) var message = "Checking the database pack."
    private(set) var finished = false
    private(set) var failure: String?
    private let install:
        @Sendable (@escaping @Sendable (Double) -> Void) async throws -> DatabasePackInspection

    init(
        install:
            @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws ->
            DatabasePackInspection = { progress in
                try await DatabasePackInstaller.live(progress: progress).install()
            }
    ) {
        self.install = install
    }

    func run() async {
        do {
            let inspection = try await install { fraction in
                Task { @MainActor in
                    self.fraction = fraction
                    self.message = "Downloading the signed database pack."
                }
            }
            fraction = 1
            message =
                inspection.state == .current
                ? "The database pack matches this version."
                : "The database pack is ready."
            finished = true
        } catch is CancellationError {
            failure = "The database pack download was cancelled."
        } catch {
            failure = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        guard let pack = error as? DatabasePackInstallError else {
            return "The database pack could not be installed."
        }
        switch pack {
        case .checksumMismatch:
            return "The database pack checksum did not match the published digest."
        case .signatureRejected:
            return "The database pack signature was rejected."
        case .signatureUnavailable:
            return "The database pack signature could not be checked."
        case .archiveInvalid:
            return "The database pack archive could not be read."
        case .downloadFailed:
            return "The database pack could not be downloaded."
        case .developmentBuild:
            return "This development build installs the database pack from the local build."
        }
    }
}

struct DatabasePackInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = DatabasePackInstallModel()

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            Text("Database pack")
                .font(.system(size: UIScale.pt(16), weight: .semibold))
            Text(model.failure ?? model.message)
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: min(max(model.fraction, 0), 1))
                .accessibilityLabel("Database pack download")
            HStack {
                Spacer()
                Button(model.finished || model.failure != nil ? "Done" : "Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(UIScale.pt(20))
        .frame(width: PresentationMetrics.width(420))
        .transientPresentation(dismissible: model.finished || model.failure != nil)
        .task { await model.run() }
    }
}
