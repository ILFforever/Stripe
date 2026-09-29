# Items: kinds, states and attributes

The rulebook for what each kind of item on the bar can be, which states it has,
and which preset keys (attributes) apply to it. Settings shows the same things:
the inspector only offers what applies to the selected item. The source of
truth is the code: `MTMR/ItemsParsing.swift` (keys), `MTMR/ItemStyle.swift`
(styling, on state, haptics), and the item classes in `MTMR/Widgets/`.

## The preset file

A bar is saved as a Stripe document: its own settings under `"bar"`, and its items under `"items"`.

```json
{ "stripe": 1,
  "bar": { "background": { "gradient": ["#5A1A73", "#0D3366"] }, "glassKeys": true },
  "items": [ … ] }
```

`"background"` is one of `{ "color": … }`, `{ "gradient": [left, right] }`, `{ "pattern": "stripes" | "grid" | "dots" | "carbon", "colors": [background, lines] }` or `{ "video": "name.mov", "pauseOnBattery": true }` (a file in Stripe's Backgrounds folder). `"glassKeys"` (Theme › Keys in Settings) draws every key as translucent glass so the background shows through; a key's own `"glass": true` or `false` (its Style tab's Background: Glass or Standard) overrides it. A plain list of items (MTMR's format) is still read, and is saved as a document from then on.

## Kinds

Every item is one of these. The kind decides which of the attribute groups
below apply.

| Kind | Types | What it is |
|---|---|---|
| **Button** | `staticButton`, `shellScriptTitledButton`, `appleScriptTitledButton`; keys (`escape`, `delete`, `brightnessUp`/`Down`, `illuminationUp`/`Down`, `previous`, `next`, `volumeUp`/`Down`, `sleep`, `displaySleep`, `close`, `exitTouchbar`); readouts (`timeButton`, `cpu`, `gpu`, `performance` (CPU + GPU stacked), `network`, `battery`, `weather`, `yandexWeather`, `currency`, `inputsource`, `music`) | A key you tap. Everything drawn as a single key is a button underneath, including the widgets. |
| **Toggle** | `dnd`, `nightShift`, `darkMode`, `mute`, `pomodoro`, `play` | A button that knows its own on/off state. |
| **Popover** | `popover` | A button that expands into its `items` across the bar (e.g. a volume slider). Press and hold can slide its first slider without opening it. |
| **Slider** | `volume`, `brightness` | A draggable level, with icons at the ends. |
| **Folder** | `group` | A key that opens its `items` as a sub-bar; a `close` item inside returns. |
| **Group** | `cluster` | Several items side by side on one shared background, always on the bar. |
| **Strip** | `dock`, `upnext` | A scrolling row (apps, calendar events). Not a button. |
| **Gesture** | `swipe` | Not drawn; runs a command on a multi-finger swipe. |

## States

| State | Which kinds | When | Shown by |
|---|---|---|---|
| **Normal** | all | always | the item's own attributes |
| **Waiting** | shell script, AppleScript, and readouts that load (`cpu`, `currency`, `weather`, `inputsource`, `music`…) | before the first value arrives | hidden, then fades in (at most 2s) |
| **Pressed** | buttons, toggles, popovers | while a finger is on it | `pressedBackground`; haptic press buzz |
| **On** | toggles (built in); any button with an `activeWhen` rule | toggles: when their thing is on (see below); rule: while every part of the rule holds | the on-state attributes |
| **Hidden** | all | while the item's `when` rule doesn't hold | not on the bar (in a group: hidden in place; a group with nothing to show hides too) |
| **Empty** | group | no items yet | not on the bar; a drop target in Settings |

What "on" means for each toggle:

| Toggle | On while |
|---|---|
| `dnd` | Do Not Disturb is on |
| `nightShift` | Night Shift is on |
| `darkMode` | Dark Mode is on |
| `mute` | the sound is muted |
| `pomodoro` | a timer is running |
| `play` | something is playing |

An `activeWhen` rule on a toggle replaces its built-in state.

`when` and `activeWhen` take the same keys, and each means "all of these hold":
`app` (names or bundle IDs, `|`-separated), `notApp`, `time` (`"09:00-18:00"`,
may wrap past midnight), `script` (holds while the command exits 0), `every`
(seconds between script checks, default 10). `when` decides whether the item
shows; `activeWhen` whether it's on.

## Attributes

✓ applies · — doesn't apply (ignored if set)

| Attribute group | Button | Toggle | Popover | Slider | Folder | Group | Strip | Gesture |
|---|---|---|---|---|---|---|---|---|
| Position and size | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| Visibility (`when`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Label (`title`, icon) | ✓ | ✓ | ✓ | knob only | ✓ | — | — | — |
| Key look | ✓ | ✓ | ✓ | — | — | ✓ (background and shape) | — | — |
| Text styling | ✓ | ✓ | ✓ | — | — | — | — | — |
| Pressed color | ✓ | ✓ | ✓ | — | — | — | — | — |
| On state | with `activeWhen` | ✓ | with `activeWhen` | — | — | — | — | — |
| Haptics (press/release) | ✓ | ✓ | ✓ | — | — | per item inside | — | — |
| Haptics (on/off feel) | with `activeWhen` | ✓ | with `activeWhen` | — | — | per item inside | — | — |
| Haptics (detents) | — | — | — | ✓ | — | — | — | — |
| Actions | ✓ (see below) | ✓ (see below) | — | — | — | — | — | — |
| Contents (`items`) | — | — | ✓ | — | ✓ | ✓ | — | — |

Items inside a group, folder or popover follow the same rules as on the bar,
except position (`align`), which only top-level items have.

### Position and size
- `align`: `left`, `center` (default) or `right`.
- `width`: points. Now Playing in the MTMR look is never narrower than 180.

### Label
- `title`: text. For script items, the script's output is the title.
- `symbol`: an SF Symbol name. `image`: `{ "filePath" | "base64": … }`. A symbol wins over an image.

### Key look
- `background`: a color (`"#RRGGBB"` or a system color name such as `green`). Unset: the standard gray key.
- `bordered: false`: no key at all (text or icon straight on the bar).
- `style: "pill"`, or `cornerRadius`: the key's shape (with a `background`).
- Groups also have `dividers`, `itemWidth` (a minimum per item), `spacing` and `padding`.

### Text styling
- `fontSize`, `fontWeight` (`ultralight` … `black`), `textColor`, `monospacedDigits`, and `iconColor` (the symbol's color).
- `textColor` only recolors the default white text. Colors a widget or script sets on purpose (e.g. ANSI colors) stay.

### Pressed color
- `pressedBackground`: the background while a finger is on the key.

### On state
Each applies only while the item is on. Anything left unset looks as it does when off.
- `activeWhen`: a rule that decides when it's on (see States). Built into toggles.
- `activeBackground`: the background.
- `activeSymbol`: a different SF Symbol, which replaces the item's own icon, including live ones like Mute's.
- `activeIconColor`: the icon's color. It also tints icons the item draws itself, e.g. Mute's speaker.
- `activeTextColor`: the text color.
- `activeTitle`: different text, e.g. `"Muted"`. It shows even when the key has no title while off.

### Haptics
All of these are subject to the Haptic Feedback switch in Stripe's menu-bar menu.
- `haptic`: when to buzz. `both` (default), `press`, `release` or `off`.
  - Default feel: a medium buzz on press and a soft tick on release.
  - A press held long enough to act (press-and-hold actions) always gives a strong buzz unless `off`.
- `hapticStrength`: `light`, `medium` (default) or `strong`, for the press. The release is always a soft tick.
- `hapticPattern`: `single`, `double` or `triple`.
- **On/off feel** (toggles, and items with `activeWhen`): the release buzz tells you what the tap did.
  - `hapticToggle: false` turns it off.
  - `hapticOnStrength` / `hapticOnPattern`: the buzz for turning on. Default: strong, single.
  - `hapticOffStrength` / `hapticOffPattern`: the buzz for turning off. Default: light, single.
  - It only plays when `haptic` includes release, and only if the state actually changes. It waits 1.5s for a toggle, or 4s for an `activeWhen` rule, since scripts can be slow.
- **Detents** (sliders): a tick at each mark while you drag, and a firm one at either end.
  - `hapticStep`: the spacing in percent, default 10.
  - `hapticStrength`: the tick's strength. Default: light.
  - `haptic: "off"`: no detents.
  - Only your own dragging and press-and-hold sliding tick; volume-key changes don't.
- **Hold to repeat** (brightness and volume up/down keys, and buttons whose tap sends those `hidKey`s): holding the key keeps stepping the level after 0.4s.
  - `holdStep`: each step in percent, default 5.
  - `holdRepeat: false`: a hold does nothing extra; only the tap steps.
  - Each step buzzes on a ramp: holding up goes light, medium, then strong; holding down goes strong, medium, then light; a new band every 4 steps. `haptic: "off"` silences it.
  - The system's brightness or volume overlay stays up while you hold. A key with a `longTap` action doesn't repeat.

### Actions
- `actions`: a list of `{ "trigger", "action", … }`.
  - Triggers: `singleTap`, `doubleTap`, `tripleTap`, `longTap`.
  - Actions: `shellScript`, `appleScript`, `openUrl`, `keyPress` (virtual key code), `hidKey` (media and system keys).
- **Keys with a fixed action ignore `actions`:** `escape`, `delete`, the brightness, keyboard-light, volume and media keys, `sleep`, `displaySleep`, `close`, `exitTouchbar`, and also `mute` and `play`.
- **Everything else adds your actions to its own:** plain buttons and scripts have none, so yours are all they do. On a widget or toggle (`dnd`, `nightShift`, `darkMode`, `battery`, `inputsource`…), a single tap runs its built-in action and yours.
- A double or triple tap makes single taps wait about 0.3s (0.4s with triple) to tell them apart.

### Type-specific
Each type's own keys (e.g. `refreshInterval`, `formatTemplate`, `showPercentage`, `pressAndHold`, `dividers`) are listed in its catalog entry in `MTMR/Editor/EditorModel.swift`, and shown first in its inspector.

**Designs.** Some types have built-in designs, picked on the Style tab: `"theme": "mtmr"` gives MTMR's classic look where it differs, and these take `"design"`:
- `performance`: `"chip"` (default), `"minimal"` or `"graph"`.
- `pomodoro`: `"icon"` (default), `"ready"`, `"stacked"` or `"pill"`.
- `music`: `"lines"` (default), `"progress"`, `"equalizer"`, `"player"` (previous, play/pause and next on the same key) or `"ring"`. Each shows "Not playing" when nothing is.

**Now Playing's controls.** `"tapOpens"` sets what a tap on `music` does: nothing extra (plays or pauses, the default), `"side"` (previous, play/pause and next slide out beside the key, and slide back after a few seconds or on another tap) or `"full"` (the controls open across the bar with the track's progress, and a back arrow at the item's end). A double tap and a press and hold are previous and next unless `"doubleTapDoes"` and `"holdDoes"` say otherwise: each is `"previous"`, `"next"`, `"playPause"`, `"side"`, `"full"` or `"nothing"` (a gesture set to nothing has no action, so a single tap doesn't wait for a possible double).

**Pages.** Tapping `cpu`, `gpu` or `performance` opens its page (holding opens Activity Monitor) across the bar (the CPU page, the GPU page, or the unified one), like the battery's overview. `"panelTiles"` picks the tiles (`cpu`, `cores`, `graph`, `load`, `gpu`, `gpuDetail`, `gpuMemory`, `memory`, `apps`) and `"panelCloseSide"` which end the back button is at.

## Precedence
1. **The preset beats defaults.** Anything set on an item wins over the built-in look (and, once themes land, over the theme).
2. **On state beats normal**, only while on, and only for the attributes that are set.
3. **Pressed beats on**, while the finger is down: `pressedBackground` over `activeBackground`.
4. **`activeWhen` beats built-in state** on toggles.
5. **Global beats per-item** for haptics: the menu-bar switch turns everything off.

## Known gaps
- **Fixed-action keys** (e.g. `mute`, `play`) show an Actions section in Settings, but a preset action on them is ignored.
- **Dock and Up Next** are strips, not buttons, but the inspector still offers button styling for them. It does nothing there.
- **Folders** take a label and icon, but no key look, pressed color or haptics of their own. The items inside have their own.
