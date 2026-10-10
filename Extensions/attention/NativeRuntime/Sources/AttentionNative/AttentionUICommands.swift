@_implementationOnly import EdithExtensionSupport
@_implementationOnly import EdithExtensionUI
import AppKit
import ApplicationServices
import Foundation

@MainActor enum AttentionUICommands {
    static func execute(
        _ operation: String, payload: Data, repository: AttentionRepository,
        service: AttentionBackgroundService
    ) async throws -> Data {
        guard payload.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        try Task.checkCancellation()
        if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil,
            [
                "attention.ui.extension.install", "attention.ui.extension.open",
                "attention.ui.token.copy",
                "attention.ui.accessibility", "attention.ui.breakdown.copy",
            ].contains(operation)
        {
            throw ExtensionPeerError.rejected("System actions are unavailable in fixture mode.")
        }
        if [
            "attention.ui.summary", "attention.ui.focus.get", "attention.ui.focus.start",
            "attention.ui.focus.stop", "attention.ui.breakdown.copy",
        ].contains(operation) {
            guard
                !SurfacePrivacyState.hides(
                    .ability("attention"),
                    values: ExtensionSharedState.current?.values(for: "presenter") ?? [:])
            else {
                throw ExtensionPeerError.rejected(
                    "Attention activity is hidden by privacy settings.")
            }
        }
        switch operation {
        case "attention.ui.summary", "attention.ui.focus.get", "attention.ui.focus.start",
            "attention.ui.focus.stop":
            return try await AttentionCommands.execute(
                operation.replacingOccurrences(of: "attention.ui.", with: "attention."),
                payload: payload, service: service)
        case "attention.ui.status":
            try AttentionCommands.empty(payload)
            let settings = repository.loadSettings()
            let snapshot = try await service.runtimeStatus()
            let backup = AttentionCloudBackup(localDirectory: repository.directory)
            return try AttentionPayload.encode(
                AttentionUIStatus(
                    extensionInstalled: FileManager.default.fileExists(
                        atPath: AttentionExtensionInstaller.installedDirectory.path),
                    browserConnected: settings.isEnabled && settings.browserTrackingEnabled
                        && snapshot.browserListening == true,
                    backupAvailable: backup.available, lastBackupAt: backup.lastBackupAt))
        case "attention.ui.extension.install":
            try AttentionCommands.empty(payload)
            try AttentionExtensionInstaller.reveal()
        case "attention.ui.extension.open":
            try AttentionCommands.empty(payload)
            guard AttentionExtensionInstaller.openExtensionsPage() else {
                throw AttentionServiceError("Could not open chrome://extensions")
            }
        case "attention.ui.token.copy":
            try AttentionCommands.empty(payload)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(repository.loadSettings().serverToken, forType: .string)
        case "attention.ui.accessibility":
            try AttentionCommands.empty(payload)
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case "attention.ui.application.icon":
            guard payload.count <= 1024 else { throw ExtensionPeerError.invalidRequest }
            let id = try AttentionPayload.decode(String.self, from: payload)
            guard !id.isEmpty, id.utf8.count <= 256 else { throw ExtensionPeerError.invalidRequest }
            let fixture = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
            let icon = fixture ? nil : await AttentionApplicationIcon.resolve(bundleID: id)
            let data = icon?.tiffRepresentation.flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }
            return try AttentionPayload.encode(data)
        case "attention.ui.breakdown.copy":
            let request = try AttentionPayload.decode(
                AttentionUIBreakdownRequest.self, from: payload)
            guard request.search.utf8.count <= 4096,
                let sort = AttentionBreakdownSort(rawValue: request.sort)
            else { throw ExtensionPeerError.invalidRequest }
            try AttentionCommands.interval(
                from: request.summary.from, to: request.summary.to, allTime: request.summary.allTime
            )
            let snapshot = try await service.summary(request.summary)
            let filter = AttentionSpanFilter(
                level: request.level, sphere: request.sphere,
                category: request.category, search: request.search)
            let rows = AttentionBreakdownProjection(
                summary: snapshot.summary, dimension: request.dimension, filter: filter, sort: sort
            ).rows
            let title =
                snapshot.summary.dimensions.first(where: { $0.key == request.dimension })?.title
                ?? request.dimension
            let total = rows.reduce(0) { $0 + $1.duration }
            let lines =
                ["\(DoubleQuoted.wrap(title)),seconds,minutes,share_percent"]
                + rows.map {
                    "\(DoubleQuoted.wrap($0.label)),\(String(format: "%.0f", $0.duration)),\(String(format: "%.2f", $0.duration / 60)),\(String(format: "%.2f", total > 0 ? $0.duration / total * 100 : 0))"
                }
            try Task.checkCancellation()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        default: throw ExtensionPeerError.invalidRequest
        }
        return Data("{}".utf8)
    }
}
