# `ed attention rules export`

Prints a JSON document containing `categories` and the complete `rules` array.
It excludes tracking settings and authentication tokens.

```
ed attention rules export > rules.json
```

Edit this document and import it to update rules. Each rule has a stable `id`,
`name`, `categoryID`, and match arrays: `bundleIDs`, `domains`, `urls`, `keywords`,
`contexts` and `browserProfiles`. Profile labels come from extension settings.
Match arrays allow alternatives within a field; populated fields must all match.
Contexts such as `channel=Example teacher` and `repo=example/project` must all match.

Set `reportSeparately` to `true` to display matching activity under the rule's name
with its own time total. Its entity ID is `rule:<id>`. A single category describes
the activity; `sphere` independently records work, personal or both. Optional
`productivity` and `sphere` override category defaults. Productivity is encoded
as an integer from -2 (very distracting) to 2 (very productive).

Specific URL rules outrank profile-only rules. Among equally specific user rules,
the earlier rule wins. Channels require recorded channel metadata; title keywords
or URL prefixes can classify older history that lacks that metadata. A historical
profile label cannot identify an account unless the extension recorded that label.

## Where to go next

- [`ed attention rules`](./README.md)

- [`ed attention`](../README.md)
