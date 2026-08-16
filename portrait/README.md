# Portrait

One toggle to turn a monitor sideways for vertical content. Click the bar glyph and the
focused output rotates to portrait; click again and it comes back. The same toggle is a
control-center tile and an IPC verb, so a keybind works too:

```sh
noctalia msg plugin tommyothen/portrait:svc all toggle
```

niri can already do this with `niri msg output <name> transform 90`, but that needs the
connector name and the right transform value at the moment a vertical video is waiting.
This remembers both.

## Plugin

| Field | Value |
| --- | --- |
| ID | `tommyothen/portrait` |
| Entries | Service: `svc`; bar widget: `toggle`; shortcut: `portrait-toggle` |

## Requirements

The `niri` CLI on `PATH`, talking to a running niri session. Without it the widget shows an
error glyph and the toggle does nothing. Compositors other than niri are not supported.

## Usage

Add the **Portrait** bar widget, or use the quick tile in the control center. The glyph is
`primary` coloured while the monitor is rotated and muted while it is upright; the tooltip
names the output and the angle.

Right-clicking the bar widget forces a re-read, for when the output was rotated from a
terminal and the poll has not caught up yet.

From a script or a keybind:

```sh
noctalia msg plugin tommyothen/portrait:svc all toggle
noctalia msg plugin tommyothen/portrait:svc all normal   # back upright
noctalia msg plugin tommyothen/portrait:svc all 90       # explicit angle: 90, 180 or 270
noctalia msg plugin tommyothen/portrait:svc all refresh
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `rotation` | `string` | `270` | Degrees counter-clockwise for the rotated state: `90`, `180` or `270`. Anything else falls back to `270`. |
| `output` | `string` | empty | Connector to rotate (`niri msg outputs`). Empty rotates whichever output is focused when you click. |

## Notes

### niri owns the state

The service keeps no rotation flag of its own. It polls `niri msg -j outputs` every five
seconds and after every change, and the published state is whatever niri reports, so a
rotation made from a terminal shows up in the bar within one poll. Transforms this plugin
never sets (the flipped variants) simply count as "not upright" and toggle back to normal.

### Which output gets rotated

A pinned `output` setting always wins. Otherwise the focused output is rotated, and a
rotated output stays the target until it is back to normal, so the reset lands on the same
monitor even if focus moved to another screen in between.

### Direction

niri specifies transforms counter-clockwise: the default `270` reads upright once you turn
the physical monitor counter-clockwise (top edge to the left). If you turn your monitor the
other way, set `rotation` to `90`.

### Teardown

Runtime transforms do not survive a niri restart, and a plain plugin reload leaves the
monitor as it is. Being disabled or uninstalled puts the output back to normal, because a
sideways monitor with no toggle left to fix it would be a trap.

### Filesystem and network

The plugin writes no files and makes no network requests. Everything it knows lives in
`noctalia.state` and in niri.
