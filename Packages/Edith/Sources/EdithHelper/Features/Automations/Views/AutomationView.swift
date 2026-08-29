import EdithKit
import SwiftUI

struct AutomationView: View {
    let runtime: AutomationRuntime

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if runtime.document.scenes.isEmpty {
                    ContentUnavailableView(
                        "No scenes yet", systemImage: "bolt.badge.clock",
                        description: Text("Import a scene or create one from Edith settings.")
                    )
                    .frame(minHeight: 180)
                } else {
                    ForEach(runtime.document.scenes) { scene in
                        sceneRow(scene)
                    }
                }
                if let error = runtime.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let latest = runtime.history.last {
                    HStack {
                        Label("Last run", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text("\(latest.sceneName) · \(latest.succeeded ? "Done" : "Failed")")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 210, maxHeight: 390)
    }

    private func sceneRow(_ scene: AutomationScene) -> some View {
        HStack(spacing: 12) {
            Image(systemName: runtime.activeSceneIDs.contains(scene.id) ? "bolt.fill" : "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    scene.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                )
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(scene.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(
                    "\(scene.actions.count) steps · \(scene.errorPolicy == .stop ? "stop on error" : "continue on error")"
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if runtime.activeSceneIDs.contains(scene.id) {
                Button("Cancel") { runtime.cancel(sceneID: scene.id) }
                    .buttonStyle(.edith(.secondary))
            } else {
                Button("Run") { runtime.runScene(scene, origin: .menuPanel) }
                    .buttonStyle(.edith(.primary))
                    .disabled(!scene.isEnabled)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
