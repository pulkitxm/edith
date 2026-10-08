import EdithKit
import SwiftUI

struct LaTeXRows: View {
    @AppStorage(AppStorageKeys.Tabs.latexEnabled, store: SharedDefaults.store) private var enabled =
        false
    var body: some View {
        Section("LaTeX projects") {
            Text("Add local .tex files or GitHub repositories from the LaTeX page.")
                .font(.edithText(.body))
            Text(
                "Local compilation uses Tectonic or a TeX Live installation. Repository projects use GitHub Actions for PDFs, Quinjet for review, and Pukbot for pull request changes and squash merges."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
        }.disabled(!enabled).opacity(enabled ? 1 : 0.5)
        CLIToolStatusSection(
            tools: [.tectonic, .latexmk, .githubCLI, .pukbot], extensionEnabled: enabled)
    }
}
