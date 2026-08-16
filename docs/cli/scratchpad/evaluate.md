# `ed scratchpad`

Evaluate one arithmetic expression or unit conversion. The command accepts the
whole expression after the command name, so quote it when it contains spaces or
shell metacharacters.

```
ed scratchpad "2 + 2"
ed scratchpad "10 km to mi"
ed scratchpad --json "72 f to c"
```

It prints the formatted result, or a JSON object with `input` and `result` when
`--json` is passed. Invalid or empty expressions exit 2.

[Back to `ed scratchpad`](./README.md)
