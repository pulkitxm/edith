# `ed focus`

`ed focus` controls the optional Focus Profiles extension. Profiles compose
Automations scenes, app launch and quit sets, layout hooks, configuration state,
and explicit rollback scenes into a session that restores its captured state
when it ends.

| Command | What it does |
| --- | --- |
| `ed focus ls` | Lists configured profiles. |
| `ed focus status` | Shows the active profile, start time, optional end time, and activation source. A bare `ed focus` runs this command. |
| `ed focus start <profile>` | Starts a profile by name or UUID. Use `--for 50m` or `--until 17:30` to override its default duration. |
| `ed focus stop` | Ends the active session and runs meeting end scenes, rollback scenes, and captured restoration actions. |
| `ed focus history` | Lists bounded, local session results without meeting titles or event details. |

```bash
ed focus ls
ed focus start "Deep work" --for 50m
ed focus start "Meeting" --until 17:30
ed focus status --json
ed focus stop
ed focus history --limit 10 --json
```

`ed focus ls`, `status`, and `history` can read local state while Edith is
closed. Starting and stopping require the menu bar helper because it owns scene
execution and restoration. Those commands exit 4 when the helper is unavailable
or silent.

`--for` accepts a positive whole number of minutes or hours, including values
such as `25m`, `90m`, and `1.5h`. `--until` accepts a future ISO 8601 date or a
local 24-hour time. `--for` and `--until` cannot be combined.

Every command accepts `--json`. Read commands emit a single document on stdout.
Mutating commands emit a result only after the helper acknowledges the action.
Failures leave stdout empty and put diagnostics on stderr.

Focus Profiles remains off until enabled with
`ed extensions enable focusProfiles`. Meeting Mode is configured in Edith
settings and only reads events through Edith Calendar when both extensions and
Calendar permission are enabled.

## Where to go next

- The Focus Profiles and Meeting Mode guide at `docs/focus-profiles.md` for
  profile design, scheduling, recovery, and privacy behavior.
- [`ed automations`](../automations/README.md) for scenes and scheduled triggers.
- [The `ed` command line](../README.md) for the rest of the reference.
