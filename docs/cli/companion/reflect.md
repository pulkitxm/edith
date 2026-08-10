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
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |

`--json` shape:

```json
{
  "beliefsFormed": 2,
  "episodesConsidered": 7,
  "model": "anthropic, model claude-sonnet-5"
}
```

`episodesConsidered` counts the episodes read this run, `beliefsFormed` the new beliefs that survived validation, and `model` names the provider that did the thinking.

Examples:

```
$ ed companion reflect
considered 7 episodes, formed 2 beliefs (anthropic, model claude-sonnet-5)
```

Behaviour: the companion reads its most recent episodes and asks the configured reasoner for two to five higher-order beliefs, each citing the episode ids it rests on. Candidates that cite unknown episodes, cite nothing, or restate an existing active belief are dropped. The provider is Anthropic when `ANTHROPIC_API_KEY` is set on the companion, or any OpenAI-compatible endpoint via `REASON_PROVIDER=openai` and `REASON_URL`; with neither configured the command fails with exit 4.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
