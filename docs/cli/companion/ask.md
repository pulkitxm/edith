# `ed companion ask`

Answers a question from your own memory, citing the episodes the answer rests on.

Usage:

```
ed companion ask <question> [--json] [--endpoint <url>]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<question>` | text | required | The question to answer. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |

`--json` shape:

```json
{
  "answer": "The auth refactor shipped in March, and it felt slower than it should have.",
  "chunksConsidered": 8,
  "citations": [
    {
      "episodeId": "ade45706-c7e0-480c-9125-11503509bef2",
      "occurredAt": "2026-03-14T00:00:00Z",
      "quote": "Shipped the auth refactor this week. Felt slower than it should have been.",
      "support": "verbatim",
      "title": "Warden retro"
    }
  ],
  "model": "anthropic, model claude-sonnet-5"
}
```

`answer` is the grounded reply, `citations` the episodes it rests on, `chunksConsidered` how many memory chunks were retrieved, and `model` the reasoner that answered. `support` types each citation: `verbatim` is checked structurally, the quote must actually appear in the cited text or the label demotes to `paraphrase`; `inference` marks the reasoner reading between the lines and renders that way.

Examples:

```
$ ed companion ask "how did the auth refactor go"
The auth refactor shipped in March, and it felt slower than it should have.
[1] Warden retro (2026-03-14T00:00:00Z)  [verbatim]
    "Shipped the auth refactor this week. Felt slower than it should have been."
```

Behaviour: the companion retrieves the eight nearest chunks by embedding, hands them to the reasoner tagged by episode id, and drops any citation that names an episode the reasoner was not shown, so an answer can only cite what it actually read. When the memory holds nothing relevant the answer says so. Needs a reasoning provider like `ed companion reflect`; exit 4 without one.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
