# `ed bifrost convert`

Converts between units and prints both sides, exactly as typing the same
sentence into the bar would.

Usage:

```
ed bifrost convert <sentence> [--json]
```

Arguments and options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<sentence>` | text | required | The conversion, in words. |
| `--json` | flag | off | Emits one JSON document on stdout. |

The plain response is the sentence resolved, both sides named in full:

```
$ ed bifrost convert "12 km in miles"
12 kilometers = 7.456454307 miles
```

The JSON response names the units by id so a script never has to parse prose:

```json
{
  "value": 12,
  "from": "kilometer",
  "to": "mile",
  "result": 7.456454307,
  "display": "7.456454307 mi",
  "dimension": "length"
}
```

What the parser accepts:

- `12 km in miles`, `12km to mi`, `convert 3 meters to feet`, `90 kmh as mph`,
  and `12 km -> mi`.
- The question form: `how many miles is 42 km`, `how much is 2 pounds in grams`.
- A unit with no number at all, which is read as one: `km to mi` is
  `1 km to mi`.
- An expression in place of the number, evaluated by the same evaluator
  [`ed bifrost calc`](./calc.md) uses: `2 * 3 km in m` is 6,000 metres.
- Plurals, symbols and both spellings: `metre` and `meter`, `feet` and `ft`,
  `secs` and `s`.

The dimensions it knows are length, mass, temperature, time, data, speed, area,
volume and angle. Temperature carries its offsets properly, so `100 f to c` is
37.77777778 and `0 c in f` is 32. Data has both decimal and binary units, so
`5 gb to mb` is 5,000 while `1 gib in mib` is 1,024. There is no currency: rates
need the network, and this command never touches it.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | The conversion resolved. |
| 2 | The command line was invalid, usually the sentence missing entirely. |
| 3 | The sentence is not a conversion Bifrost understands. |

Crossing dimensions is a not-found rather than an error of its own, and so is a
unit nobody has heard of or a sentence with no target at all:

```
$ ed bifrost convert "12 km in kilograms"
error: 12 km in kilograms is not a conversion Bifrost understands
hint: try `ed bifrost convert "12 km in miles"`
```

Quote the sentence: it is one positional argument and it has spaces in it. The
command needs neither Edith nor the extension, touches no state, and never
writes to the pasteboard.

## Where to go next

- [`ed bifrost calc`](./calc.md), for arithmetic rather than units
- [`ed bifrost`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
