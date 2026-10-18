import { execFileSync } from "node:child_process";

const discovery = `import importlib.util, json, sys, unittest
sys.path.insert(0, "scripts")
spec = importlib.util.spec_from_file_location("host_size_cases", "scripts/test-extension-host-size-report.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def identifiers(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from identifiers(item)
        else:
            prefix = "host_size_cases."
            identity = item.id()
            if not identity.startswith(prefix):
                raise ValueError("Foreign size test module")
            yield identity[len(prefix):]
print(json.dumps(list(identifiers(unittest.defaultTestLoader.loadTestsFromModule(module)))))`;

export function validateHostSizeTestInventory(value) {
  if (
    !Array.isArray(value) ||
    value.length !== 29 ||
    value.some(
      (identifier) =>
        typeof identifier !== "string" ||
        identifier.trim() !== identifier ||
        !/^HostSizeReportTests\.test_[a-z][a-z0-9_]*$/.test(identifier),
    ) ||
    new Set(value).size !== value.length
  ) {
    throw new Error("Expected exactly 29 unique closed host size tests");
  }
  return Object.freeze([...value]);
}

export function discoverHostSizeTests() {
  const output = execFileSync("python3", ["-B", "-c", discovery], {
    encoding: "utf8",
    timeout: 60000,
    maxBuffer: 65536,
  });
  return validateHostSizeTestInventory(JSON.parse(output));
}
