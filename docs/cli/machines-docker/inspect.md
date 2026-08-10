# `ed machines docker inspect`

Prints docker's own `inspect` output for a container, untouched.

```
ed machines docker inspect <machine> <container>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to ask. |
| `<container>` | container name or id | required | What to inspect. Passed to `docker inspect` as given. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

This command has no `--json` flag, because all of its output already is JSON:
docker's array of one object, printed exactly as docker produced it, with
docker's own key names and key order.

```
$ ed machines tuf docker inspect lobe-chat | head -8
[
    {
        "Id": "b556d7fef23e992287fe837df535b4dcfbdf2aaa48f90ee9f96fdc994ed5d79d",
        "Created": "2026-08-06T22:20:40.507261889Z",
        "Path": "/bin/node",
        "Args": [
            "/app/startServer.js"
        ],
```

## Examples

```
ed machines tuf docker inspect lobe-chat
ed machines tuf docker inspect lobe-chat | jq -r '.[0].State.Status'
ed machines tuf docker inspect lobe-chat | jq -r '.[0].Config.Env[]'
```

## Behaviour notes

The remote command is `docker inspect <container> 2>/dev/null`, with a 30 second
ceiling. Because it is plain `docker inspect`, it answers for any docker object,
so an image name, a volume or a network works here too even though the argument
is called `container`.

The two failure paths are worth telling apart. When docker itself fails, which
is what a missing container does, the non-zero status is reported and the
command exits 1; docker's stderr was discarded by the `2>/dev/null`, so the hint
falls back to what landed on stdout, which for a missing object is `[]`:

```
$ ed machines tuf docker inspect nosuch-container
error: docker inspect nosuch-container 2>/dev/null exited 1 on Asus TUF 7
hint: []
```

When docker succeeds but prints nothing at all, `ed` reports
`no container named <container>` and exits 3.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
