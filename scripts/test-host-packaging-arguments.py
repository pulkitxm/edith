import itertools
import os
import pathlib
import shlex
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "build.sh").read_text()


def source_block(start, end):
    return SOURCE[SOURCE.index(start) : SOURCE.index(end, SOURCE.index(start))]


def capture_arguments(body, values, function):
    with tempfile.TemporaryDirectory(prefix="host-packaging-arguments-") as directory:
        output = pathlib.Path(directory) / "arguments"
        assignments = "\n".join(
            f"{name}={shlex.quote(value)}" for name, value in values.items()
        )
        capture = f"{function}() {{ printf '%s\\0' \"$@\" > \"$OUTPUT\"; }}"
        script = f"set -euo pipefail\n{assignments}\n{capture}\nnode() {{ :; }}\n{body}"
        environment = {
            "PATH": "/usr/bin:/bin",
            "OUTPUT": str(output),
            "TMPDIR": os.environ.get("TMPDIR", directory),
        }
        result = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", script],
            env=environment,
            capture_output=True,
            timeout=5,
            check=False,
        )
        if result.returncode:
            raise AssertionError(result.stderr.decode(errors="replace"))
        return output.read_bytes().split(b"\0")[:-1]


class HostPackagingArgumentsTests(unittest.TestCase):
    def test_packaging_preserves_each_mode_without_empty_array_expansion(self):
        block = source_block("PACKAGE_ARGUMENTS=", 'APP="dist/Edith.app"')
        for release, version, build, slot in itertools.product(
            ("0", "1"), ("", "0.0.999"), ("", "999"), ("", "fixture slot")
        ):
            with self.subTest(release=release, version=version, build=build, slot=slot):
                values = {
                    "SIGN_IDENTITY": "Synthetic signer with spaces",
                    "RELEASE": release,
                    "RELEASE_VERSION": version,
                    "RELEASE_BUILD": build,
                    "SLOT": slot,
                }
                actual = capture_arguments(block, values, "python3")
                expected = [
                    "scripts/package-shipping-host.py",
                    "local/minimal-host/Edith.app",
                    "dist/Edith.app",
                    "--identity",
                    values["SIGN_IDENTITY"],
                ]
                if release == "1" and (version or build):
                    expected.extend(("--version", version, "--build", build))
                if slot:
                    expected.extend(("--slot", slot))
                if release == "1":
                    expected.append("--release")
                self.assertEqual(actual, [value.encode() for value in expected])

    def test_unset_release_metadata_is_safe(self):
        block = source_block("PACKAGE_ARGUMENTS=", 'APP="dist/Edith.app"')
        actual = capture_arguments(
            block,
            {"SIGN_IDENTITY": "-", "RELEASE": "1", "SLOT": ""},
            "python3",
        )
        self.assertEqual(actual[-3:], [b"--identity", b"-", b"--release"])

    def test_branch_dispatch_preserves_all_flag_combinations(self):
        block = source_block('    BUILD_ARGUMENTS=("$ROOT/build.sh")', "  fi\nfi\n")
        options = (
            ("INSTALL", "--install"),
            ("NO_OPEN", "--no-open"),
            ("BACKGROUND", "--background"),
            ("RELEASE", "--release"),
        )
        for selected in itertools.product(("0", "1"), repeat=len(options)):
            with self.subTest(selected=selected):
                values = {"ROOT": "/synthetic fixture/worktree"}
                values.update(zip((name for name, _ in options), selected))
                actual = capture_arguments(block, values, "exec")
                expected = ["/synthetic fixture/worktree/build.sh"]
                expected.extend(
                    flag for (name, flag), value in zip(options, selected) if value == "1"
                )
                self.assertEqual(actual, [value.encode() for value in expected])


if __name__ == "__main__":
    unittest.main()
