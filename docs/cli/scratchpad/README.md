# `ed scratchpad`

Evaluates the same arithmetic and unit-conversion engine used by Edith's
Scratchpad panel. It does not need the app or the Scratchpad extension to be
running, so it is useful in scripts as well as at a shell prompt.

```
ed scratchpad "2 + 2"
ed scratchpad "10 km to mi"
ed scratchpad --json "72 f to c"
```

Arithmetic supports addition, subtraction, multiplication, division, unary
signs and parentheses. Unit conversion accepts length, weight, time and Celsius
or Fahrenheit values. Units can be abbreviated or written out, for example
`10 kilometers to miles` and `5 lb in kg`.

## Output

Human output is the result only:

```
$ ed scratchpad "2 * (3 + 4)"
14
$ ed scratchpad "10 km to mi"
6.21371 mi
```

`--json` returns an object with the original `input` and the formatted `result`.

## Exit codes

| Code | When |
| --- | --- |
| 0 | The expression was evaluated. |
| 2 | No expression was supplied, or the expression is not supported. |

## Commands

- [`ed scratchpad`](./evaluate.md)

## Where to go next

- [`ed extensions`](../extensions/README.md) to turn on the Scratchpad hotkey
- [`ed config`](../config/README.md) to set `scratchpadEnabled` and its shortcut
- [All `ed` commands](../README.md)
