import Foundation

enum FileIconColor: String, CaseIterable {
    case amber
    case blue
    case brown
    case cyan
    case gray
    case green
    case indigo
    case orange
    case pink
    case purple
    case red
    case teal
    case yellow
}

struct FileIconDescriptor: Equatable {
    let badge: String
    let color: FileIconColor
    let symbol: String
}

enum FileIconCatalog {
    static func descriptor(name: String, path: String = "", fileExtension: String)
        -> FileIconDescriptor
    {
        let filename = name.lowercased()
        let location = path.lowercased()
        let ext = fileExtension.lowercased()

        if location.contains("/.github/workflows/") || location.hasPrefix(".github/workflows/") {
            return descriptor("CI", .purple, "arrow.triangle.branch")
        }
        if filename.hasPrefix(".env") {
            return descriptor("ENV", .yellow, "key.fill")
        }
        if filename.hasSuffix(".blade.php") {
            return descriptor("LV", .red, "curlybraces")
        }
        if filename.hasSuffix(".d.ts") {
            return descriptor("TS", .blue, "chevron.left.forwardslash.chevron.right")
        }
        if let exact = exactNames[filename] {
            return exact
        }
        if let framework = frameworkDescriptor(filename) {
            return framework
        }
        if let known = extensionDescriptors[ext] {
            return known
        }
        return fallbackDescriptor(ext)
    }

    private static func frameworkDescriptor(_ filename: String) -> FileIconDescriptor? {
        let frameworks: [(String, FileIconDescriptor)] = [
            ("next.config.", descriptor("NX", .gray, "n.square.fill")),
            ("nuxt.config.", descriptor("NU", .green, "n.square.fill")),
            ("vite.config.", descriptor("VT", .purple, "bolt.fill")),
            ("vitest.config.", descriptor("VI", .green, "checkmark.diamond.fill")),
            ("svelte.config.", descriptor("SV", .orange, "s.square.fill")),
            ("vue.config.", descriptor("VU", .green, "v.square.fill")),
            ("astro.config.", descriptor("AS", .purple, "sparkles")),
            ("tailwind.config.", descriptor("TW", .cyan, "wind")),
            ("postcss.config.", descriptor("PC", .red, "paintbrush.fill")),
            ("webpack.config.", descriptor("WP", .blue, "shippingbox.fill")),
            ("rollup.config.", descriptor("RU", .red, "arrow.triangle.2.circlepath")),
            ("eslint.config.", descriptor("ES", .indigo, "checkmark.seal.fill")),
            ("playwright.config.", descriptor("PW", .green, "play.rectangle.fill")),
            ("jest.config.", descriptor("JT", .red, "checkmark.circle.fill")),
            ("babel.config.", descriptor("BL", .yellow, "wand.and.stars")),
            ("remotion.config.", descriptor("RM", .indigo, "play.square.stack.fill")),
        ]
        return frameworks.first(where: { filename.hasPrefix($0.0) })?.1
    }

