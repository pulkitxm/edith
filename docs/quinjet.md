# Quinjet integration

Edith embeds Quinjet for local and SSH project review while keeping project selection in native SwiftUI.

## Added

- Recent projects, live folder browsing, worktrees, and tabs across the local Mac and SSH machines.
- Embedded or cmux terminals, persistent themes, exact project paths, and stable terminal restarts.
- `N`, `Shift+N`, and `W` open Edith tabs or worktree pickers when Quinjet is embedded.

## Edith client mode

Embedded launches pass `--client edith`. In that mode Quinjet hides quit actions, disables its native new-project and worktree flows, and sends those actions back to Edith. The flag is opt-in, so regular Quinjet launches and external cmux sessions keep their standard behavior.
