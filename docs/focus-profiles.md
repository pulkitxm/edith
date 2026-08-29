# Focus Profiles and Meeting Mode

Focus Profiles is an optional, local extension for turning reusable Edith scenes into a session that can be started, timed, and safely restored. It uses the Automations planner and executor for every action.

## Profiles

A profile can combine:

- one or more start scenes;
- a separate window layout scene, which is the hook for Window Tools actions;
- application bundle identifiers to launch or quit;
- explicit rollback scenes;
- a default duration, notification guidance, exclusions, and a global shortcut.

Use scene actions such as `config set micMuted true`, `config set preventSleep true`, and any supported audio, display, power, or Window Tools operation. Focus Profiles snapshots configuration values changed by `config set` and restores their previous values when the session ends. Apps opened by the profile are quit if they were not already running, and apps quit by the profile are reopened if they were running.

Explicit rollback scenes run before the captured state is restored. This makes them suitable for layout hooks or operations whose state cannot be read through Edith configuration.

## Starting and stopping

Profiles can start from the menu panel, settings, a global shortcut, the Command Bar action catalog, the CLI, or an Automations scene.

```bash
ed focus ls
ed focus start "Deep work" --for 50m
ed focus start "Deep work" --until 17:30
ed focus status --json
ed focus stop
ed focus history
```

`--for` accepts minutes or hours. `--until` accepts a future ISO 8601 date or a local 24-hour time. A profile with no duration runs until it is stopped.

To schedule a profile, add `focus.start` to a scene and use an Automations schedule trigger for that scene. This keeps scheduling in one engine.

## Meeting Mode

Meeting Mode is off by default. When enabled, it reads Edith Calendar locally and schedules a single timer for the next eligible event boundary. It does not poll, upload event data, or keep meeting titles in focus history.

Meeting settings can:

- select the profile to activate;
- require a busy event or a join link;
- ignore short events;
- exclude calendars and title terms;
- add separate meeting start and end scenes.

The selected profile starts when an eligible event begins and ends at the event boundary. While it is active, a compact menu bar item shows the meeting state and offers an immediate End Focus action.

macOS does not expose a supported API for changing the user's system Focus mode. A profile can store the Focus name to show a local notification reminder instead.

## Recovery and privacy

The active session and bounded 30-day history are local files. The profile document is included in Edith settings backup, while active sessions and history are device-local. Meeting titles, locations, notes, and attendees are not written to focus history.

Stopping a session, disabling the extension, quitting Edith, or recovering an expired session runs meeting end scenes, rollback scenes, and the generated restoration scene. Restoration continues after individual failures, and any failure is recorded locally.

## Teardown

Disabling Focus Profiles removes Calendar observers, timers, global shortcuts, IPC observers, and the status item. It first attempts to restore an active session. If Automations is otherwise disabled, its internal runtime is released after restoration finishes.