    private static let exactNames: [String: FileIconDescriptor] = [
        "dockerfile": descriptor("DK", .cyan, "shippingbox.fill"),
        "containerfile": descriptor("CT", .blue, "shippingbox.fill"),
        "docker-compose.yml": descriptor("DK", .cyan, "square.stack.3d.up.fill"),
        "docker-compose.yaml": descriptor("DK", .cyan, "square.stack.3d.up.fill"),
        "compose.yml": descriptor("DK", .cyan, "square.stack.3d.up.fill"),
        "compose.yaml": descriptor("DK", .cyan, "square.stack.3d.up.fill"),
        "makefile": descriptor("MK", .orange, "hammer.fill"),
        "gnumakefile": descriptor("MK", .orange, "hammer.fill"),
        "cmakelists.txt": descriptor("CM", .blue, "hammer.fill"),
        "justfile": descriptor("JS", .purple, "hammer.fill"),
        "taskfile.yml": descriptor("TK", .blue, "checklist"),
        "taskfile.yaml": descriptor("TK", .blue, "checklist"),
        "package.json": descriptor("NP", .red, "shippingbox.fill"),
        "package-lock.json": descriptor("NP", .red, "lock.fill"),
        "pnpm-lock.yaml": descriptor("PN", .orange, "lock.fill"),
        "yarn.lock": descriptor("YN", .blue, "lock.fill"),
        "bun.lock": descriptor("BN", .brown, "lock.fill"),
        "bun.lockb": descriptor("BN", .brown, "lock.fill"),
        "deno.json": descriptor("DN", .gray, "d.circle.fill"),
        "deno.jsonc": descriptor("DN", .gray, "d.circle.fill"),
        "angular.json": descriptor("NG", .red, "a.square.fill"),
        "cargo.toml": descriptor("RS", .orange, "shippingbox.fill"),
        "cargo.lock": descriptor("RS", .orange, "lock.fill"),
        "go.mod": descriptor("GO", .cyan, "shippingbox.fill"),
        "go.sum": descriptor("GO", .cyan, "checkmark.seal.fill"),
        "package.swift": descriptor("SW", .orange, "shippingbox.fill"),
        "podfile": descriptor("CP", .red, "shippingbox.fill"),
        "podfile.lock": descriptor("CP", .red, "lock.fill"),
        "gemfile": descriptor("RB", .red, "diamond.fill"),
        "gemfile.lock": descriptor("RB", .red, "lock.fill"),
        "rakefile": descriptor("RB", .red, "hammer.fill"),
        "brewfile": descriptor("BR", .orange, "mug.fill"),
        "composer.json": descriptor("CP", .brown, "music.note.list"),
        "composer.lock": descriptor("CP", .brown, "lock.fill"),
        "manage.py": descriptor("DJ", .green, "leaf.fill"),
        "artisan": descriptor("LV", .red, "hammer.fill"),
        "mix.exs": descriptor("EX", .purple, "shippingbox.fill"),
        "mix.lock": descriptor("EX", .purple, "lock.fill"),
        "pubspec.yaml": descriptor("FL", .blue, "shippingbox.fill"),
        "pubspec.lock": descriptor("FL", .blue, "lock.fill"),
        "build.gradle": descriptor("GR", .green, "hammer.fill"),
        "build.gradle.kts": descriptor("KT", .purple, "hammer.fill"),
        "settings.gradle": descriptor("GR", .green, "gearshape.fill"),
        "gradlew": descriptor("GR", .green, "hammer.fill"),
        "pom.xml": descriptor("MV", .red, "shippingbox.fill"),
        "build.sbt": descriptor("SB", .red, "hammer.fill"),
        "workspace": descriptor("BZ", .green, "square.stack.3d.up.fill"),
        "workspace.bazel": descriptor("BZ", .green, "square.stack.3d.up.fill"),
        "build": descriptor("BZ", .green, "hammer.fill"),
        "build.bazel": descriptor("BZ", .green, "hammer.fill"),
        "flake.nix": descriptor("NX", .blue, "snowflake"),
        "shell.nix": descriptor("NX", .blue, "terminal.fill"),
        "vagrantfile": descriptor("VG", .blue, "cube.fill"),
        "procfile": descriptor("HK", .purple, "server.rack"),
        "vercel.json": descriptor("VC", .gray, "triangle.fill"),
        "netlify.toml": descriptor("NF", .teal, "network"),
        "render.yaml": descriptor("RN", .purple, "cloud.fill"),
        "firebase.json": descriptor("FB", .amber, "flame.fill"),
        "supabase.toml": descriptor("SB", .green, "bolt.fill"),
        "codeowners": descriptor("CO", .purple, "person.2.fill"),
        ".gitignore": descriptor("GT", .orange, "arrow.triangle.branch"),
        ".gitattributes": descriptor("GT", .orange, "arrow.triangle.branch"),
        ".gitmodules": descriptor("GT", .orange, "arrow.triangle.branch"),
        ".editorconfig": descriptor("EC", .orange, "slider.horizontal.3"),
        ".prettierrc": descriptor("PR", .pink, "paintbrush.fill"),
        ".eslintrc": descriptor("ES", .indigo, "checkmark.seal.fill"),
        ".npmrc": descriptor("NP", .red, "gearshape.fill"),
        ".nvmrc": descriptor("ND", .green, "n.square.fill"),
        ".yarnrc": descriptor("YN", .blue, "gearshape.fill"),
        ".babelrc": descriptor("BL", .yellow, "wand.and.stars"),
        ".browserslistrc": descriptor("WB", .orange, "globe"),
        ".swift-format": descriptor("SW", .orange, "paintbrush.fill"),
        ".clang-format": descriptor("C", .blue, "paintbrush.fill"),
        ".clang-tidy": descriptor("C", .blue, "checkmark.seal.fill"),
        "readme": descriptor("RD", .blue, "book.closed.fill"),
        "license": descriptor("LC", .yellow, "checkmark.seal.fill"),
        "copying": descriptor("LC", .yellow, "checkmark.seal.fill"),
        "authors": descriptor("AU", .purple, "person.2.fill"),
        "contributors": descriptor("AU", .purple, "person.2.fill"),
        "changelog": descriptor("CH", .green, "clock.arrow.circlepath"),
        "doxyfile": descriptor("DX", .blue, "book.closed.fill"),
    ]

