# Remote machines

Machines turns computers reachable over SSH into one fleet inside Edith. The local
Mac is always present. Add Linux, macOS or other SSH hosts to monitor them, browse
their files, run terminals and containers, and collect agent usage without juggling
separate connections.

## Add a host

Open Machines, choose **Add machine**, and enter a name plus either an SSH host or
an alias from `~/.ssh/config`. Edith supports SSH-agent authentication, private keys
with optional passphrases, and saved login passwords. Secrets are stored in the
macOS Keychain, not in the machine registry or exported settings.

An optional sudo password enables operations that require elevation, including
power actions and thermal profile changes. Commands try passwordless sudo when no
password is stored. Edith reports a clear refusal when the remote account lacks the
needed privilege.

## Fleet and machine views

The fleet view summarizes reachability and live resource use. Select a host for:

- CPU and memory history, storage, temperatures, GPU data, fans and uptime;
- a sortable process list;
- persistent terminal tabs;
- file browsing, search, preview, upload, download, copy, move and deletion;
- Docker Compose groups, containers, resource use, configuration and log streams;
- saved commands and port forwards;
- wake-on-LAN, restart and shutdown controls.

Command-click a machine chip to open it in a separate window. Workspace mode saves
split-pane layouts that can mix terminals and machine content from different hosts.
Removing a machine only forgets Edith's connection details, forwards, snippets and
saved secrets. It does not change files or services on that host.

## Agent usage collection

The usage collector can run over the same SSH connection and fold each host's agent
history into the dashboard as machine-specific sources. Repository, worktree and
chat attribution is preserved when data is reconciled. Replaced snapshots are
deduplicated, so reconnecting or refreshing a host does not count the same activity
twice.

## Docker ownership

Docker projects are grouped by their Compose project name. The exact
`edith-companion` project is labeled Companion, sorted first and marked as managed
by Edith. Similar names are left alone. Container actions still run on the selected
host, and removing the host from Edith does not stop or delete its containers.

## Fans and thermal profiles

Fan RPM is read-only. Thermal profile control appears only when a Linux host exposes
both `/sys/firmware/acpi/platform_profile` and its choices file. Edith offers the
profiles the kernel reports, rather than assuming names such as balanced or
performance.

A profile can remain active until changed or automatically revert after 15 minutes,
30 minutes, 1 hour or 2 hours. Timed changes use `systemd-run` on the host. They need
systemd and sudo access to the platform profile file. Applying another profile
cancels the previous timer and starts a new one; an untimed choice cancels rollback.

Thermal profiles affect heat, fan noise, performance and battery life. Use a timed
change for experiments or short builds, and verify that the host reports the
expected current profile afterward.

## Power controls

Restart and shutdown ask for confirmation and end the SSH connection immediately.
Edith treats the expected disconnect as a successful power action and reconnects
when the host returns. Wake-on-LAN needs a known MAC address and a network path that
allows the magic packet; it cannot wake every machine across every routed network.

Every machine feature also has scriptable commands with JSON output. Start with the
[Machines command reference](cli/machines/README.md).
