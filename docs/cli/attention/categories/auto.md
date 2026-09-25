# `ed attention categories auto`

Asks Jev to categorize apps and sites with more than two minutes of unclassified
time in the last seven days, and individual titles on mixed sites such as YouTube,
X and Reddit.

```
ed attention categories auto [--json]
```

It needs a Jev key and Jev categorization turned on in Attention settings. The
background agent also runs this every half hour on its own. Confident answers become
low-priority classifications that your own rules and the built-in catalog always
override. Doubtful answers are remembered and asked again after two weeks.

The JSON document reports whether Jev was `available` and how many `entities` and
`titles` it answered.

## Where to go next

- [`ed attention`](../README.md)
- [`ed attention categories set`](./set.md)
