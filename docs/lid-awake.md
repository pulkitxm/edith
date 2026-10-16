# Lid Awake

Lid Awake keeps an Apple Silicon Mac running after its display lid closes, even
without a charger or external display. It is separate from the ordinary Keep Awake
action: Keep Awake prevents idle sleep, while Lid Awake changes the system's
closed-lid sleep policy.

## Enable it

Turn on the Lid Awake extension in Settings, then activate it from Settings, the
Home quick actions, the sidebar or the command line. The first activation can open
System Settings so you can approve Edith's background item. This is a one-time
approval for the helper that applies the privileged power setting. Later toggles
are silent.

The signed helper is embedded inside Edith's menu bar companion. If Edith reports
that it is missing, reinstall the current app and reopen it before trying again.

## Session choices

Choose one policy before starting:

| Session | Stops when |
| --- | --- |
| Indefinitely | You turn Lid Awake off. |
| 15 minutes | The timer expires. |
| 30 minutes | The timer expires. |
| 1 hour | The timer expires. |
| 2 hours | The timer expires. |
| Until lid reopens | The lid has closed and then opens again. |

The timer and lid-cycle state are owned by the always-on menu bar companion, so
closing the main Edith window does not cancel them.

## Battery and quit behavior

The optional battery floor can pause Lid Awake below 10, 20 or 30 percent while the
Mac is unplugged. It resumes after charging above the floor with a small safety
margin. Starting Lid Awake manually while already below the floor overrides the
pause for that discharge.

Keep **Restore normal sleep when Edith quits** enabled unless you deliberately want
the changed policy to survive the app quitting. Turning the Lid Awake extension off
always restores normal sleep, regardless of that setting.

## Safety

A closed Mac that remains awake keeps using power and producing heat. Do not put it
in a bag or another enclosed space while Lid Awake is active. Set a time limit or a
battery floor for unattended work, and confirm that the task no longer needs the
machine before leaving it closed for a long period.

Use `ed lid-awake status --json` to inspect the active session, deadline, battery
pause and helper registration. The complete command workflows are in the
[Lid Awake command reference](cli/lid-awake/README.md).

## Attribution

The Lid Awake idea was inspired by
[Awayke](https://github.com/daemonphantom/Awayke), an MIT-licensed macOS utility by
daemonphantom.
