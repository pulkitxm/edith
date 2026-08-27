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
                == FileIconDescriptor(badge: "XCD", color: .blue, symbol: "hammer.fill"))
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

    @Test("recognizes compound names and repository context")
    func context() {
        #expect(icon("app.d.ts").badge == "TS")
        #expect(icon("welcome.blade.php").badge == "LV")
        #expect(icon("deploy.yml", path: ".github/workflows/deploy.yml").badge == "CI")
        #expect(icon(".env.production").badge == "ENV")
    }

    @Test("creates stable distinct fallbacks for the long tail")
    func fallbacks() {
        let first = icon("model.safetensors")
        let repeated = icon("weights.safetensors")
        let other = icon("scene.customformat")
        #expect(first == repeated)
        #expect(first.badge == "SAFE")
        #expect(other.badge == "CUST")
        #expect(first.color != other.color || first.badge != other.badge)
    }

    private func icon(_ name: String, path: String = "") -> FileIconDescriptor {
        let ext =
            name.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let fileExtension = name.contains(".") && !name.hasSuffix(".") ? ext : ""
        return FileIconCatalog.descriptor(name: name, path: path, fileExtension: fileExtension)
    }
}
