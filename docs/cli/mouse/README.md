# Mouse Controls

Mouse Controls gives a conventional mouse smoother wheel movement, independent vertical and horizontal direction settings, delayed focus under the pointer, and useful actions on extra buttons. Trackpad scrolling, Magic Mouse gestures, momentum, drags, and Control-scroll remain unchanged.

## Setup

```bash
ed extensions enable mouseControls
ed permissions request accessibility
ed extensions verify mouseControls --json
```

The menu bar companion owns the global event tap. Turning the extension off immediately removes the tap, cancels a pending focus change, and stops any active scroll glide.

## Settings

Open Edith, choose Extensions, then open Mouse Controls. The General tab contains wheel, focus, and trackpad behavior. Buttons maps mouse buttons 4 through 8. Apps can add a running application or accept comma-separated bundle identifiers that should keep their original mouse behavior.

Every setting is also visible through the existing configuration commands:

```bash
ed config ls --group mouse
ed config set mouseSmoothScroll true
ed config set mouseScrollStep 48
ed config set mouseReverseVertical false
ed config set mouseReverseHorizontal true
ed config set mouseFocusFollowsPointer true
ed config set mouseFocusDelay 350
ed config set mouseSideNavigation true
ed config set mouseMiddleClick true
ed config set mouseButton6Action middleClick
ed config set mouseExcludedApps com.example.game,com.example.design
```

Button actions include `automatic`, `passThrough`, `back`, `forward`, `middleClick`, `closeTab`, `reopenTab`, `missionControl`, `appExpose`, and `showDesktop`. Automatic maps buttons 4 and 5 to Back and Forward while side navigation is enabled.

## Scope

Smooth scrolling and direction changes apply only to discrete mouse-wheel events. Edith does not alter continuous touch scrolling. Focus changes only after the pointer settles, and pause while a mouse button or modifier key is held.

Middle click is available as an extra-button action. The optional trackpad setting turns a three-finger physical press into a standard middle-button down, drag, and up sequence. Light taps and swipes stay unchanged. This compatibility feature uses macOS trackpad contact data when available and stands down if that source changes or if macOS three-finger drag is enabled.

## Recovery

If settings look correct but no input changes, refresh Accessibility state and restart the runtime:

```bash
ed permissions refresh
ed extensions disable mouseControls
ed extensions enable mouseControls
ed extensions doctor mouseControls --json
```

Excluded applications always receive their original wheel and button events.
