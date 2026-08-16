# `ed companion ask`

Answers a question from your own memory, citing the episodes the answer rests on.

Usage:

```
ed companion ask <question> [--persona <id>] [--json] [--endpoint <url>]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<question>` | text | required | The question to answer. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |
| `--persona` | persona id | `analyst` | Chooses the retrieval, evidence, reasoning and output policy. |

`--json` shape:

```json
{
  "abstained": false,
  "answer": "The auth refactor shipped in March, and it felt slower than it should have.",
  "chunksConsidered": 10,
  "citations": [
    {
      "episodeId": "ade45706-c7e0-480c-9125-11503509bef2",
      "occurredAt": "2026-03-14T00:00:00Z",
      "quote": "Shipped the auth refactor this week. Felt slower than it should have been.",
      "support": "verbatim",
      "title": "Warden retro"
    }
  ],
  "grounding": {
    "score": 0.81,
    "scorer": "lexical",
    "unsupported": []
  },
  "model": "openai-compatible at http://ollama:11434/v1, model qwen3:1.7b",
  "opinion": null,
  "persona": "analyst",
  "reframed": "What does the record show about the auth refactor's outcome and pace?",
  "stages": ["reframe_question", "retrieve", "counterfactual", "draft", "ground_check", "revise"]
}
```

`answer` is the reply, `citations` names its source episodes,
`chunksConsidered` is the persona's final chunk count, and `model` is the active
reasoner. `persona` and `stages` make the policy explicit. `reframed` records a
better evidence-seeking form of the question when that stage ran. `grounding`
holds the score, scorer and unsupported sentences. `abstained` says the score
fell below the persona's threshold. `opinion` is a clearly separated judgment
when the selected pipeline produced one.

`support` types each citation. A claimed `verbatim` quote must actually occur
in the cited chunk or it is demoted to `paraphrase`; `inference` marks the
reasoner reading between the lines and renders that way.

Examples:

```
$ ed companion ask "how did the auth refactor go"
The auth refactor shipped in March, and it felt slower than it should have.
[1] Warden retro (2026-03-14T00:00:00Z)  [verbatim]
    "Shipped the auth refactor this week. Felt slower than it should have been."
```

Behaviour: the default analyst searches the last 365 days and asks for 10
chunks. Retrieval fuses vector, keyword and entity-graph candidates, then also
loads relevant beliefs and independent observations. The selected persona can
reframe the question, seek counter-evidence, draft, ground-check and revise.
The server drops citations to episodes it did not retrieve. When evidence is
too weak, the persona abstains instead of forcing an answer. An unknown persona
is rejected by the backend. This command needs a configured reasoning provider;
backend failures, including no provider, exit 1, while an unreachable endpoint
exits 4.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
