# `ed attention categories auto`

Asks Jev to categorize apps and sites with more than two minutes of unclassified
time in the last seven days, and individual titles on mixed sites such as YouTube,
X and Reddit. Jev answers three questions at once: the category, how productive
it is for you, and whether it is work, personal or both.

Each question carries the evidence Edith has: the app's own App Store category
and vendor, or the site's name and description; the most used window titles and
pages; how long and how often you use it, and whether you mostly type or mostly
scroll there. It also carries the "About you" note from Attention settings and
examples from your own rules, so answers follow your preferences.

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
