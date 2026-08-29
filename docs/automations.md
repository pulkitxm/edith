# Automations & Scenes

Automations & Scenes is an opt-in local extension. A scene is an ordered list of existing Edith operations. An automation connects one trigger to one reusable scene. Edith resolves every step through its operation catalog and runs the corresponding `ed` command, so an action has the same validation and behavior whether it comes from the app, menu panel, Command Bar, shortcut, CLI, or trigger.

Supported triggers are schedules with weekday selection, app launch and termination, adapter or battery power, battery threshold crossings, display attach and detach, screen lock and unlock, wake, network reachability changes, and Calendar event starts or ends. Calendar subscriptions are active only while both Calendar and Automations are enabled.

Each action stores an operation id, typed argument list, required permissions, and a timeout. Preview shows the resolved command, effect, confirmation requirement, missing permissions, and timeout before execution. Scenes run in order with either stop or continue-on-error behavior. Active-scene recursion, non-positive timeouts, nested automation control actions, and cooldown violations are rejected.

Execution history stays in `~/Library/Application Support/Edith/automation-history.json`. Edith retains at most 200 runs and removes entries older than 30 days. Configuration stays beside it in `automations.json`, can be imported or exported, and is included when settings are backed up. Disabling the extension removes every event subscription, timer, reachability monitor, and scene shortcut.

Use `ed automations operations` to discover action ids, `ed automations plan <scene>` to dry-run a scene, and `ed automations run <scene>` to run it manually. See the [CLI reference](./cli/automations/README.md) for the complete command surface.
