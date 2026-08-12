import Foundation

public enum Guide {
    public static let text = """
        # ed, in five minutes, for agents and humans

        `ed` is the command line for Edith, the macOS menu bar app. Everything the app
        can configure, `ed` can configure, and everything the Machines extension can
        reach over SSH, `ed` can reach. `edh` and `edith` are the same binary under
        different names, so use whichever reads better in your shell history.

        There are two surfaces, and picking the right one is the only thing to learn:

        ```
        ed <command> ...          Edith itself.  Config, extensions, usage, limits,
                                  system metrics, music, calendar, permissions.
                                  ed config set, ed usage limits, ed system stats

        ed <machine> <cmd...>     A configured machine, over SSH.  Everything after
                                  the machine name is run there, verbatim, with your
                                  exit code and both streams preserved.
                                  ed tuf docker ps, ed tuf ls -la /srv
        ```

        The second form is why `ed <machine> docker <TAB>` completes docker's own
        subcommands: `ed` asks the remote shell what it would have offered, so any
        tool installed there completes, not just the ones `ed` knows about.

        ## Discover, then act

        ```
        ed machines ls              every machine configured in Edith
        ed machines show <m>        one machine, with live facts
        ed config ls                every setting, with its current value
        ed config describe <key>    one setting: type, scope, allowed values
        ed extensions ls            every extension and whether it is on
        ed permissions ls           every macOS permission Edith uses
        ed usage sources            the agents that produced your usage history
        ed schema                   JSON Schema for the config document
        ed version                  the CLI version, and whether the app is up
        ed guide                    this text
        ed guide claude             a CLAUDE.md snippet making a repo ed-aware
        ```

        `ed install` links `ed`, `edh` and `edith` into a directory on PATH, and
        `ed uninstall` removes those links again. Neither touches anything else.

        Add `--json` to any read command for machine-readable output on stdout with
        stable field names. Diagnostics go to stderr, so stdout stays one parseable
        document. Exit codes are the contract: 0 success, 1 failure, 2 bad usage,
        3 not found, 4 unavailable (the app is not running, or a machine is down).

        ## Configuration

        Every preference the UI writes is a key in the same defaults suite the app
        reads, so a change from `ed` shows up in the running app without a restart.

        ```
        ed config get preventSleep
        ed config set preventSleep true
        ed config set warnPercent 70
        ed config ls --group presenter
        ed config export > edith.json
        ed config import edith.json
        ```

        `ed config set` validates against the catalog: an unknown key, a value of the
        wrong type, or a value outside the allowed set all fail before anything is
        written. `ed schema` prints the same catalog as JSON Schema, which is what
        `ed config import` accepts.

        Extensions are settings too, but they have their own verbs because turning one
        on can need a permission:

        ```
        ed extensions ls
        ed extensions enable machines
        ed extensions disable notchShelf
        ed extensions info clipboard
        ```

        ## Machines

        Machines come from Edith's own machine list, so `ed` never asks you to
        re-enter a host. Transport is `/usr/bin/ssh` with a ControlMaster socket
        shared with the app: if the app already holds a connection, `ed` reuses it
        and every command is a round trip on an open channel.

        ```
        ed machines ls
        ed machines tuf                         one machine, with live facts
        ed machines tuf metrics                 one sample
        ed machines tuf metrics --follow        a sample every two seconds
        ed machines tuf uptime                  run a command there
        ed tuf uptime                           the same thing, shorter
        ed machines tuf files ls /var/log
        ed machines tuf files get /etc/os-release ./os-release
        ed machines tuf files put ./deploy.sh /tmp/deploy.sh
        ed machines tuf services
        ed machines tuf disconnect
        ```

        A machine's disk can also come to you. `mount` hangs its file system off a
        folder on this Mac over the same connection, so Finder and every local tool
        read and write it in place. It needs an sshfs here, FUSE-T for a kext-free
        one or macFUSE if you already run it. A mount that dies with the machine is
        put back the way saved port forwards are: the app checks the machines it is
        connected to, and `mount` run again repairs rather than refusing.

        ```
        ed machines mount tuf                   all of / at ~/Edith/tuf
        ed machines mount tuf /srv --read-only  one directory, look but do not touch
        ed machines mounts                      what is mounted, and whether it answers
        ed machines mount tuf                   again: puts a dead mount back
        ed machines unmount tuf
        ed machines tuf files open /var/log     a Files window, in its own small app
        ```

        The list itself is yours to edit from here, and a change reaches a running
        Edith immediately.

        ```
        ed machines add box --host 10.0.0.4 --user pi
        ed machines edit box --name shed --key ~/.ssh/id_ed25519
        ed machines rm shed --yes               with its forwards, snippets and secrets
        ed machines forwards add box --local 8080 --remote 80
        ed machines snippets add box logs journalctl -xe
        ```

        Power, units and processes. Restart and shut down need --yes, and report
        the machine's own refusal rather than claiming success.

        ```
        ed machines power status box            up? wakeable? rebootable?
        ed machines power reboot box --yes
        ed machines power wake box              works while it is off
        ed machines services restart box nginx.service
        ed machines kill box 4213 --signal KILL
        ```

        The machine name comes first, subject then verb. The older order with the
        machine last still parses, so `ed machines docker ps tuf` keeps working. A
        subcommand name always wins, so a machine literally called `ls` or `docker`
        has to be named explicitly: `ed machines show docker`.

        Docker on a machine has both a parsed form and a raw form. The parsed form is
        for scripts, the raw form is for everything docker can do:

        ```
        ed machines tuf docker ps --json        parsed, stable field names
        ed machines tuf docker images
        ed machines tuf docker logs api --tail 100 --follow
        ed machines tuf docker start|stop|restart|rm api
        ed machines tuf docker prune images --yes
        ed machines tuf docker compose ls
        ed machines tuf docker compose up|down|restart|pull web
        ed tuf docker buildx ls                 raw docker, straight through
        ```

        `ed <machine> <anything>` is the general escape hatch, and it is not limited to
        docker: `ed tuf systemctl status nginx`, `ed tuf tail -f /var/log/syslog`, `ed
        tuf 'ls -la | head'`. Stdin is forwarded, so pipes work in both directions.

        `cd` sticks, so the commands after it run where you left off. The directory
        belongs to the terminal it was set in, like a local shell, and remote path
        completion follows it.

        ```
        ed tuf cd Desktop
        ed tuf pwd                              /home/pulkit/Desktop
        ed tuf cd -                             back to where you were before
        ed tuf cd                               back to the home directory
        ```

        ## Companion memory

        The companion stores Markdown notes as append-only episodes. Run its stack
        from apps/companion, or point the CLI at a forwarded backend.

        ```
        ed companion status                     counts and latest ingest
        ed companion doctor                     postgres, redis and vault checks
        ed companion search "launch plan"        search indexed memory
        ed companion ingest ./notes --json      ingest a Markdown tree
        ed companion chat "how was my week"      streamed chat with citations
        ed companion conversations              list chats, replay one by id
        ed companion episode <id>               read one episode in full
        ed companion reason set --api-key sk-x  configure the reasoner in place
        ed companion nightly                    run the learning pipeline now
        ```

        ## Usage and limits

        Usage numbers come from the same `usage.json` the dashboard reads, and limits
        come from the same `limits-history.jsonl` the rings read. `ed` never recomputes
        them, so the CLI and the UI can never disagree.

        ```
        ed usage limits                 session and weekly, per provider
        ed usage summary --range week   cost and tokens for a window
        ed usage daily --range month
        ed usage models
        ed usage projects              repositories, with folders in JSON
        ed usage sources
        ed usage machines               machines counted with this Mac
        ed usage machines collect tuf   run the collector there, bring it back
        ed usage refresh                re-collect from every agent, live progress
        ed usage refresh --follow       watch a refresh that is already running
        ```

        `--range` is one of today, week, month, all. Week is the current calendar
        week, from Monday through today. `--source` filters to one agent and repeats,
        `--machine` filters to one machine by name and repeats, and `--machine local`
        is this Mac on its own.

        `ed usage projects` groups folders that share a GitHub remote into one
        repository, including folders on different machines. The table shows only the
        repository name, cost and tokens. JSON adds the repository identity, GitHub
        URL and every folder with its path and machine. Repositories with the same
        visible name stay separate by identity. Project detail is normalized per
        source to the canonical totals, and unmatched usage appears as Unattributed.

        A machine keeps its agent history on its own disk, so `ed usage machines
        collect` pipes the collector over SSH and runs it there, installing what is
        missing under ~/.cache/edith on that machine. Its agents come back as sources
        named `<machine>:<agent>`, which every other usage command then counts.

        ## The Mac itself

        ```
        ed system stats                 one sample of this Mac
        ed system stats --follow        keep sampling
        ed system disks
        ed music status                 whatever is playing, on whichever player
        ed music play|pause|stop|toggle|next|previous
        ed music volume 0.4
        ed music players                every player, and which one is active
        ed calendar ls --days 7
        ed permissions ls
        ed permissions request calendar
        ```

        `ed music` targets whatever is actually playing. Spotify and Apple Music are
        driven straight over AppleScript, so they work whether or not Edith is running;
        Edith's own library is driven through the menu bar app. A player that is not
        already open is never launched. Pass `--player builtin|spotify|apple` to force
        one, and `ed music status --json` reports every player it can see plus the
        active one. `ed nowplaying` and `ed np` are the same command.

        Calendar runs through the menu bar app, because the calendar grant lives there.
        If the app is not running those commands exit 4 and say so rather than
        pretending.

        ## The desk

        Everything the UI parks somewhere is readable, and most of it without the app
        running, because it lives in files and preferences rather than in memory.

        ```
        ed tools ls                     yt-dlp and the agent CLIs
        ed machines broadcast -- uptime one command, every machine
        ed apps ls                      what is running here
        ed apps quit Safari | --all --yes
        ed download ls                  the yt-dlp queue
        ed download add <url> --kind audio
        ed download retry --all | clear | tool --update
        ```

        ```
        ed clipboard ls                 the clipboard history, pinned first
        ed clipboard ls --search token  only entries mentioning it
        ed clipboard stats              how many entries, and what they weigh
        ed clipboard get 3              entry three, as text
        ed clipboard copy 3             put it back on the pasteboard
        ed clipboard pin 3 | unpin 3
        ed clipboard rm 3 | clear
        ed color ls --format hex        the colours you picked
        ed shelf ls                     what is parked on the notch shelf
        ed shelf add ./report.pdf
        ed cleaner scan                 developer caches worth reclaiming
        ed cleaner clean --yes          moves them to the Trash, never deletes
        ```

        ## One-shot actions

        `ed config set` flips switches. These are verbs the app performs once:

        ```
        ed app actions                  what can be asked for, and whether it can run
        ed app clean-keys               lock the keyboard so it can be wiped
        ed app test-notification
        ed app open                     open Edith's panel
        ed app check-updates            ask Sparkle to look now
        ed app updates                  the checks already made
        ed app quit                     quit the main window, leave the menu bar
        ```

        ## Completions

        ```
        ed completions install          zsh, bash and fish, auto-detected
        ed completions zsh > _ed        or place it yourself
        ```

        Completion is dynamic. It offers machine names where a machine goes, setting
        keys where a key goes, allowed values where a value goes, and after a machine
        name it asks that machine what it would complete. Remote completion only runs
        when a ControlMaster socket for the machine is already open, so pressing TAB
        never opens a connection or blocks on a sleeping host.

        ## Agent etiquette

        - Prefer `--json` and parse stdout; treat stderr as commentary. On failure
          stdout may be empty; the exit code is the contract.
        - Discover before acting. `ed machines ls --json` and `ed config ls --json`
          are cheap and tell you the exact names the other commands expect.
        - `ed config set` writes to the live app. Read the current value first if you
          intend to restore it.
        - `ed <machine> <cmd>` runs with your SSH identity on a real machine. Treat it
          with the care you would give a shell there.
        - The first `ed` command against a machine may open a ControlMaster socket that
          outlives the process, which is what makes later commands fast.
          `ed machines disconnect <m>` closes it.
        - Commands that need the app say so and exit 4. That is a signal to start
          Edith, not to retry.
        """

