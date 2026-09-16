# `ed bifrost calc`

Evaluates an expression and prints the number, exactly as typing it into the bar
would.

Usage:

```
ed bifrost calc <expression> [--json]
```

Arguments and options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<expression>` | text | required | The expression to evaluate. |
| `--json` | flag | off | Emits one JSON document on stdout. |

The plain response is the number alone, ungrouped, so it can be piped straight
into something else:

```
$ ed bifrost calc "12 * 8 + 4"
100
```

The JSON response carries the grouped form as well:

```json
{
  "expression": "1000 * 1000",
  "value": 1000000,
  "display": "1,000,000"
}
```

What the evaluator understands:

- `+`, `-`, `*`, `/` and `^`, with `^` right associative, plus the typed
  variants `×`, `÷` and `−`.
- Parentheses, and a leading `-` or `+`.
- `mod` for a remainder, as in `17 mod 5`.
- Percentages the way people write them: `50 + 10%` is 55, `200 - 25%` is 150,
  `10% of 50` is 5, and `50%` on its own is 0.5.
- `sqrt`, `cbrt`, `abs`, `round`, `floor`, `ceil`, `ln`, `log`, `log2`, `exp`,
  `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, and the two-argument `min`,
  `max`, `pow` and `hypot`. Trigonometry is in radians.
- `pi`, `π`, `tau` and `e`.
- Decimals, `1e3` exponents, `0xff` hex, `0b1011` binary, and `1,234` or
  `1_234` grouping in a number.

Answers are rounded to ten significant digits, an integral result prints without
a decimal point, and the grouped display adds thousands separators that the
plain output never has.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | The expression evaluated. |
| 2 | The command line was invalid, usually the expression missing entirely. |
| 3 | The expression is not one Bifrost can evaluate. |

A bare number is deliberately a not-found, because the bar only offers an answer
when there is something to work out, and so are division by zero, the square
root of a negative number, an unknown function and anything that is not an
expression at all:

```
$ ed bifrost calc 5
error: 5 is not an expression Bifrost can evaluate
hint: try a sum such as `ed bifrost calc "2 + 2"`
```

Both `*` and spaces mean something to your shell, so quote the expression. The
command needs neither Edith nor the extension, touches no state, and never
writes to the pasteboard; copying is what the bar itself does when you press
return on the answer.

## Where to go next

- [`ed bifrost convert`](./convert.md), for units rather than arithmetic
- [`ed bifrost`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
