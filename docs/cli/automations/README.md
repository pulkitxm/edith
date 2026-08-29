# `ed automations`

`ed automations` reads, previews, runs, enables, disables, imports, and exports Edith's local automations and reusable scenes. Configuration lives in `~/Library/Application Support/Edith/automations.json`. `ed automations` with no subcommand runs `ed automations ls`.

| Command | What it does |
| --- | --- |
| `ed automations operations` | Lists the existing Edith operations that scene actions may compose. |
| `ed automations ls` | Lists scenes and automations, or emits the complete document with `--json`. |
| `ed automations plan <scene>` | Resolves ordered commands, effects, timeouts, and missing permissions without running. |
| `ed automations run <scene>` | Runs a scene and records per-step results. `--dry-run` prints commands, and `--yes` approves previewed or destructive steps. |
| `ed automations enable <name>` | Enables a scene or automation by name or UUID. |
| `ed automations disable <name>` | Disables a scene or automation by name or UUID. |
| `ed automations history --limit 20` | Shows bounded local run history. |
| `ed automations export <path>` | Writes the configuration document as JSON. |
| `ed automations import <path>` | Validates with `--dry-run` or replaces local configuration with `--yes`. |

The extension itself is controlled independently with `ed extensions enable automations` and `ed extensions disable automations`. Manual CLI planning and configuration remain available while the extension is off, but background triggers and shortcuts do not run.

Every action must resolve to `UserOperationCatalog`. Automation control operations are excluded from scene steps to prevent recursive process chains. The executor also prevents the same scene from running twice, applies its cooldown, checks permissions, enforces each step timeout, honors cancellation, and records ordered results.

Return to the [CLI index](../README.md).