    public static let claudeSnippet = """
        ## Edith, from the command line

        This machine runs Edith, a macOS menu bar app with a first-class CLI. Prefer it
        over ad hoc scripts for anything about this Mac, its settings, agent usage, or
        the machines it can reach over SSH.

        - `ed guide` is the full manual. `ed --help` lists commands, `ed <command>
          --help` drills in.
        - Every read command takes `--json`: stdout is exactly one JSON document, logs
          go to stderr, and the exit code is reliable (0 ok, 1 failed, 2 bad usage,
          3 not found, 4 the app or machine is unavailable). Gate on it.
        - `ed config ls --json`, `ed config get <key>`, `ed config set <key> <value>`
          reach every setting the UI exposes, and the running app picks changes up
          live. `ed schema` is the JSON Schema for the whole config document.
        - `ed extensions ls` and `ed extensions enable|disable <id>` toggle features.
        - `ed machines ls --json` lists configured machines. `ed <machine> <command>`
          runs a command there over the app's shared SSH ControlMaster, preserving the
          exit code and both streams: `ed tuf docker ps`, `ed tuf systemctl status`.
        - `ed usage limits --json` and `ed usage summary --json` read the same usage
          pipeline the app's dashboard does, so never re-derive token or cost numbers
          from raw logs.
        - `ed system stats --json` samples this Mac; add `--follow` to stream.

        Do not shell out to `ssh` directly for a configured machine; `ed` reuses the
        app's connection and its known-hosts pinning.
        """
}
