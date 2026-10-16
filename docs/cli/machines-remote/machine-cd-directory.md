# `ed <machine> cd [<directory>]`

Sets the directory the later commands on that machine run in. It is not sent to
the machine as a command; `ed` intercepts it, asks the machine where that path
resolves to, and records the answer.

```
ed <machine> cd <directory>
ed <machine> cd -
ed <machine> cd
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<directory>` | a path on the machine, absolute or relative to the current one, or `-` | omitted | Where to move to. Omitted means the home directory; `-` means back to the directory you were in before the last `cd`. |

`cd` is only intercepted when it is the whole command and there are at most two
words. `ed tuf cd` and `ed tuf cd Desktop` are interceptions;
`ed tuf cd a b` and the quoted one-shot `ed tuf 'cd /tmp && pwd'` are ordinary
commands that run and change nothing:

```
$ ed tuf 'cd /tmp && pwd'
/tmp
$ ed tuf pwd
/home/pulkit
```

## Examples

```
ed tuf pwd                      /home/pulkit
ed tuf cd Desktop
ed tuf pwd                      /home/pulkit/Desktop
ed tuf ls                       lists Desktop
ed tuf cd -                     back to where you were before
ed tuf cd                       back to the home directory
```

## Behaviour notes

A successful `cd` prints nothing and exits 0. Under the covers `ed` runs
`pwd; cd -- '<target>' && pwd` on the machine, prefixed with a `cd` into the
directory you were already in, and keeps two lines: the first `pwd` becomes the
previous directory and the second becomes the current one. That is why `-`
works, and why it toggles rather than walking a stack.

The pair is stored in a file at
`~/Library/Application Support/Edith/machines/cwd/<machine>/<session>`, where
`<machine>` is the first ten characters of the machine's id with the dashes
removed and `<session>` is the name of the terminal your stdin is attached to,
`/dev/` stripped and anything that is not a letter or a digit turned into a
dash. So `/dev/ttys012` becomes `ttys012`, and two tabs on one machine never
move each other, the same way `cd` behaves in a local shell. When stdin is not a
terminal, which covers a pipe, a script and a cron job, the session is called
`shared` and every such invocation uses the same slot. The directory is created
mode `0700` and the file is written atomically.

A path that does not exist is reported with the machine's own message, exits 1,
and leaves the stored directory alone:

```
$ ed tuf cd nosuchdir
error: cannot change to nosuchdir on Asus TUF 7
hint: bash: line 1: cd: nosuchdir: No such file or directory
```

`cd -` with nothing recorded for this terminal exits 1 with `no previous
directory for <machine> in this terminal`, decided locally once the connection
is open and without asking the machine anything. The round trip a `cd` does
make is under the 60 second command timeout that `ed` puts on ordinary
commands, unlike the command path, which has none.

`--tty` reads the remembered directory but never sets it. The terminal branch
runs before the `cd` interception, so `ed machines exec --tty tuf cd Desktop`
changes directory inside that one pty session and nothing survives it.

The remembered directory reaches exactly two things: `ed machines exec`,
including the shorthand and the `--tty` form, and remote path completion.
Everything else keeps its own defaults, so `ed machines files ls tuf` still
lists the remote home directory after `ed tuf cd Desktop`, and the app's own
terminal and Finder windows are unaffected.

## Where to go next

- [Running commands on a machine](./README.md), the rest of this group
- [All `ed` commands](../README.md)
