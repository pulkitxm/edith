import os
import pathlib
import tempfile
import unittest

from editor_parity_checks import verify_artifacts
from editor_parity_fixtures import checksum, command, ffmpeg


class ProtectedArtifactTests(unittest.TestCase):
    def test_equivalent_pcm_rewrite_invalidates_provenance(self):
        parent = pathlib.Path(os.environ.get("TMPDIR", tempfile.gettempdir())) / "opencode"
        parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as directory:
            root = pathlib.Path(directory)
            original, rewritten = root / "master.wav", root / "rewritten.wav"
            ffmpeg("-f", "lavfi", "-i", "sine=frequency=317:sample_rate=48000:duration=0.1", "-ac", "2", "-c:a", "pcm_s24le", original)
            snapshot = {original: checksum(original)}
            verify_artifacts(snapshot, "before rewrite")
            ffmpeg("-i", original, "-c:a", "copy", "-metadata", "title=Synthetic byte mutation", rewritten)
            def pcm(path):
                return command(["ffmpeg", "-v", "error", "-i", path, "-f", "s24le", "pipe:1"])
            self.assertEqual(pcm(original), pcm(rewritten))
            self.assertNotEqual(checksum(original), checksum(rewritten))
            rewritten.replace(original)
            for stage in ("after native PCM render", "after lifecycle calls", "immediately before publication"):
                with self.assertRaisesRegex(AssertionError, "Protected artifact changed"):
                    verify_artifacts(snapshot, stage)


if __name__ == "__main__":
    unittest.main()
