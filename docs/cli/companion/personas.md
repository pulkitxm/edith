# `ed companion personas`

Lists the lenses that can answer you, and how each one thinks. A persona is not a
tone: it is a spec file that sets which sources are read, how much your own account
of yourself counts against independent records, which passes run, what shape the
answer takes and how sure the lens must be before it says anything. The voice is the
last line of the file.

Usage:

```
ed companion personas [--json] [--endpoint <url>]
```

The four that ship:

| Lens | How it reads you |
| --- | --- |
| `analyst` | Evidence first. Weights records of what you did above your account of it, and says when the record is thin. |
| `friend` | Long window, high salience weighting, warm because it recalls the specific thing you said, not because it agrees. |
| `coach` | Last thirty days, commitment focused, ends with exactly one next action. |
| `skeptic` | Argues the other side. Runs a counterfactual pass and a second inverted retrieval, and abstains unless the record carries the push. |

`--json` shape: an array of `{id, label, pipeline, output, abstainBelow, maxWords,
selfReportWeight, observationWeight, k, windowDays}`.

Adding a lens is data, never code: drop a YAML spec and a voice prompt into the
directory named by `PERSONA_DIR` on the backend. Files are `<id>.yaml` and the
optional matching `<id>.md`; custom ids replace built-ins with the same id.
Malformed specs and unknown pipeline stages are skipped and written to backend
stderr. The returned list is sorted by id.

Pass any of these to [`ed companion ask`](./ask.md) with `--persona`, or ask several
at once with [`ed companion council`](./council.md). Chat also accepts
`--persona` and defaults to `friend`; ask defaults to `analyst`.

## Where to go next

- [`ed companion lenses`](./lenses.md), what each lens learned about being useful to you
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
