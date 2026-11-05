import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const root = join(dirname(new URL(import.meta.url).pathname), "..");
const svgDirectory = join(root, "svg");
const output = join(root, "Sources/EdithIcons/EdithIcon.generated.swift");
const grids = [16, 20] as const;
const pathGrammar = /^(?:[MLHVQCZ]|[-\d.]+|\s)*$/;

type Layers = { primary: string; secondary: string };

function layer(source: string, id: string, file: string): string {
  const match = source.match(new RegExp(`<path id="${id}"[^>]*\\sd="([^"]*)"`));
  const data = match?.[1] ?? "";
  if (!pathGrammar.test(data)) {
    throw new Error(`${file}: ${id} uses unsupported path commands; export absolute outlines`);
  }
  return data;
}

function read(name: string, grid: number): Layers {
  const file = `${name}.${grid}.svg`;
  const source = readFileSync(join(svgDirectory, file), "utf8");
  if (!source.includes(`viewBox="0 0 ${grid} ${grid}"`)) {
    throw new Error(`${file}: viewBox must be 0 0 ${grid} ${grid}`);
  }
  if (/<(rect|circle|ellipse|line|polygon|polyline|mask|use|image)\b/.test(source)) {
    throw new Error(`${file}: outline every shape into primary and secondary paths`);
  }
  const layers = {
    primary: layer(source, "primary", file),
    secondary: layer(source, "secondary", file),
  };
  if (!layers.primary) throw new Error(`${file}: primary path is required`);
  return layers;
}

function names(): string[] {
  const found = new Map<string, Set<number>>();
  for (const file of readdirSync(svgDirectory)) {
    const match = file.match(/^(\w+)\.(16|20)\.svg$/);
    if (!match) throw new Error(`unexpected file in svg: ${file}`);
    const [, name, grid] = match;
    found.set(name, (found.get(name) ?? new Set()).add(Number(grid)));
  }
  for (const [name, cuts] of found) {
    if (cuts.size !== grids.length) throw new Error(`${name}: both optical cuts are required`);
  }
  return [...found.keys()].sort();
}

function dataCases(icons: string[], grid: number, key: keyof Layers): string {
  return icons.map((name) => `        case .${name}: "${read(name, grid)[key]}"`).join("\n");
}

function render(): string {
  const icons = names();
  const cases = icons.map((name) => `    case ${name}`).join("\n");
  const accessor = (name: string, grid: number, key: keyof Layers) => `    private var ${name}: String {
        switch self {
${dataCases(icons, grid, key)}
        }
    }
`;
  return `import Foundation

public enum EdithIcon: String, CaseIterable, Sendable {
${cases}
}

extension EdithIcon {
    public func pathData(_ layer: EdithIconLayer, cut: EdithIconCut) -> String {
        switch (cut, layer) {
        case (.small, .primary): smallPrimary
        case (.small, .secondary): smallSecondary
        case (.regular, .primary): regularPrimary
        case (.regular, .secondary): regularSecondary
        }
    }

${accessor("smallPrimary", 16, "primary")}
${accessor("smallSecondary", 16, "secondary")}
${accessor("regularPrimary", 20, "primary")}
${accessor("regularSecondary", 20, "secondary")}}
`;
}

const generated = render();
if (process.argv.includes("--check")) {
  if (readFileSync(output, "utf8") !== generated) {
    console.error("EdithIcon.generated.swift does not match svg. Run bun scripts/generate.ts");
    process.exit(1);
  }
} else {
  writeFileSync(output, generated);
}
