# Developing Stripe

Stripe is a fork of [MTMR](https://github.com/Toxblh/MTMR) that builds with only the
Xcode Command Line Tools. This covers building, testing without touching the Touch
Bar, and the conventions the code follows.

## Build and install

```sh
build-support/make-signing-identity.sh   # once per Mac (see "Signing" below)
make            # build build/Stripe.app for this Mac
make run        # build, then relaunch from build/
make install    # build, copy to /Applications, relaunch (use this day to day)
make universal  # arm64 + x86_64
```

Builds are incremental and parallel: swiftc recompiles only the files that
changed (and what depends on them), across all cores (`JOBS=` to override).
A clean build takes about 12s; a rebuild after an edit, about 2s. Per-file
objects live in `build/obj/<arch>/swift/`; `make clean` starts over.

`make universal` needs x86_64 Swift support libraries (e.g.
`libswiftCompatibility56.a`), which some Command Line Tools installs only ship
for Apple silicon; the link then fails with "fat file missing arch 'x86_64'".

`MTMR.xcodeproj` is out of date (it doesn't list files added in the fork and still
references Sparkle). The Makefile is the supported build.

### Signing

macOS ties privacy permissions (Accessibility, needed for media keys and other
simulated keys) to an app's code signature. Ad-hoc signatures change with every
build, so macOS would treat each build as a new app and ask again. The Makefile
signs with the self-signed "Stripe Local Signing" certificate when it exists, which
keeps the permission across rebuilds. Without it, builds fall back to ad-hoc.

### Toolchain notes

- SwiftUI's `@State` is a macro whose plugin ships only with Xcode, so it doesn't
  compile here. Views use `State<Value>` properties directly or an
  `ObservableObject` (see the note in `Editor/EditorFields.swift`).
- Asset-catalog images are copied as loose files (no `actool`); `main.swift`
  restores their template flag. Icons come from `build-support/make-icons.swift`.

## Where things are

| Path | What |
|---|---|
| `~/Library/Application Support/Stripe/items.json` | The main preset |
| `.../Stripe/apps/<bundle-id>.json` | Per-app presets |
| `MTMR/TouchBarController.swift` | Builds and shows the bar |
| `MTMR/ItemsParsing.swift` | Preset JSON → item definitions |
| `MTMR/ItemStyle.swift` | Per-item styling, on-state and haptic keys |
| `ITEMS.md` | Rulebook: each kind of item, its states, and which keys apply |
| `MTMR/Conditions.swift` | `"when"` visibility conditions |
| `MTMR/Widgets/` | Items (battery, popover, mute, network…) |
| `MTMR/Editor/` | The Settings window (SwiftUI) |
| `MTMR/Theme.swift` | Colors/sizes for built-in chrome (start of theming) |

## Testing without touching the bar

Screenshot the Touch Bar at any time:

```sh
screencapture -b -x touchbar.png
```

Launch with debug hooks to drive the bar and editor from the command line:

```sh
STRIPE_DEBUG=1 /Applications/Stripe.app/Contents/MacOS/Stripe
```

Then post a distributed notification named `com.ilfforever.stripe.debug` whose
object is a command:

| Command | Does |
|---|---|
| `popover` | Expand the first popover |
| `group` | Open the first group |
| `dismiss` | Return to the main bar |
| `tap NAME` | Tap the first item whose identifier contains NAME (e.g. `tap battery`) |
| `settings` | Open the Settings window |
| `select N` | Select the Nth top-level item in Settings (`select N.M`: the Mth item inside it) |
| `pane NAME` | Show the Settings sidebar's `library` or `outline` |
| `search TEXT` | Type TEXT into the Settings sidebar's search |
| `press NAME` | Hold down the first button whose identifier or title contains NAME (shows its pressed color) |
| `release` | Let go of every held button |
| `battery` | Open the battery panel (`battery left`: back chevron on the left) |
| `add TYPE` | Add an item to the end of the center, like a library double-click (`add saved:<id>` for My Items) |
| `tab NAME` | Show an inspector tab: `item`, `style`, `behavior` or `advanced` |

A one-line sender:

```sh
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.ilfforever.stripe.debug"), object: "popover", deliverImmediately: true)'
```

## Conventions

- Items that run background work (timers, processes, audio listeners) conform to
  `TearDownable` and stop it in `tearDown()`; the bar calls it when replacing them.
- Only one system-modal bar shows at a time, and `NSPopoverTouchBarItem` can't open
  from one, so sub-bars (groups, popovers) take over the main bar via
  `TouchBarController.showSubBar` / `restoreMainBar`.
- Match Apple's own Touch Bar controls. Adjust horizontal padding only (keys are
  always 30pt tall), and don't add margins at the bar's ends.

## Gotchas

Things that cost time to find out:

- **Never do slow work on the main thread.** Apple Events (ScriptingBridge),
  process walks and per-frame redraws froze the bar for seconds, or cost 20% CPU.
  Measure with `sample <pid> 10` and `ps -o time= -p <pid>` over 30s.
- **What's playing comes from MediaRemote, via the perl helper.** Since macOS
  15.4 it only answers Apple-signed processes (see NowPlaying.swift). Don't go
  back to asking apps and browser tabs.
- **Animate with Core Animation, not timers.** The battery's charging sweep is a
  layer animation; redrawing an NSImage 20 times a second was 20% CPU.
- **The Touch Bar ignores `contentTintColor`.** Tint an icon by drawing a copy
  (`NSImage.tinted`). Colored SF Symbols use hierarchical rendering, so filled
  symbols keep their glyph.
- **Haptics go through the trackpad's actuator.** It's found at runtime by
  `ActuationSupported`; the old hard-coded device IDs only covered 2016–2020 Macs.
- **Editor items get new ids whenever the preset reloads** (reopening Settings,
  undo). Anything keyed by id, like the bar's hit-testing frames, has to drop
  ids the document no longer has.
- **On macOS, SwiftUI `Menu` ignores custom label backgrounds.** For a styled
  button that opens a menu, use a `Button` that pops up an `NSMenu`
  (`ClosureMenuItem`).
- **The toolchain has no `@State` macro.** Use `State(initialValue:)` stored
  properties with `wrappedValue` (see EditorFields.swift).
- **Simulated input has limits.** CGEvent clicks reach AppKit and SwiftUI
  buttons, but not SwiftUI double-tap gestures or drags. Test those paths with
  debug hooks (`add`, `select`, `tab`), and let a person try the real gesture.
