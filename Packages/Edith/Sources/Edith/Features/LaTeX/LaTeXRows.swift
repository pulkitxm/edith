import EdithKit
import SwiftUI

struct LaTeXRows: View {
    var body: some View {
        Section("LaTeX projects") {
            Text("Add local .tex files or GitHub repositories from the LaTeX page.")
                .font(.edithText(.body))
            Text(
                "Local compilation uses Tectonic. Repository projects use GitHub Actions for PDFs, Quinjet for review, and Pukbot for pull request changes and squash merges."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
        }
        CLIToolStatusSection(
            tools: [.tectonic, .githubCLI, .quinjet, .pukbot], extensionEnabled: true)
    }
}
