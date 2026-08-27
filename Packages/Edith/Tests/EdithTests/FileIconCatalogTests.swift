import Testing

@testable import Edith

@Suite("File icon catalog")
struct FileIconCatalogTests {
    @Test("recognizes languages and platform formats")
    func extensions() {
        #expect(
            icon("main.rs")
                == FileIconDescriptor(badge: "RS", color: .orange, symbol: "gearshape.2.fill"))
        #expect(
            icon("Info.plist")
                == FileIconDescriptor(
                    badge: "PLST", color: .blue, symbol: "list.bullet.rectangle.fill"))
        #expect(
            icon("schema.prisma")
                == FileIconDescriptor(badge: "PR", color: .indigo, symbol: "cylinder.fill"))
        #expect(
            icon("shader.glsl")
                == FileIconDescriptor(
                    badge: "GPU", color: .purple, symbol: "sparkles.rectangle.stack.fill"))
    }

    @Test("recognizes framework and stack files")
    func frameworks() {
        #expect(icon("Dockerfile").badge == "DK")
        #expect(icon("Cargo.toml").badge == "RS")
        #expect(icon("next.config.ts").badge == "NX")
        #expect(icon("tailwind.config.js").badge == "TW")
        #expect(icon("manage.py").badge == "DJ")
        #expect(icon("pubspec.yaml").badge == "FL")
        #expect(icon("main.tf").badge == "TF")
    }

    @Test("recognizes Next.js and TypeScript ecosystem files")
    func typescriptEcosystem() {
        #expect(icon("pnpm-workspace.yaml").badge == "PN")
        #expect(icon("tsconfig.json").badge == "TS")
        #expect(icon("turbo.json").badge == "TB")
        #expect(icon("components.json").badge == "UI")
        #expect(icon("cypress.config.ts").badge == "CY")
        #expect(icon("button.stories.tsx").badge == "SB")
        #expect(icon("theme.ts", path: ".storybook/theme.ts").badge == "SB")
        #expect(icon("devcontainer.json", path: ".devcontainer/devcontainer.json").badge == "DEV")
        #expect(icon("workspace.code-workspace").badge == "VS")
        #expect(icon("cache.tsbuildinfo").badge == "TS")
    }

    @Test("recognizes Python ecosystem files")
    func pythonEcosystem() {
        #expect(icon("pyproject.toml").badge == "PY")
        #expect(icon("requirements.txt").badge == "PY")
        #expect(icon("uv.lock").badge == "UV")
        #expect(icon("MANIFEST.in").badge == "PY")
        #expect(icon(".python-version").badge == "PY")
        #expect(icon("module.pyx").badge == "CY")
        #expect(icon("template.jinja2").badge == "J2")
        #expect(icon("model.onnx").badge == "ML")
    }

    @Test("recognizes Swift and Apple ecosystem files")
    func swiftEcosystem() {
        #expect(icon("Cartfile.resolved").badge == "CT")
        #expect(icon("Project.swift").badge == "TU")
        #expect(icon("Main.storyboard").badge == "UI")
        #expect(icon("Settings.xctestplan").badge == "XCD")
        #expect(icon("Module.swiftinterface").badge == "SW")
        #expect(icon("Model.mlmodel").badge == "ML")
        #expect(icon(".swiftlint.yml").badge == "SW")
    }

    @Test("recognizes Rust and systems ecosystem files")
    func rustEcosystem() {
        #expect(icon("rust-toolchain.toml").badge == "RS")
        #expect(icon("clippy.toml").badge == "RS")
        #expect(icon("shader.wgsl").badge == "GPU")
        #expect(icon("library.rlib").badge == "BIN")
        #expect(icon("module.ll").badge == "IR")
        #expect(icon("installer.wxs").badge == "SETUP")
        #expect(icon("service.service").badge == "SYS")
    }

    @Test("recognizes data media and documentation formats")
    func broaderFormats() {
        #expect(icon("dataset.parquet").badge == "DATA")
        #expect(icon("weights.safetensors").badge == "ML")
        #expect(icon("architecture.mermaid").badge == "DIA")
        #expect(icon("photo.jxl").badge == "IMG")
        #expect(icon("captions.vtt").badge == "SUB")
        #expect(icon("locations.kml").badge == "GEO")
        #expect(icon("package.deb").badge == "ZIP")
    }

    @Test("recognizes compound names and repository context")
    func context() {
        #expect(icon("app.d.ts").badge == "TS")
        #expect(icon("welcome.blade.php").badge == "LV")
        #expect(icon("deploy.yml", path: ".github/workflows/deploy.yml").badge == "CI")
        #expect(icon(".env.production").badge == "ENV")
        #expect(icon("bug.yml", path: ".github/ISSUE_TEMPLATE/bug.yml").badge == "ISS")
        #expect(
            icon("default.md", path: ".github/PULL_REQUEST_TEMPLATE/default.md").badge == "PR")
    }

    @Test("creates stable distinct fallbacks for the long tail")
    func fallbacks() {
        let first = icon("model.zorbium")
        let repeated = icon("weights.zorbium")
        let other = icon("scene.customformat")
        #expect(first == repeated)
        #expect(first.badge == "ZORB")
        #expect(other.badge == "CUST")
        #expect(first.color != other.color || first.badge != other.badge)
    }

    @Test("renders distinct high resolution document icons")
    func rendering() {
        let swift = FileIconRenderer.image(for: icon("Feature.swift"))
        let terraform = FileIconRenderer.image(for: icon("main.tf"))
        #expect(swift.size == FileIconRenderer.size)
        #expect(terraform.size == FileIconRenderer.size)
        #expect(swift.tiffRepresentation != terraform.tiffRepresentation)
    }

    private func icon(_ name: String, path: String = "") -> FileIconDescriptor {
        let ext =
            name.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let fileExtension = name.contains(".") && !name.hasSuffix(".") ? ext : ""
        return FileIconCatalog.descriptor(name: name, path: path, fileExtension: fileExtension)
    }
}
