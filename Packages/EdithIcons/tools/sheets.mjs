import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const tools = dirname(new URL(import.meta.url).pathname);
const output = resolve(join(tools, "../../../local/icons"));
const focus = process.argv[2];
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("EDITH_")));
env.DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer";

mkdirSync(output, { recursive: true });
const args = ["run", "--package-path", join(tools, "preview"), "preview", output];
execFileSync("swift", focus ? [...args, focus] : args, { stdio: "inherit", env });
console.log(`sheets written to ${output}`);