    private static let extensionDescriptors: [String: FileIconDescriptor] = {
        var result: [String: FileIconDescriptor] = [:]
        add(
            ["js", "mjs", "cjs", "jsx"],
            descriptor("JS", .yellow, "chevron.left.forwardslash.chevron.right"), to: &result)
        add(
            ["ts", "mts", "cts", "tsx"],
            descriptor("TS", .blue, "chevron.left.forwardslash.chevron.right"), to: &result)
        add(
            ["py", "pyi", "pyw"],
            descriptor("PY", .blue, "chevron.left.forwardslash.chevron.right"), to: &result)
        add(["rb", "rake", "gemspec", "erb"], descriptor("RB", .red, "diamond.fill"), to: &result)
        add(["rs"], descriptor("RS", .orange, "gearshape.2.fill"), to: &result)
        add(["swift", "gyb"], descriptor("SW", .orange, "swift"), to: &result)
        add(["c", "h"], descriptor("C", .blue, "c.square.fill"), to: &result)
        add(
            ["cpp", "cc", "cxx", "hpp", "hxx", "hh", "inl", "cppm"],
            descriptor("C++", .blue, "c.square.fill"), to: &result)
        add(["m", "mm"], descriptor("OC", .indigo, "apple.logo"), to: &result)
        add(["cs", "csx", "cshtml"], descriptor("C#", .green, "number.square.fill"), to: &result)
        add(["fs", "fsx", "fsi"], descriptor("F#", .cyan, "number.square.fill"), to: &result)
        add(["java"], descriptor("JV", .red, "cup.and.saucer.fill"), to: &result)
        add(["kt", "kts"], descriptor("KT", .purple, "k.square.fill"), to: &result)
        add(["scala", "sc"], descriptor("SC", .red, "s.square.fill"), to: &result)
        add(["go"], descriptor("GO", .cyan, "g.circle.fill"), to: &result)
        add(
            ["php", "phtml"], descriptor("PHP", .indigo, "chevron.left.forwardslash.chevron.right"),
            to: &result)
        add(["dart"], descriptor("DA", .blue, "d.square.fill"), to: &result)
        add(["lua"], descriptor("LU", .blue, "moon.fill"), to: &result)
        add(["zig"], descriptor("ZG", .orange, "bolt.fill"), to: &result)
        add(
            ["ex", "exs", "eex", "heex", "leex"], descriptor("EX", .purple, "drop.fill"),
            to: &result)
        add(["erl", "hrl"], descriptor("ER", .red, "e.square.fill"), to: &result)
        add(["hs", "lhs"], descriptor("HS", .purple, "h.square.fill"), to: &result)
        add(["clj", "cljs", "cljc", "edn"], descriptor("CLJ", .green, "leaf.fill"), to: &result)
        add(["elm"], descriptor("ELM", .cyan, "triangle.fill"), to: &result)
        add(["jl"], descriptor("JL", .purple, "function"), to: &result)
        add(["r", "rmd"], descriptor("R", .blue, "r.square.fill"), to: &result)
        add(["pl", "pm", "t"], descriptor("PL", .blue, "p.square.fill"), to: &result)
        add(
            ["sh", "bash", "zsh", "fish", "ksh", "command"],
            descriptor("SH", .green, "terminal.fill"), to: &result)
        add(["ps1", "psm1", "psd1"], descriptor("PS", .blue, "terminal.fill"), to: &result)
        add(["bat", "cmd"], descriptor("BAT", .gray, "terminal.fill"), to: &result)
        add(["sql", "psql"], descriptor("SQL", .blue, "cylinder.fill"), to: &result)
        add(
            ["graphql", "gql"], descriptor("GQL", .pink, "point.3.connected.trianglepath.dotted"),
            to: &result)
        add(["proto", "fbs"], descriptor("PB", .green, "square.stack.3d.up.fill"), to: &result)
        add(["sol"], descriptor("SOL", .gray, "diamond.fill"), to: &result)
        add(["move"], descriptor("MV", .cyan, "arrow.right.square.fill"), to: &result)
        add(["nix"], descriptor("NIX", .blue, "snowflake"), to: &result)
        add(["v", "vh", "sv", "svh"], descriptor("HDL", .green, "cpu.fill"), to: &result)
        add(["asm", "s"], descriptor("ASM", .red, "cpu.fill"), to: &result)
        add(["cu", "cuh"], descriptor("CU", .green, "cpu.fill"), to: &result)
        add(["groovy", "gradle"], descriptor("GR", .green, "g.square.fill"), to: &result)
        add(
            ["gd", "gdscript", "godot", "gdextension"],
            descriptor("GD", .blue, "gamecontroller.fill"), to: &result)
        add(
            ["glsl", "vert", "frag", "hlsl", "metal"],
            descriptor("GPU", .purple, "sparkles.rectangle.stack.fill"), to: &result)
        add(
            ["html", "htm", "xhtml"],
            descriptor("HTML", .orange, "chevron.left.forwardslash.chevron.right"), to: &result)
        add(["css"], descriptor("CSS", .blue, "paintbrush.fill"), to: &result)
        add(["scss", "sass"], descriptor("SASS", .pink, "paintbrush.fill"), to: &result)
        add(["less", "styl"], descriptor("CSS", .indigo, "paintbrush.fill"), to: &result)
        add(["vue"], descriptor("VUE", .green, "v.square.fill"), to: &result)
        add(["svelte"], descriptor("SV", .orange, "s.square.fill"), to: &result)
        add(["astro"], descriptor("AS", .purple, "sparkles"), to: &result)
        add(
            ["xml", "xsd", "xsl", "xslt", "dtd"],
            descriptor("XML", .orange, "chevron.left.forwardslash.chevron.right"), to: &result)
        add(
            ["json", "jsonc", "json5", "jsonl", "geojson", "webmanifest"],
            descriptor("JSON", .yellow, "curlybraces"), to: &result)
        add(["yaml", "yml"], descriptor("YML", .red, "list.bullet.indent"), to: &result)
        add(["toml"], descriptor("TOML", .brown, "slider.horizontal.3"), to: &result)
        add(
            ["ini", "cfg", "conf", "config", "cnf", "properties"],
            descriptor("CFG", .gray, "gearshape.fill"), to: &result)
        add(["plist"], descriptor("PLST", .blue, "list.bullet.rectangle.fill"), to: &result)
        add(["entitlements"], descriptor("ENT", .blue, "checkmark.shield.fill"), to: &result)
        add(
            ["xcconfig", "pbxproj", "xcscheme", "xcworkspacedata", "xcprivacy"],
            descriptor("XCD", .blue, "hammer.fill"), to: &result)
        add(["tf", "tfvars", "hcl"], descriptor("TF", .purple, "cube.fill"), to: &result)
        add(["bzl", "bazel", "bzlmod"], descriptor("BZ", .green, "hammer.fill"), to: &result)
        add(["cmake"], descriptor("CM", .blue, "hammer.fill"), to: &result)
        add(["prisma"], descriptor("PR", .indigo, "cylinder.fill"), to: &result)
        add(
            ["md", "mdx", "mdc", "markdown"], descriptor("MD", .blue, "text.document.fill"),
            to: &result)
        add(
            ["rst", "adoc", "asciidoc", "tex", "bib"],
            descriptor("DOC", .blue, "text.document.fill"), to: &result)
        add(
            ["txt", "text", "log", "stdout", "stderr"], descriptor("TXT", .gray, "text.alignleft"),
            to: &result)
        add(["pdf"], descriptor("PDF", .red, "doc.richtext.fill"), to: &result)
        add(
            ["doc", "docx", "odt", "rtf"], descriptor("DOC", .blue, "doc.richtext.fill"),
            to: &result)
        add(
            ["xls", "xlsx", "ods", "csv", "tsv"], descriptor("TAB", .green, "tablecells.fill"),
            to: &result)
        add(
            ["ppt", "pptx", "odp", "key"],
            descriptor("SLD", .orange, "rectangle.on.rectangle.angled"), to: &result)
        add(
            [
                "png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "tif", "tiff", "bmp", "ico",
                "icns", "svg", "apng", "psd", "exr", "hdr", "tga", "dds",
            ], descriptor("IMG", .pink, "photo.fill"), to: &result)
        add(
            ["mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "aiff"],
            descriptor("AUD", .purple, "waveform"), to: &result)
        add(
            ["mp4", "mov", "mkv", "avi", "webm", "m4v"],
            descriptor("VID", .red, "play.rectangle.fill"), to: &result)
        add(
            ["zip", "tar", "gz", "tgz", "bz2", "xz", "lzma", "7z", "rar", "br", "zst"],
            descriptor("ZIP", .brown, "archivebox.fill"), to: &result)
        add(
            ["ttf", "otf", "woff", "woff2", "eot"], descriptor("FONT", .indigo, "textformat"),
            to: &result)
        add(
            ["db", "dbf", "sqlite", "sqlite3"], descriptor("DB", .blue, "cylinder.fill"),
            to: &result)
        add(
            ["pem", "crt", "cer", "cert", "key", "csr", "der", "p12", "pfx", "keystore"],
            descriptor("KEY", .yellow, "key.fill"), to: &result)
        add(["lock", "resolved", "sum"], descriptor("LOCK", .gray, "lock.fill"), to: &result)
        add(["diff", "patch"], descriptor("DIFF", .green, "plusminus"), to: &result)
        add(["wasm", "wat"], descriptor("WASM", .purple, "w.square.fill"), to: &result)
        add(
            ["exe", "dll", "dylib", "so", "a", "bin", "class", "jar"],
            descriptor("BIN", .gray, "cpu.fill"), to: &result)
        add(
            ["gltf", "glb", "obj", "fbx", "dae", "blend", "stl", "usdz"],
            descriptor("3D", .teal, "cube.fill"), to: &result)
        add(["ipynb"], descriptor("NB", .orange, "book.pages.fill"), to: &result)
        add(
            ["po", "pot", "mo", "strings", "arb"], descriptor("I18N", .green, "globe"), to: &result)
        add(["ics"], descriptor("CAL", .red, "calendar"), to: &result)
        add(["eml"], descriptor("MAIL", .blue, "envelope.fill"), to: &result)
        add(
            ["snap", "snapshot", "golden", "expected"],
            descriptor("TEST", .green, "checkmark.circle.fill"), to: &result)
        return result
    }()

    private static func descriptor(_ badge: String, _ color: FileIconColor, _ symbol: String)
        -> FileIconDescriptor
    {
        FileIconDescriptor(badge: badge, color: color, symbol: symbol)
    }

    private static func add(
        _ extensions: [String], _ descriptor: FileIconDescriptor,
        to result: inout [String: FileIconDescriptor]
    ) {
        for ext in extensions {
            result[ext] = descriptor
        }
    }

    private static func fallbackDescriptor(_ ext: String) -> FileIconDescriptor {
        guard !ext.isEmpty else {
            return descriptor("FILE", .gray, "doc.fill")
        }
        let badge = String(ext.prefix(4)).uppercased()
        let value = ext.utf8.reduce(0) { (partial, byte) in
            (partial &* 31 &+ Int(byte)) & 0x7fff_ffff
        }
        let colors = FileIconColor.allCases.filter { $0 != .gray }
        return descriptor(badge, colors[value % colors.count], "doc.fill")
    }
}
