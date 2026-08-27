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
        if location.contains("/.github/issue_template/")
            || location.hasPrefix(".github/issue_template/")
        {
            return descriptor("ISS", .green, "bubble.left.and.bubble.right.fill")
        }
        if location.contains("/.github/pull_request_template/")
            || location.hasPrefix(".github/pull_request_template/")
        {
            return descriptor("PR", .purple, "arrow.triangle.pull")
        }
        if location.contains("/.devcontainer/") || location.hasPrefix(".devcontainer/") {
            return descriptor("DEV", .blue, "shippingbox.fill")
        }
        if location.contains("/.storybook/") || location.hasPrefix(".storybook/") {
            return descriptor("SB", .pink, "book.pages.fill")
        }
        if location.contains("/.vscode/") || location.hasPrefix(".vscode/") {
            return descriptor("VS", .blue, "chevron.left.forwardslash.chevron.right")
        }
        if location.contains("/.idea/") || location.hasPrefix(".idea/") {
            return descriptor("IDE", .purple, "hammer.fill")
        }
        if location.contains("/.cargo/") || location.hasPrefix(".cargo/") {
            return descriptor("RS", .orange, "gearshape.2.fill")
        }
        if location.contains("/.changeset/") || location.hasPrefix(".changeset/") {
            return descriptor("CS", .purple, "clock.arrow.circlepath")
        }
        if location.contains("/.circleci/") || location.hasPrefix(".circleci/") {
            return descriptor("CI", .green, "arrow.triangle.branch")
        }
        if filename.hasPrefix(".env") {
            return descriptor("ENV", .yellow, "key.fill")
        }
        if let exact = exactNames[filename] {
            return exact
        }
        if filename.hasSuffix(".blade.php") {
            return descriptor("LV", .red, "curlybraces")
        }
        if filename.hasSuffix(".d.ts") {
            return descriptor("TS", .blue, "chevron.left.forwardslash.chevron.right")
        }
        if filename.contains(".test.") || filename.contains(".spec.") {
            return descriptor("TEST", .green, "checkmark.circle.fill")
        }
        if filename.contains(".stories.") || filename.contains(".story.") {
            return descriptor("SB", .pink, "book.pages.fill")
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
            ("next-sitemap.config.", descriptor("NX", .gray, "map.fill")),
            ("next-i18next.config.", descriptor("NX", .gray, "globe")),
            ("nuxt.config.", descriptor("NU", .green, "n.square.fill")),
            ("vite.config.", descriptor("VT", .purple, "bolt.fill")),
            ("vitest.config.", descriptor("VI", .green, "checkmark.diamond.fill")),
            ("vitest.workspace.", descriptor("VI", .green, "square.stack.3d.up.fill")),
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
            ("prettier.config.", descriptor("PR", .pink, "paintbrush.fill")),
            ("stylelint.config.", descriptor("SL", .purple, "paintbrush.fill")),
            ("cypress.config.", descriptor("CY", .green, "checkmark.circle.fill")),
            ("tsup.config.", descriptor("TU", .cyan, "shippingbox.fill")),
            ("esbuild.config.", descriptor("EB", .yellow, "hammer.fill")),
            ("rspack.config.", descriptor("RP", .cyan, "shippingbox.fill")),
            ("drizzle.config.", descriptor("DZ", .green, "cylinder.fill")),
            ("prisma.config.", descriptor("PR", .indigo, "cylinder.fill")),
            ("knip.config.", descriptor("KN", .orange, "scissors")),
            ("payload.config.", descriptor("PL", .gray, "shippingbox.fill")),
            ("react-router.config.", descriptor("RR", .red, "arrow.triangle.branch")),
            ("metro.config.", descriptor("MT", .blue, "tram.fill")),
            ("sentry.client.config.", descriptor("SE", .purple, "ant.fill")),
            ("sentry.server.config.", descriptor("SE", .purple, "ant.fill")),
            ("sentry.edge.config.", descriptor("SE", .purple, "ant.fill")),
            ("tsconfig.", descriptor("TS", .blue, "gearshape.fill")),
            ("jsconfig.", descriptor("JS", .yellow, "gearshape.fill")),
            ("typedoc.", descriptor("TD", .blue, "book.closed.fill")),
            ("api-extractor.", descriptor("API", .blue, "shippingbox.fill")),
            ("nodemon.", descriptor("ND", .green, "arrow.clockwise")),
            ("lerna.", descriptor("LR", .blue, "square.stack.3d.up.fill")),
            ("rush.", descriptor("RU", .orange, "square.stack.3d.up.fill")),
            ("requirements-", descriptor("PY", .blue, "list.bullet.rectangle.fill")),
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
        "jenkinsfile": descriptor("JK", .red, "server.rack"),
        "earthfile": descriptor("EA", .purple, "globe"),
        "tiltfile": descriptor("TL", .red, "shippingbox.fill"),
        "buck": descriptor("BK", .blue, "hammer.fill"),
        ".buckconfig": descriptor("BK", .blue, "gearshape.fill"),
        "pants.toml": descriptor("PT", .green, "hammer.fill"),
        "package.json": descriptor("NP", .red, "shippingbox.fill"),
        "package-lock.json": descriptor("NP", .red, "lock.fill"),
        "pnpm-lock.yaml": descriptor("PN", .orange, "lock.fill"),
        "pnpm-workspace.yaml": descriptor("PN", .orange, "square.stack.3d.up.fill"),
        "yarn.lock": descriptor("YN", .blue, "lock.fill"),
        "bun.lock": descriptor("BN", .brown, "lock.fill"),
        "bun.lockb": descriptor("BN", .brown, "lock.fill"),
        "deno.json": descriptor("DN", .gray, "d.circle.fill"),
        "deno.jsonc": descriptor("DN", .gray, "d.circle.fill"),
        "deno.lock": descriptor("DN", .gray, "lock.fill"),
        "tsconfig.json": descriptor("TS", .blue, "gearshape.fill"),
        "jsconfig.json": descriptor("JS", .yellow, "gearshape.fill"),
        "turbo.json": descriptor("TB", .red, "bolt.fill"),
        "nx.json": descriptor("NX", .blue, "square.stack.3d.up.fill"),
        "biome.json": descriptor("BM", .green, "checkmark.seal.fill"),
        "biome.jsonc": descriptor("BM", .green, "checkmark.seal.fill"),
        "components.json": descriptor("UI", .gray, "square.grid.2x2.fill"),
        "next-env.d.ts": descriptor("NX", .gray, "n.square.fill"),
        "middleware.ts": descriptor("NX", .gray, "arrow.left.arrow.right"),
        "instrumentation.ts": descriptor("NX", .gray, "gauge.with.dots.needle.67percent"),
        "proxy.ts": descriptor("NX", .gray, "network"),
        "route.ts": descriptor("NX", .gray, "arrow.triangle.branch"),
        "page.tsx": descriptor("NX", .gray, "doc.text.fill"),
        "layout.tsx": descriptor("NX", .gray, "rectangle.3.group.fill"),
        "loading.tsx": descriptor("NX", .gray, "hourglass"),
        "error.tsx": descriptor("NX", .red, "exclamationmark.triangle.fill"),
        "not-found.tsx": descriptor("NX", .gray, "questionmark.folder.fill"),
        "template.tsx": descriptor("NX", .gray, "doc.on.doc.fill"),
        "default.tsx": descriptor("NX", .gray, "doc.fill"),
        "typedoc.json": descriptor("TD", .blue, "book.closed.fill"),
        "api-extractor.json": descriptor("API", .blue, "shippingbox.fill"),
        "nodemon.json": descriptor("ND", .green, "arrow.clockwise"),
        "lerna.json": descriptor("LR", .blue, "square.stack.3d.up.fill"),
        "rush.json": descriptor("RU", .orange, "square.stack.3d.up.fill"),
        "wrangler.toml": descriptor("CF", .orange, "cloud.fill"),
        "angular.json": descriptor("NG", .red, "a.square.fill"),
        "cargo.toml": descriptor("RS", .orange, "shippingbox.fill"),
        "cargo.lock": descriptor("RS", .orange, "lock.fill"),
        "rust-project.json": descriptor("RS", .orange, "hammer.fill"),
        "rust-analyzer.json": descriptor("RS", .orange, "gearshape.fill"),
        "cargo-generate.toml": descriptor("RS", .orange, "doc.on.doc.fill"),
        "makefile.toml": descriptor("RS", .orange, "hammer.fill"),
        "go.mod": descriptor("GO", .cyan, "shippingbox.fill"),
        "go.sum": descriptor("GO", .cyan, "checkmark.seal.fill"),
        "package.swift": descriptor("SW", .orange, "shippingbox.fill"),
        "package.resolved": descriptor("SW", .orange, "lock.fill"),
        "podfile": descriptor("CP", .red, "shippingbox.fill"),
        "podfile.lock": descriptor("CP", .red, "lock.fill"),
        "cartfile": descriptor("CT", .blue, "shippingbox.fill"),
        "cartfile.resolved": descriptor("CT", .blue, "lock.fill"),
        "mintfile": descriptor("MT", .green, "shippingbox.fill"),
        "project.swift": descriptor("TU", .blue, "hammer.fill"),
        "workspace.swift": descriptor("TU", .blue, "square.stack.3d.up.fill"),
        "tuist.swift": descriptor("TU", .blue, "hammer.fill"),
        "dangerfile": descriptor("DG", .red, "exclamationmark.triangle.fill"),
        "fastfile": descriptor("FL", .purple, "bolt.fill"),
        "appfile": descriptor("FL", .purple, "app.fill"),
        "matchfile": descriptor("FL", .purple, "checkmark.seal.fill"),
        "snapfile": descriptor("FL", .purple, "camera.fill"),
        "xcodegen.yml": descriptor("XG", .blue, "hammer.fill"),
        "xcodegen.yaml": descriptor("XG", .blue, "hammer.fill"),
        "periphery.yml": descriptor("PE", .purple, "checkmark.seal.fill"),
        ".periphery.yml": descriptor("PE", .purple, "checkmark.seal.fill"),
        "sourcery.yml": descriptor("SO", .orange, "wand.and.stars"),
        ".sourcery.yml": descriptor("SO", .orange, "wand.and.stars"),
        "gemfile": descriptor("RB", .red, "diamond.fill"),
        "gemfile.lock": descriptor("RB", .red, "lock.fill"),
        "rakefile": descriptor("RB", .red, "hammer.fill"),
        "brewfile": descriptor("BR", .orange, "mug.fill"),
        "composer.json": descriptor("CP", .brown, "music.note.list"),
        "composer.lock": descriptor("CP", .brown, "lock.fill"),
        "manage.py": descriptor("DJ", .green, "leaf.fill"),
        "pyproject.toml": descriptor("PY", .blue, "shippingbox.fill"),
        "requirements.txt": descriptor("PY", .blue, "list.bullet.rectangle.fill"),
        "requirements-dev.txt": descriptor("PY", .blue, "list.bullet.rectangle.fill"),
        "requirements-test.txt": descriptor("PY", .blue, "list.bullet.rectangle.fill"),
        "constraints.txt": descriptor("PY", .blue, "list.bullet.rectangle.fill"),
        "setup.py": descriptor("PY", .blue, "shippingbox.fill"),
        "setup.cfg": descriptor("PY", .blue, "gearshape.fill"),
        "tox.ini": descriptor("TX", .green, "checkmark.circle.fill"),
        "pytest.ini": descriptor("PT", .green, "checkmark.circle.fill"),
        "poetry.lock": descriptor("PO", .purple, "lock.fill"),
        "poetry.toml": descriptor("PO", .purple, "gearshape.fill"),
        "uv.lock": descriptor("UV", .purple, "lock.fill"),
        "pdm.lock": descriptor("PD", .blue, "lock.fill"),
        "pdm.toml": descriptor("PD", .blue, "gearshape.fill"),
        "pixi.toml": descriptor("PX", .purple, "shippingbox.fill"),
        "conda-lock.yml": descriptor("CN", .green, "lock.fill"),
        "pipfile": descriptor("PI", .blue, "shippingbox.fill"),
        "pipfile.lock": descriptor("PI", .blue, "lock.fill"),
        "manifest.in": descriptor("PY", .blue, "list.bullet.rectangle.fill"),
        "ruff.toml": descriptor("RF", .purple, "checkmark.seal.fill"),
        ".ruff.toml": descriptor("RF", .purple, "checkmark.seal.fill"),
        "mypy.ini": descriptor("MP", .blue, "checkmark.seal.fill"),
        "pyrightconfig.json": descriptor("PR", .blue, "checkmark.seal.fill"),
        "environment.yml": descriptor("CN", .green, "shippingbox.fill"),
        "alembic.ini": descriptor("AL", .red, "cylinder.fill"),
        "mkdocs.yml": descriptor("MK", .blue, "book.closed.fill"),
        "mkdocs.yaml": descriptor("MK", .blue, "book.closed.fill"),
        "dvc.yaml": descriptor("DVC", .purple, "point.3.connected.trianglepath.dotted"),
        "dvc.lock": descriptor("DVC", .purple, "lock.fill"),
        "py.typed": descriptor("PY", .blue, "checkmark.seal.fill"),
        "wsgi.py": descriptor("WS", .green, "server.rack"),
        "asgi.py": descriptor("AS", .green, "server.rack"),
        "celery.py": descriptor("CL", .green, "leaf.fill"),
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
        ".bazelrc": descriptor("BZ", .green, "gearshape.fill"),
        ".bazelversion": descriptor("BZ", .green, "number.square.fill"),
        "meson.build": descriptor("MS", .blue, "hammer.fill"),
        "meson_options.txt": descriptor("MS", .blue, "gearshape.fill"),
        "conanfile.txt": descriptor("CN", .blue, "shippingbox.fill"),
        "vcpkg.json": descriptor("VC", .blue, "shippingbox.fill"),
        "flake.nix": descriptor("NX", .blue, "snowflake"),
        "flake.lock": descriptor("NX", .blue, "lock.fill"),
        "shell.nix": descriptor("NX", .blue, "terminal.fill"),
        "vagrantfile": descriptor("VG", .blue, "cube.fill"),
        "procfile": descriptor("HK", .purple, "server.rack"),
        "vercel.json": descriptor("VC", .gray, "triangle.fill"),
        "netlify.toml": descriptor("NF", .teal, "network"),
        "render.yaml": descriptor("RN", .purple, "cloud.fill"),
        "firebase.json": descriptor("FB", .amber, "flame.fill"),
        "supabase.toml": descriptor("SB", .green, "bolt.fill"),
        "devcontainer.json": descriptor("DEV", .blue, "shippingbox.fill"),
        "dependabot.yml": descriptor("DB", .blue, "arrow.clockwise"),
        "renovate.json": descriptor("RV", .blue, "arrow.clockwise"),
        ".renovaterc": descriptor("RV", .blue, "arrow.clockwise"),
        "codecov.yml": descriptor("CV", .pink, "gauge.with.dots.needle.67percent"),
        ".codecov.yml": descriptor("CV", .pink, "gauge.with.dots.needle.67percent"),
        ".gitlab-ci.yml": descriptor("CI", .orange, "arrow.triangle.branch"),
        "azure-pipelines.yml": descriptor("CI", .blue, "arrow.triangle.branch"),
        "buildkite.yml": descriptor("CI", .green, "arrow.triangle.branch"),
        "bitrise.yml": descriptor("CI", .purple, "arrow.triangle.branch"),
        "appveyor.yml": descriptor("CI", .green, "arrow.triangle.branch"),
        ".travis.yml": descriptor("CI", .red, "arrow.triangle.branch"),
        "codeowners": descriptor("CO", .purple, "person.2.fill"),
        ".gitignore": descriptor("GT", .orange, "arrow.triangle.branch"),
        ".gitattributes": descriptor("GT", .orange, "arrow.triangle.branch"),
        ".gitmodules": descriptor("GT", .orange, "arrow.triangle.branch"),
        ".gitkeep": descriptor("GT", .orange, "arrow.triangle.branch"),
        ".git-blame-ignore-revs": descriptor("GT", .orange, "arrow.triangle.branch"),
        ".mailmap": descriptor("GT", .orange, "person.2.fill"),
        ".editorconfig": descriptor("EC", .orange, "slider.horizontal.3"),
        ".prettierrc": descriptor("PR", .pink, "paintbrush.fill"),
        ".prettierignore": descriptor("PR", .pink, "paintbrush.fill"),
        ".eslintrc": descriptor("ES", .indigo, "checkmark.seal.fill"),
        ".eslintignore": descriptor("ES", .indigo, "checkmark.seal.fill"),
        ".stylelintignore": descriptor("SL", .purple, "paintbrush.fill"),
        ".dockerignore": descriptor("DK", .cyan, "shippingbox.fill"),
        ".npmignore": descriptor("NP", .red, "shippingbox.fill"),
        ".vercelignore": descriptor("VC", .gray, "triangle.fill"),
        ".vscodeignore": descriptor("VS", .blue, "chevron.left.forwardslash.chevron.right"),
        ".npmrc": descriptor("NP", .red, "gearshape.fill"),
        ".nvmrc": descriptor("ND", .green, "n.square.fill"),
        ".node-version": descriptor("ND", .green, "number.square.fill"),
        ".tool-versions": descriptor("AS", .purple, "number.square.fill"),
        ".yarnrc": descriptor("YN", .blue, "gearshape.fill"),
        ".yarnrc.yml": descriptor("YN", .blue, "gearshape.fill"),
        ".babelrc": descriptor("BL", .yellow, "wand.and.stars"),
        ".swcrc": descriptor("SWC", .orange, "bolt.fill"),
        ".browserslistrc": descriptor("WB", .orange, "globe"),
        ".swift-format": descriptor("SW", .orange, "paintbrush.fill"),
        ".swiftformat": descriptor("SW", .orange, "paintbrush.fill"),
        ".swiftlint.yml": descriptor("SW", .orange, "checkmark.seal.fill"),
        ".swiftlint.yaml": descriptor("SW", .orange, "checkmark.seal.fill"),
        ".python-version": descriptor("PY", .blue, "number.square.fill"),
        ".flake8": descriptor("PY", .blue, "checkmark.seal.fill"),
        ".coveragerc": descriptor("PY", .blue, "gauge.with.dots.needle.67percent"),
        ".pre-commit-config.yaml": descriptor("PC", .orange, "checkmark.seal.fill"),
        "rust-toolchain": descriptor("RS", .orange, "hammer.fill"),
        "rust-toolchain.toml": descriptor("RS", .orange, "hammer.fill"),
        "rustfmt.toml": descriptor("RS", .orange, "paintbrush.fill"),
        ".rustfmt.toml": descriptor("RS", .orange, "paintbrush.fill"),
        "clippy.toml": descriptor("RS", .orange, "checkmark.seal.fill"),
        "deny.toml": descriptor("RS", .red, "hand.raised.fill"),
        "cross.toml": descriptor("RS", .orange, "shippingbox.fill"),
        "taplo.toml": descriptor("TP", .orange, "checkmark.seal.fill"),
        "bacon.toml": descriptor("BC", .red, "checkmark.circle.fill"),
        ".clang-format": descriptor("C", .blue, "paintbrush.fill"),
        ".clang-tidy": descriptor("C", .blue, "checkmark.seal.fill"),
        "readme": descriptor("RD", .blue, "book.closed.fill"),
        "license": descriptor("LC", .yellow, "checkmark.seal.fill"),
        "copying": descriptor("LC", .yellow, "checkmark.seal.fill"),
        "license-apache": descriptor("LC", .yellow, "checkmark.seal.fill"),
        "license-mit": descriptor("LC", .yellow, "checkmark.seal.fill"),
        "copyright": descriptor("LC", .yellow, "checkmark.seal.fill"),
        "citation.cff": descriptor("CITE", .blue, "quote.bubble.fill"),
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
        add(
            ["pyx", "pxd", "pxi"],
            descriptor("CY", .blue, "chevron.left.forwardslash.chevron.right"), to: &result)
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
        add(["coffee", "litcoffee"], descriptor("CF", .brown, "cup.and.saucer.fill"), to: &result)
        add(["d", "di"], descriptor("D", .red, "d.square.fill"), to: &result)
        add(["vb", "vbs"], descriptor("VB", .purple, "v.square.fill"), to: &result)
        add(
            ["f", "for", "f77", "f90", "f95", "f03", "f08"],
            descriptor("FT", .purple, "function"), to: &result)
        add(["pas", "pp"], descriptor("PAS", .blue, "p.square.fill"), to: &result)
        add(["nim", "nims", "nimble"], descriptor("NIM", .yellow, "n.square.fill"), to: &result)
        add(["cr"], descriptor("CR", .gray, "diamond.fill"), to: &result)
        add(["ml", "mli"], descriptor("ML", .orange, "function"), to: &result)
        add(["scm", "ss", "rkt"], descriptor("SCM", .red, "function"), to: &result)
        add(["el", "lisp", "cl"], descriptor("LSP", .purple, "parentheses"), to: &result)
        add(["vim"], descriptor("VIM", .green, "terminal.fill"), to: &result)
        add(["applescript", "scpt"], descriptor("AS", .indigo, "apple.logo"), to: &result)
        add(["awk", "sed", "tcl"], descriptor("SCR", .green, "terminal.fill"), to: &result)
        add(["qml"], descriptor("QML", .green, "q.square.fill"), to: &result)
        add(["vala", "vapi"], descriptor("VA", .purple, "v.square.fill"), to: &result)
        add(["raku", "p6"], descriptor("RA", .purple, "r.square.fill"), to: &result)
        add(["cob", "cbl"], descriptor("COB", .blue, "c.square.fill"), to: &result)
        add(["adb", "ads", "ada"], descriptor("ADA", .blue, "a.square.fill"), to: &result)
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
        add(
            ["proto", "fbs", "thrift", "capnp"],
            descriptor("IDL", .green, "square.stack.3d.up.fill"), to: &result)
        add(["edgeql"], descriptor("EDG", .purple, "cylinder.fill"), to: &result)
        add(["rego"], descriptor("OPA", .indigo, "checkmark.shield.fill"), to: &result)
        add(["cue"], descriptor("CUE", .cyan, "slider.horizontal.3"), to: &result)
        add(["dhall"], descriptor("DHL", .orange, "slider.horizontal.3"), to: &result)
        add(["ron"], descriptor("RON", .orange, "curlybraces"), to: &result)
        add(["wit"], descriptor("WIT", .purple, "w.square.fill"), to: &result)
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
            ["glsl", "vert", "frag", "hlsl", "metal", "wgsl"],
            descriptor("GPU", .purple, "sparkles.rectangle.stack.fill"), to: &result)
        add(["hip", "sycl"], descriptor("GPU", .green, "cpu.fill"), to: &result)
        add(["ll", "bc", "td", "sil", "mir"], descriptor("IR", .red, "cpu.fill"), to: &result)
        add(
            ["def", "inc", "include", "apinotes"], descriptor("API", .blue, "curlybraces"),
            to: &result)
        add(["ld", "lds", "map", "rsp"], descriptor("LNK", .orange, "link"), to: &result)
        add(["modulemap"], descriptor("MOD", .blue, "square.stack.3d.up.fill"), to: &result)
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
            ["ejs", "hbs", "handlebars", "mustache", "njk", "pug", "haml", "slim", "liquid"],
            descriptor("TPL", .orange, "curlybraces"), to: &result)
        add(
            ["j2", "jinja", "jinja2", "djtpl"], descriptor("J2", .red, "curlybraces"),
            to: &result)
        add(["mjml"], descriptor("MAIL", .red, "envelope.fill"), to: &result)
        add(
            ["tpl", "tmpl", "template", "in"], descriptor("TPL", .gray, "doc.on.doc.fill"),
            to: &result)
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
        add(
            [
                "babelrc", "browserslistrc", "coveragerc", "editorconfig", "eslintrc", "flake8",
                "flowconfig", "graphqlconfig", "npmrc", "nvmrc", "prettierrc", "swcrc", "yarnrc",
            ], descriptor("CFG", .gray, "gearshape.fill"), to: &result)
        add(
            ["code-workspace", "code-snippets", "tmlanguage"],
            descriptor("VS", .blue, "chevron.left.forwardslash.chevron.right"), to: &result)
        add(["tsbuildinfo"], descriptor("TS", .blue, "bolt.fill"), to: &result)
        add(
            ["eszip", "eszip2", "node"], descriptor("JS", .yellow, "shippingbox.fill"), to: &result)
        add(["dockerfile"], descriptor("DK", .cyan, "shippingbox.fill"), to: &result)
        add(["makefile"], descriptor("MK", .orange, "hammer.fill"), to: &result)
        add(["plist"], descriptor("PLST", .blue, "list.bullet.rectangle.fill"), to: &result)
        add(["entitlements"], descriptor("ENT", .blue, "checkmark.shield.fill"), to: &result)
        add(
            [
                "xcconfig", "pbxproj", "xcscheme", "xcworkspacedata", "xcprivacy", "xcsettings",
                "xctestplan",
            ],
            descriptor("XCD", .blue, "hammer.fill"), to: &result)
        add(["storyboard", "xib", "nib"], descriptor("UI", .blue, "macwindow"), to: &result)
        add(["storekit"], descriptor("SK", .blue, "cart.fill"), to: &result)
        add(
            ["mobileconfig", "provisionprofile"],
            descriptor("PROF", .blue, "person.crop.rectangle.fill"), to: &result)
        add(
            ["swiftdoc", "swiftinterface", "swiftmodule", "swiftoverlay", "swiftcrossimport"],
            descriptor("SW", .orange, "swift"), to: &result)
        add(["tbd", "metallib"], descriptor("APL", .indigo, "apple.logo"), to: &result)
        add(
            ["mlmodel", "mlpackage"], descriptor("ML", .blue, "brain.head.profile.fill"),
            to: &result)
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
            ["org", "pod", "roff", "man"], descriptor("DOC", .blue, "text.document.fill"),
            to: &result)
        add(["cls", "sty"], descriptor("TEX", .blue, "text.document.fill"), to: &result)
        add(
            ["mermaid", "mmd", "puml", "plantuml", "dot", "gv", "graffle", "drawio"],
            descriptor("DIA", .purple, "point.3.connected.trianglepath.dotted"), to: &result)
        add(["cff", "spdx"], descriptor("META", .blue, "checkmark.seal.fill"), to: &result)
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
                "icns", "svg", "apng", "psd", "exr", "hdr", "tga", "dds", "cur", "jp2", "jxl",
                "ktx", "ktx2", "pbm", "pgm", "ppm", "pnm", "xpm", "xcf", "qoi", "pic", "dng",
                "cr2", "nef",
            ], descriptor("IMG", .pink, "photo.fill"), to: &result)
        add(
            ["mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "aiff", "pcm", "mid", "midi"],
            descriptor("AUD", .purple, "waveform"), to: &result)
        add(
            ["mp4", "mov", "mkv", "avi", "webm", "m4v"],
            descriptor("VID", .red, "play.rectangle.fill"), to: &result)
        add(["m3u", "m3u8", "pls"], descriptor("LIST", .purple, "music.note.list"), to: &result)
        add(["vtt", "srt", "ass"], descriptor("SUB", .blue, "captions.bubble.fill"), to: &result)
        add(
            [
                "zip", "tar", "gz", "tgz", "bz2", "xz", "lzma", "7z", "rar", "br", "zst", "asar",
                "nupkg", "whl", "egg", "ipa", "apk", "deb", "rpm", "pkg", "dmg", "msi", "appimage",
            ],
            descriptor("ZIP", .brown, "archivebox.fill"), to: &result)
        add(
            ["ttf", "otf", "woff", "woff2", "eot"], descriptor("FONT", .indigo, "textformat"),
            to: &result)
        add(
            ["db", "dbf", "sqlite", "sqlite3", "mmdb", "mdb", "realm"],
            descriptor("DB", .blue, "cylinder.fill"),
            to: &result)
        add(
            ["parquet", "orc", "avro", "arrow", "feather", "h5", "hdf5", "mat"],
            descriptor("DATA", .green, "tablecells.fill"), to: &result)
        add(
            [
                "pkl", "pickle", "joblib", "npy", "npz", "pt", "pth", "onnx", "tflite",
                "safetensors",
            ],
            descriptor("ML", .purple, "brain.head.profile.fill"), to: &result)
        add(
            ["pem", "crt", "cer", "cert", "key", "csr", "der", "p12", "pfx", "keystore"],
            descriptor("KEY", .yellow, "key.fill"), to: &result)
        add(["lock", "resolved", "sum"], descriptor("LOCK", .gray, "lock.fill"), to: &result)
        add(["diff", "patch"], descriptor("DIFF", .green, "plusminus"), to: &result)
        add(["wasm", "wat"], descriptor("WASM", .purple, "w.square.fill"), to: &result)
        add(
            ["exe", "dll", "dylib", "so", "a", "bin", "class", "jar", "rlib"],
            descriptor("BIN", .gray, "cpu.fill"), to: &result)
        add(
            ["sln", "vcxproj", "csproj", "fsproj", "vbproj"],
            descriptor("VS", .purple, "hammer.fill"), to: &result)
        add(
            ["wixproj", "wxs", "wxi", "wxl", "iss", "nsi", "nsh"],
            descriptor("SETUP", .blue, "shippingbox.fill"), to: &result)
        add(["natvis"], descriptor("DBG", .purple, "ladybug.fill"), to: &result)
        add(
            ["desktop", "service", "socket", "timer"],
            descriptor("SYS", .gray, "gearshape.2.fill"), to: &result)
        add(
            ["1", "2", "3", "4", "5", "6", "7", "8", "9"],
            descriptor("MAN", .blue, "book.closed.fill"), to: &result)
        add(
            ["gltf", "glb", "obj", "fbx", "dae", "blend", "stl", "usdz"],
            descriptor("3D", .teal, "cube.fill"), to: &result)
        add(["ipynb"], descriptor("NB", .orange, "book.pages.fill"), to: &result)
        add(
            ["po", "pot", "mo", "strings", "stringsdict", "arb", "xlf", "xliff", "xmb", "xtb"],
            descriptor("I18N", .green, "globe"), to: &result)
        add(
            ["kml", "kmz", "gpx", "shp", "shx", "topojson"], descriptor("GEO", .teal, "map.fill"),
            to: &result)
        add(["pcap", "pcapng"], descriptor("NET", .cyan, "network"), to: &result)
        add(
            ["sig", "pub", "gpg", "asc", "age", "ppk"],
            descriptor("SIG", .yellow, "checkmark.seal.fill"), to: &result)
        add(
            ["bak", "old", "orig"], descriptor("BAK", .gray, "clock.arrow.circlepath"), to: &result)
        add(["sample", "example"], descriptor("SAMP", .teal, "doc.on.doc.fill"), to: &result)
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
