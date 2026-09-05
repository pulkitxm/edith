import { expect, test } from "bun:test";

function python(source) {
  const result = Bun.spawnSync(["python3", "-B", "-c", source], {
    stdout: "pipe",
    stderr: "pipe",
    timeout: 15000,
  });
  const output = result.stdout.toString();
  const error = result.stderr.toString();
  expect(error).toBe("");
  expect(result.exitCode).toBe(0);
  return JSON.parse(output);
}

test("fixture copies preserve metadata and isolate subsequent byte changes", () => {
  const result = python(`import hashlib, json, os, pathlib, tempfile
from scripts.edith_fixture_copy import copy_fixture_file
with tempfile.TemporaryDirectory(prefix='edith-copy-test-') as folder:
    root = pathlib.Path(folder)
    source = root / 'source'
    destination = root / 'copy'
    source.write_bytes(b'fixture bytes' * 8192)
    source.chmod(0o750)
    os.utime(source, (1700000000, 1700000000))
    original = hashlib.sha256(source.read_bytes()).hexdigest()
    copy_fixture_file(source, destination)
    same_bytes = destination.read_bytes() == source.read_bytes()
    same_metadata = (source.stat().st_mode, source.stat().st_mtime_ns) == (destination.stat().st_mode, destination.stat().st_mtime_ns)
    separate_inode = source.stat().st_ino != destination.stat().st_ino
    with destination.open('r+b') as stream:
        stream.write(b'changed')
    print(json.dumps(dict(sameBytes=same_bytes, sameMetadata=same_metadata,
        separateInode=separate_inode, sourceUnchanged=hashlib.sha256(source.read_bytes()).hexdigest() == original,
        destinationChanged=hashlib.sha256(destination.read_bytes()).hexdigest() != original)))`);
  expect(result).toEqual({
    sameBytes: true,
    sameMetadata: true,
    separateInode: true,
    sourceUnchanged: true,
    destinationChanged: true,
  });
});

test("fixture tree copying preserves framework aliases and isolates its executable", () => {
  const result = python(`import json, pathlib, shutil, tempfile
from scripts.edith_fixture_copy import copy_fixture_file
with tempfile.TemporaryDirectory(prefix='edith-copy-tree-') as folder:
    root = pathlib.Path(folder)
    source = root / 'Source.framework'
    binary = source / 'Versions/A/Executable'
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b'framework fixture')
    (source / 'Versions/Current').symlink_to('A', target_is_directory=True)
    (source / 'Executable').symlink_to('Versions/Current/Executable')
    destination = root / 'Copy.framework'
    shutil.copytree(source, destination, symlinks=True, copy_function=copy_fixture_file)
    copied = destination / 'Versions/A/Executable'
    separate_inode = copied.stat().st_ino != binary.stat().st_ino
    copied.write_bytes(b'changed fixture')
    print(json.dumps(dict(aliasPreserved=(destination / 'Executable').is_symlink(),
        targetPreserved=(destination / 'Versions/Current').readlink().as_posix() == 'A',
        separateInode=separate_inode, sourceUnchanged=binary.read_bytes() == b'framework fixture')))`);
  expect(result).toEqual({
    aliasPreserved: true,
    targetPreserved: true,
    separateInode: true,
    sourceUnchanged: true,
  });
});

test.skipIf(process.platform !== "darwin")(
  "signing a private native executable leaves its source hash unchanged",
  () => {
    const result =
      python(`import hashlib, json, pathlib, shutil, subprocess, tempfile
from scripts.edith_fixture_copy import copy_fixture_file
with tempfile.TemporaryDirectory(prefix='edith-copy-signing-') as folder:
    root = pathlib.Path(folder)
    source = root / 'source'
    destination = root / 'copy'
    shutil.copyfile('/usr/bin/true', source)
    source.chmod(0o755)
    original = hashlib.sha256(source.read_bytes()).hexdigest()
    copy_fixture_file(source, destination)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier',
        'com.pulkit.edith.fixture-copy', str(destination)], check=True, capture_output=True, timeout=10)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(destination)],
        check=True, capture_output=True, timeout=10)
    print(json.dumps(dict(separateInode=source.stat().st_ino != destination.stat().st_ino,
        sourceUnchanged=hashlib.sha256(source.read_bytes()).hexdigest() == original,
        signedCopyChanged=hashlib.sha256(destination.read_bytes()).hexdigest() != original)))`);
    expect(result).toEqual({
      separateInode: true,
      sourceUnchanged: true,
      signedCopyChanged: true,
    });
  },
);
