import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

const directory = join(dirname(new URL(import.meta.url).pathname), "../svg");
const failures = [];

for (const file of readdirSync(directory).sort()) {
  const source = readFileSync(join(directory, file), "utf8");
  for (const [, data] of source.matchAll(/ d="([^"]*)"/g)) {
    let previous = null;
    for (const [, command, args] of data.matchAll(/([MLQCZ])([^MLQCZ]*)/g)) {
      if (command === "Z") {
        previous = null;
        continue;
      }
      const numbers = args.trim().split(/\s+/).map(Number);
      const point = numbers.slice(-2);
      if (command === "L" && previous) {
        const [dx, dy] = [Math.abs(point[0] - previous[0]), Math.abs(point[1] - previous[1])];
        const off = (value) => Math.abs(value - Math.round(value)) > 0.01;
        if (dx < 0.001 && dy > 0.4 && off(point[0])) failures.push(`${file} x=${point[0]}`);
        if (dy < 0.001 && dx > 0.4 && off(point[1])) failures.push(`${file} y=${point[1]}`);
      }
      previous = point;
    }
  }
}

const unique = [...new Set(failures)];
console.log(unique.join("\n"));
console.log(`${unique.length} off-grid axis edges`);
process.exitCode = unique.length ? 1 : 0;
