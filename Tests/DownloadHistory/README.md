# Download history fixtures

`python3 scripts/test-download-history.py <fresh-private-fixture-directory>` builds a Foundation-only package from the current music and downloads queue sources. Set `HOME` and `CFFIXED_USER_HOME` to the same fresh synthetic home under the fixture directory's parent, with synthetic `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, and `TMPDIR`. Use `PYTHONDONTWRITEBYTECODE=1` and the Xcode developer directory. The runner uses one build job.

The generated package records every source SHA-256 in `source-receipts.json`. It contains separate owner modules and a synthetic child executable. Both owners use injected fake runners. Boundary adapters fail if local command execution or defaults access is attempted. Native service owners, renderers, download tools, networking, and media playback are excluded.

Fixtures seed the original `Edith/data/downloads.json` location under a private source root. They verify retained files and source associations, worker replacement, development storage isolation, concurrent mutations, corrupt-history protection, shared progress, cross-owner cancellation and retry, late completions, scheduler handoff, restart recovery, and separate-process admission serialization.
