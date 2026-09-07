# Open a Files window

`ed machines files open <machine> [path] [--json]` opens a directory in Edith's Files window.

The window belongs to the main application. The command starts Edith when needed and waits for the window to acknowledge the request. The background agent continues owning collection and shared state.

With no path, the command uses the directory remembered for this terminal and machine. If no directory was remembered, the window opens at the machine's home directory.

```sh
ed machines files open local ~/projects
ed machines files open workstation --json
```

A JSON success includes `machine`, `opened`, and `path`. Unknown machines fail before the application is launched. An unavailable application or an unanswered window request returns an error.

[Back to CLI index](../README.md)
