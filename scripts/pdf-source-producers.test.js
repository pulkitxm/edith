import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(path, "utf8");
const docker = read("apps/companion/Dockerfile");

function embeddedDocker(path) {
  const source = read(path);
  const marker = 'public static let dockerfile = #"""\n';
  const start = source.indexOf(marker);
  expect(start).toBeGreaterThan(-1);
  const content = start + marker.length;
  const end = source.indexOf('\n        """#', content);
  expect(end).toBeGreaterThan(content);
  return source
    .slice(content, end)
    .split("\n")
    .map((line) => line.slice(8))
    .join("\n");
}

test("Companion consumes only the prepared maintained PDF dependency", () => {
  const manifest = read("apps/companion/Cargo.toml");
  expect(manifest).toContain(
    'pdf-extract = { version = "0.13.0", path = "pdf-extract" }',
  );
  expect(manifest).not.toContain('pdf-extract = "0.12.0"');
  expect(read("apps/companion/src/ingest.rs")).toContain(
    "pdf_extract::extract_text_from_mem(&bytes)",
  );
  expect(read(".gitignore").split("\n")).toContain("local/");
});

test("both developer native Cargo targets require source preparation", () => {
  const make = read("Makefile");
  expect(make).toContain(
    "prepare-pdf-extract:\n\tpython3 -B apps/companion/prepare-pdf-extract.py",
  );
  expect(make).toContain("ci-companion: prepare-pdf-extract\n");
  expect(make).toContain("ci-companion-migrate: prepare-pdf-extract\n");
  expect(make).toContain(
    "ci-pdf-source-preparation:\n\tpython3 -B scripts/test-pdf-source-preparation.py",
  );
  expect(make).toContain(
    "cargo +stable clippy --all-targets --locked -- -D warnings",
  );
  expect(make).toContain("cargo +stable test --locked");
  expect(make).toContain("cargo +stable run --locked -- --migrate-only");
});

test("Linux Companion prepares sources before every locked Cargo producer", () => {
  const workflow = read(".github/workflows/ci.yml");
  const section = workflow.slice(
    workflow.indexOf("  companion:\n"),
    workflow.indexOf("  version:\n"),
  );
  const prepare = section.indexOf(
    "run: make prepare-pdf-extract ci-pdf-source-preparation",
  );
  expect(prepare).toBeGreaterThan(-1);
  for (const command of [
    "cargo clippy --all-targets --locked -- -D warnings",
    "cargo test --locked",
    "cargo run --locked -- --migrate-only",
  ]) {
    expect(section.indexOf(command)).toBeGreaterThan(prepare);
  }
});

test("actual and both deployed Dockerfiles prepare identical pinned sources", () => {
  expect(docker).toContain("RUN apk add --no-cache musl-dev python3");
  expect(docker).toContain(
    "COPY Cargo.toml Cargo.lock prepare-pdf-extract.py ./\nCOPY pdf-extract/Cargo.toml pdf-extract/\nRUN python3 -B prepare-pdf-extract.py",
  );
  expect(docker.indexOf("RUN cargo build --release --locked")).toBeGreaterThan(
    docker.indexOf("RUN python3 -B prepare-pdf-extract.py"),
  );
  for (const path of [
    "Extensions/companion/Models/CompanionRuntimeFiles.swift",
    "Packages/Edith/Sources/EdithKit/Features/Companion/Models/CompanionRuntimeFiles.swift",
  ]) {
    expect(embeddedDocker(path)).toBe(docker);
  }
});

test("direct developer Cargo instructions prepare the source first", () => {
  const docs = read("CONTRIBUTING.md");
  expect(docs).toContain(
    "make prepare-pdf-extract\ncd apps/companion\ncargo clippy --all-targets --locked -- -D warnings",
  );
});

test("the locked graph uses the owned source and removes the advisory parser", () => {
  const lock = read("apps/companion/Cargo.lock");
  const records = lock.split("[[package]]");
  const pdf = records.find((record) => record.includes('name = "pdf-extract"'));
  expect(pdf).toContain('version = "0.13.0"');
  expect(pdf).not.toContain("source =");
  expect(pdf).not.toContain("checksum =");
  expect(records.find((record) => record.includes('name = "lopdf"'))).toContain(
    'version = "0.45.0"',
  );
  expect(records.some((record) => record.includes('name = "ttf-parser"'))).toBe(
    false,
  );
  expect(records.some((record) => record.includes('name = "skrifa"'))).toBe(
    false,
  );
});

test("the hosted container proof builds the final image and checks its original user and tools", () => {
  const workflow = read(".github/workflows/ci.yml");
  const section = workflow.slice(
    workflow.indexOf("  companion:\n"),
    workflow.indexOf("  version:\n"),
  );
  const build =
    "docker build --progress=plain --tag edith-companion-pdf-check --file apps/companion/Dockerfile apps/companion";
  const position = section.indexOf(build);
  expect(position).toBeGreaterThan(section.indexOf("cargo test --locked"));
  expect(position).toBeLessThan(
    section.indexOf("cargo run --locked -- --migrate-only"),
  );
  expect(section).toContain(
    "docker image inspect --format '{{ .Config.User }}' edith-companion-pdf-check",
  );
  expect(section).toContain(
    "docker run --rm --network none --entrypoint /bin/sh edith-companion-pdf-check",
  );
  expect(section).toContain(
    'test -x /usr/local/bin/companion && test "$(id -un)" = companion && command -v ffmpeg && command -v exiftool',
  );
  expect(section).not.toContain("--target builder");
});

test("the real PDF path manifest is available before generated sources and retains its locked graph", () => {
  const companion = Bun.TOML.parse(read("apps/companion/Cargo.toml"));
  const dependency = companion.dependencies["pdf-extract"];
  const source = Bun.TOML.parse(
    read(`apps/companion/${dependency.path}/Cargo.toml`),
  );
  expect(dependency).toEqual({ version: "0.13.0", path: "pdf-extract" });
  expect(source.package.name).toBe("pdf-extract");
  expect(source.package.version).toBe(dependency.version);
  expect(source.package.license).toBe("MIT");
  expect(source.dependencies.lopdf).toEqual({
    version: "0.45",
    "default-features": false,
    features: ["wasm_js"],
  });
  expect(source.lib).toBeUndefined();
  expect(
    Object.values(source.dependencies).some(
      (value) => typeof value === "object" && "path" in value,
    ),
  ).toBe(false);
  expect(read(".gitignore")).toContain(
    "apps/companion/pdf-extract/*\n!apps/companion/pdf-extract/Cargo.toml",
  );
});
