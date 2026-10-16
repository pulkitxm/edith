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

The downloaded extension runs its privileged role through the same signed Edith executable. If Edith reports a missing package or role, reinstall the compatible Lid Awake package from Extensions before trying again.

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

The timer and lid-cycle state are owned by the active extension worker, so closing the main Edith window does not cancel them.

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

Enable Lid Awake and keep Edith running before inspecting its active session:

```sh
ed invoke lidAwake lidAwake.status --json '{}'
ed invoke lidAwake lidAwake.on --json '{"session":"fifteenMinutes"}'
ed invoke lidAwake lidAwake.off --json '{}'
```

Starting still requires the extension's confirmation and privileged approval. See the [public invocation reference](cli/invoke/README.md) for availability and request limits.

## Attribution

The Lid Awake idea was inspired by
[Awayke](https://github.com/daemonphantom/Awayke), an MIT-licensed macOS utility by
daemonphantom.
