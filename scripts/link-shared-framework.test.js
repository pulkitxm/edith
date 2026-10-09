import { expect, test } from "bun:test";
import { basename } from "node:path";

function objects(suffix, fileList, missing = false) {
  const result = Bun.spawnSync(
    [
      "python3",
      "-B",
      "-c",
      `import importlib.util, json, pathlib, sys, tempfile
spec = importlib.util.spec_from_file_location('framework', 'scripts/link-shared-framework.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
suffix, file_list, missing = sys.argv[1:]
with tempfile.TemporaryDirectory(prefix='framework-layout-') as directory:
    root = pathlib.Path(directory)
    for config in ('Debug', 'Release'):
        for name in module.MODULES:
            if missing == '1' and name == 'EdithCore':
                continue
            target = root / 'Build/Intermediates.noindex/Edith.build' / config / (name + suffix + '.build') / 'Objects-normal/arm64'
            target.mkdir(parents=True)
            compiled = target / (name + '.o')
            compiled.write_bytes(b'synthetic object')
            if file_list == '1':
                (target / (name + '.LinkFileList')).write_text(str(compiled) + '\\n')
    try:
        found = module.object_list(root, 'Release')
        print(json.dumps({'objects': [str(pathlib.Path(path).relative_to(root)) for path in found]}))
    except SystemExit as error:
        print(json.dumps({'error': str(error)}))`,
      suffix,
      fileList ? "1" : "0",
      missing ? "1" : "0",
    ],
    { stdout: "pipe", stderr: "pipe", timeout: 15000 },
  );
  expect(result.exitCode).toBe(0);
  expect(result.stderr.toString()).toBe("");
  return JSON.parse(result.stdout.toString());
}

for (const suffix of ["", "-t"]) {
  for (const fileList of [true, false]) {
    test(`framework objects use Release artifacts in ${suffix || "plain"} targets with file lists ${fileList}`, () => {
      const result = objects(suffix, fileList);
      expect(result.objects.map((path) => basename(path)).sort()).toEqual([
        "EdithCameraSupport.o",
        "EdithCore.o",
        "EdithDatabase.o",
        "EdithKit.o",
        "EdithLidAwakeSupport.o",
        "EdithShared.o",
      ]);
      for (const path of result.objects) {
        expect(path).toContain("/Release/");
        expect(path).toEndWith(".o");
      }
      expect(result.error).toBeUndefined();
    });
  }
}

test("missing module objects fail before the shared framework is linked", () => {
  const result = objects("", true, true);
  expect(result.error).toContain(
    "missing shared framework objects for EdithCore",
  );
  expect(result.objects).toBeUndefined();
});
