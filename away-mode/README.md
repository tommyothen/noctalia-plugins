# Away Mode

One toggle for stepping away from the machine. Click it and the speakers mute, the screens
go dark, the session locks, and nothing can suspend the laptop: not the lid switch, not the
idle timer, not `systemctl suspend`. Whatever you left running keeps running. Come back,
unlock, and the mode turns itself off and unmutes the speakers, unless they were already
muted when you left.

*Suspend* and *lock* are separate things. Caffeine inhibits `idle`, which stops the suspend
but also cancels the lock and the screen blanking, so an unattended machine sits there awake
and unlocked. Away Mode inhibits `sleep` and `handle-lid-switch` instead and leaves `idle`
alone, so Noctalia's own lock and screen-off timers still fire on schedule. Someone who
bumps the desk wakes the screens to a lock screen, and the idle timer darkens them again a
minute later.

Derived from [`8bury/lid-guard`](https://github.com/noctalia-dev/community-plugins/tree/main/lid-guard)
1.0.0, which is MIT licensed. The transient-unit mechanic is theirs.

## Plugin

| Field | Value |
| --- | --- |
| ID | `tommyothen/away-mode` |
| Entries | Service: `svc`; bar widget: `toggle`; shortcut: `away-toggle` |

## Requirements

`systemd-run`, `systemctl`, `systemd-inhibit` and `sleep` on `PATH`, and a logind session.
Without them the widget shows an error glyph and the toggle does nothing.

The lock and screen-off steps shell out to `noctalia msg`. If the CLI is not on `PATH` the
mode still works, it just does not lock or blank for you. The mute step uses `wpctl`
(WirePlumber) and is skipped when that is missing.

`date` is used once, to recover the start time of a unit the plugin adopted rather than
started. Missing it costs the "Since" row in the tooltip and nothing else.

## Usage

Add the **Away Mode** bar widget, or use the quick tile in the control center. The glyph is
`primary` coloured while the mode is on and muted while it is off; the tooltip lists what is
blocked and what is not.

Right-clicking the bar widget forces a re-read of the unit state, for when it was stopped
from a terminal and the bar has not caught up yet.

From a script or a keybind:

```sh
noctalia msg plugin tommyothen/away-mode:svc all toggle
noctalia msg plugin tommyothen/away-mode:svc all on
noctalia msg plugin tommyothen/away-mode:svc all off
noctalia msg plugin tommyothen/away-mode:svc all refresh
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `lock_on_enable` | `bool` | `true` | Locks the session as soon as the mode is turned on. |
| `screen_off_on_enable` | `bool` | `true` | Turns the screens off as soon as the mode is turned on. They wake normally on input or lid-open and go dark again on the usual idle timer. |
| `mute_on_enable` | `bool` | `true` | Mutes the speakers as soon as the mode is turned on. Turning it off unmutes them again, unless they were already muted when the mode went on. |
| `auto_off_on_unlock` | `bool` | `true` | Turns the mode off by itself once the session is unlocked. |

## Notes

### The state is a systemd unit, not a variable

Turning the mode on starts a transient user unit called `away-mode-inhibit.service`, whose
only job is to hold the inhibitor:

```
systemd-inhibit --what=sleep:handle-lid-switch --mode=block sleep infinity
```

That makes the state crash-safe and inspectable. A shell restart, a plugin reload or a
segfault leaves the unit running, and the service adopts it on the way back up rather than
resetting it. You can always check from a terminal:

```sh
systemctl --user is-active away-mode-inhibit.service
systemd-inhibit --list
```

Being disabled or uninstalled is the one teardown that stops the unit, because leaving an
invisible suspend block behind with no toggle to clear it would be a trap.

### Why a block inhibitor is enough

A `--mode=block` inhibitor on `sleep` is only bypassable by a caller that asks logind to
ignore inhibitors, and that path is gated by the `org.freedesktop.login1.suspend-ignore-inhibit`
polkit action, which is `auth_admin` by default. Noctalia's own suspend implementation falls
back from `loginctl` to `systemctl` to writing `/sys/power/state`; the first two hit the
inhibitor and the last needs root. So every route out is closed for an unprivileged session.

### Coming back

The plugin API exposes no lock-state accessor and no lock or unlock callback, so the service
polls `noctalia msg status`, which reports a `locked` flag, every three seconds, and only
while the mode is on. Nothing is polled the rest of the time.

The trigger is the transition from locked to unlocked, not the level, so turning the mode on
while the session happens to be unlocked does not immediately turn it back off.

### Filesystem and network

The plugin makes no network requests. Everything it knows lives in the transient unit and in
`noctalia.state`, with one exception: when the mute step actually mutes (rather than finding
the sink already muted), it drops a marker file at
`$XDG_RUNTIME_DIR/away-mode/restore-unmute` so the off path knows the mute was its own to
undo. It is on disk rather than in a variable for the same reason the inhibitor is a unit: a
shell restart in the middle of an away period must not orphan the mute.
