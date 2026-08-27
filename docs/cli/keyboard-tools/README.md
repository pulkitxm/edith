# Keyboard Tools

Keyboard Tools filters keyboard input in Edith's menu bar helper. It can suppress accidental duplicate physical presses and turn Caps Lock into a Super key with separate tap and hold behavior.

## Setup

Enable the extension and grant Accessibility:

```bash
ed extensions enable keyboardTools
ed permissions request accessibility
```

macOS may require Edith to restart after the permission changes. Input Monitoring is optional and appears in the extension's access list for keyboard configurations that require it.

## Debounce

Debounce keeps normal key repeat working. It only drops a second physical press of the same key when that press follows the accepted release inside the configured window.

```bash
ed config set keyboardDebounceEnabled true
ed config set keyboardDebounceWindowMs 50
```

The window accepts 10 through 500 milliseconds. Start near 50 milliseconds and increase it only enough to cover the faulty switch.

## Super key

Super key maps Caps Lock to an unused function key while Edith is running. Edith removes only its own mapping when the extension is disabled or the helper quits.

A quick tap runs the selected tap action. Holding Caps Lock while pressing another key adds the selected modifier chord. A long hold by itself does nothing.

```bash
ed config set keyboardSuperEnabled true
ed config set keyboardSuperTapAction escape
ed config set keyboardSuperHoldAction hyper
```

Tap actions are `none`, `escape`, and `openEdith`. Hold actions are `hyper`, `commandOption`, `controlOption`, and `controlCommand`.

## Disable and recover

Disabling the extension tears down the event tap and restores Caps Lock immediately:

```bash
ed extensions disable keyboardTools
```

Inspect permissions, helper state, and configuration with:

```bash
ed extensions doctor keyboardTools --json
```
