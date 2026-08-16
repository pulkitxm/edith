# `ed companion reflect`

Asks the companion's reasoning provider to distill durable beliefs from recent episodes.

Usage:

```
ed companion reflect [--json] [--endpoint <url>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |

`--json` shape:

```json
{
  "beliefsFormed": 2,
  "episodesConsidered": 7,
  "model": "openai-compatible at http://ollama:11434/v1, model qwen3:1.7b"
}
```

`episodesConsidered` counts the episodes read this run, `beliefsFormed` the new beliefs that survived validation, and `model` names the provider that did the thinking.

Examples:

```
$ ed companion reflect
considered 7 episodes, formed 2 beliefs (openai-compatible at http://ollama:11434/v1, model qwen3:1.7b)
```

Behaviour: the companion reads its most recent episodes and asks the configured
reasoner for two to five higher-order beliefs, each citing the episode ids it
rests on. Candidates that cite unknown episodes, cite nothing, or restate an
existing active belief are dropped. An OpenAI-compatible endpoint is selected
with `REASON_PROVIDER=openai` and `REASON_URL`. Without a configured provider,
the backend rejects the request and the CLI exits 1.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
