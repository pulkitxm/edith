# `ed companion chat`

Talks with the companion. Retrieval grounds the reply in your own episodes, the
reply streams to stdout as the model produces it, and validated citations print
after it. Every exchange persists, so a conversation can be continued later
from any machine.

Usage:

```
ed companion chat <message> [--conversation <id>] [--json] [--endpoint <url>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--conversation` | conversation id | new conversation | Continues that conversation with its history in context. |
| `--json` | flag | off | Suppresses streaming and emits one JSON document at the end. |
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |

`--json` shape:

```json
{
  "answer": "You shipped the auth refactor and kept avoiding the billing migration.",
  "chunksConsidered": 8,
  "citations": [
    {
      "episodeId": "6a7c1f0e-6f0f-4bb0-9d3a-2f6f6f0e1a2b",
      "occurredAt": "2026-08-05T09:00:00Z",
      "quote": "shipped the session-scoped tokens today",
      "support": "verbatim",
      "title": "auth-refactor.md"
    }
  ],
  "conversationId": "e3b6d2a4-27c8-4f7c-9b7e-3e2b1a0c9d8f",
  "latencyMs": 1874,
  "model": "anthropic, model claude-sonnet-5"
}
```

The conversation id prints on stderr after a plain-text chat; pass it back with
`--conversation` to keep talking in the same thread.

Behaviour: requires a configured reasoning provider (`ed companion reason`);
without one the backend answers 412 and the command exits `4`.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
