# `ed shelf share`

Asks the running notch shelf to open its anchored macOS share picker for one or
more numbered items.

```text
ed shelf share <n...> [--json]
```

JSON reports `action`, `opened`, and an `items` array containing the full
item documents. The helper receives the whole selection in one typed request,
then confirms that the picker opened before the command exits successfully.
Exit 4 means Edith is not running, the Notch Shelf extension is off, the items
are no longer available, or no shelf panel can present the picker.

- [`ed shelf`](./README.md)
- [All command groups](../README.md)
