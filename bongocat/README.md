# Bongo Cat

A cat that sits in your bar, blinks, dozes off, and slaps its paws when you type or when the
music has a beat.

Fork of [`noctalia/bongocat`](https://github.com/noctalia-dev/official-plugins/tree/main/bongocat)
1.1.4, which is MIT licensed. The cat, the font and all of the animation logic are theirs.
This fork changes how the keyboard is found, and adds the typing speed readout.

## Why the fork

Upstream reads keystrokes by running `evtest` against whatever you put in `input_devices`,
and its docs steer you towards `/dev/input/by-id/` or `/dev/input/by-path/` because `eventN`
numbers move around between boots. That advice quietly breaks on a machine running a key
remapper.

`keyd`, and `kmonad`, `evremap` and `xremap` the same way, takes an exclusive grab
(`EVIOCGRAB`) on the physical keyboard and replays every keystroke on a virtual keyboard it
creates through `uinput`. Two things follow. The physical device goes silent, so pointing
`evtest` at the obvious `by-path` entry yields a device description and then nothing forever.
And the device that does carry the keystrokes is a uinput device, which gets no `by-id` and
no `by-path` symlink at all, so the only path that works is exactly the unstable
`/dev/input/eventN` upstream tells you not to use.

Here is what that looked like on this laptop, twenty seconds of typing on each device:

```
event2  (AT Translated Set 2 keyboard, /dev/input/by-path/platform-i8042-serio-0-event-kbd)   0 events
event10 (keyd virtual keyboard, no by-id or by-path entry)                                   61 events
```

So the fork finds the keyboards itself instead of asking. It reads
`/proc/bus/input/devices` and keeps every device whose `EV` bitmask has both `EV_KEY` and
`EV_REP` set. That pair is what distinguishes a keyboard from the other things that report
key events: the power button, the lid switch, the touchpad and the audio jack all have
`EV_KEY` but none of them has autorepeat. On this machine the filter selects `event2` and
`event10` and nothing else.

Reading a grabbed keyboard alongside the virtual one costs nothing, because a grabbed device
emits no events. That is what makes "read all of them" a safe answer rather than a guess
about which one is live.

## Typing speed

While you type, the cat shows your speed in words per minute, next to it on a horizontal bar
and under it on a vertical one. It disappears five seconds after you stop.

The number is the last five seconds of keystrokes, at the conventional five characters to a
word, so 60 wpm means 300 characters in the last minute's worth of pace. Only keys that
produce a character count: letters, digits, punctuation, space and the numeric keypad.
Modifiers, arrows and F-keys are not words, and counting them would show a burst of speed
every time you reached for Ctrl. Autorepeat does not count either, so leaning on a key does
not run the number up.

Before the window has five seconds in it the divisor is how long you have been typing rather
than a flat five seconds, so an opening burst reads at its own speed instead of a fifth of
it. Below five keystrokes nothing is drawn at all, which keeps a single keypress from
flashing a number into the bar.

Turn it off with `show_wpm` if you would rather have just the cat.

## Plugin

| Field | Value |
| --- | --- |
| ID | `tommyothen/bongocat` |
| Entry | Bar widget: `cat` |

## Requirements

`evtest`, and read access to `/dev/input/event*`, which on most systems means being in the
`input` group and logging in again. Without either the widget still runs; the cat just sleeps.

Audio reactivity uses Noctalia's PipeWire spectrum callback and needs neither.

## Usage

Add the **Bongo Cat** widget to a bar. It works with no configuration. Click the cat to pause
or resume it.

Fill in `input_devices` only when you want to override the detection, for instance to react to
one specific keyboard out of several. Entries are literal paths or globs under `/dev/input/`,
and they replace automatic detection rather than adding to it.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `auto_detect` | `bool` | `true` | Finds keyboards from `/proc/bus/input/devices` and rescans every 5 seconds. |
| `input_devices` | `string_list` | `[]` | Paths or globs under `/dev/input/`. Used instead of detection when non-empty. |
| `executable_path` | `file` | `evtest` | Path to the input reader executable. |
| `show_wpm` | `bool` | `true` | Shows your typing speed beside the cat while you type. |
| `audio_spectrum` | `bool` | `false` | Enables PipeWire audio spectrum events. |
| `tappy_mode` | `bool` | `false` | Makes the cat tap its paws to detected beats. |
| `rave_mode` | `bool` | `false` | Flashes cat colors on detected beats. |
| `use_mpris_filter` | `bool` | `false` | Reacts only while an MPRIS player is playing. |

## IPC

```sh
noctalia msg plugin tommyothen/bongocat:cat focused pause
noctalia msg plugin tommyothen/bongocat:cat focused resume
noctalia msg plugin tommyothen/bongocat:cat focused toggle
```

## Notes

### One shell, not one per device

`noctalia.runStream` returns a boolean rather than a handle, so a script cannot stop a stream
it started and restart it with a different command. Rescanning therefore has to happen inside
the stream. The single shell the plugin starts resolves the device list, runs an `evtest` per
device, and every 5 seconds resolves it again; when the list differs it kills its children and
respawns. A keyboard plugged in after the bar started is picked up within 5 seconds, and so is
a remapper that was restarted and came back on a different `eventN`.

The shell traps `INT`, `TERM` and `EXIT` to kill its `evtest` children, and its loop condition
is `kill -0` on the Noctalia process, so nothing is left behind when the widget reloads or the
shell goes away. Hot reloading the script replaces both `evtest` processes rather than
stacking a second pair on top.

Device detection is POSIX shell rather than Luau for the same reason: the parsing has to live
where the rescan happens.

### Duplicate keystrokes

If two devices genuinely emit the same keypress, which needs a virtual keyboard that is not a
grabbing remapper, the cat sees each press twice and lands on both paws instead of alternating.
It is a cosmetic difference and no setup here produces it, but `input_devices` is the way out
if yours does.

### Translations

The upstream German, Brazilian Portuguese, Turkish and Simplified Chinese files are kept as
they were. The `auto_detect` label and the rewritten `input_devices` description are English
in all five, since inventing translations for them would be worse than leaving them obvious.

## Credits

- [@StrayRogue](https://x.com/StrayRogue), for the original Bongo Cat artwork.
- The Noctalia team, for the widget this is a fork of.
