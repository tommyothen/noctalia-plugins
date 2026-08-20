# LibrePods

AirPods in the bar: the lowest bud battery next to an earbuds glyph, coloured
primary while anything charges and red once it runs low. The tooltip lists every
connected component and the current noise control mode. Click for the panel:
per-component battery, a noise control selector built from the modes the device
actually allows, a conversation awareness toggle, and the ear detection state.

## Requirements

The [librepods fork with IPC support](https://github.com/tommyothen/librepods)
(branch `rice`), running as a daemon. It holds the exclusive L2CAP connection to
the AirPods and exposes two local surfaces this plugin uses:

- `$XDG_RUNTIME_DIR/librepods/state.json` (`/tmp` fallback), rewritten
  atomically on every device event. The service polls it (default 1.5 s) and
  publishes a snapshot the widget and panel subscribe to.
- `librepods ctl anc <mode>` and `librepods ctl ca <on|off>`, one-shot commands
  that print a JSON result. Every command triggers an immediate re-poll, so the
  UI updates in one round trip rather than at the next interval.

## Plugin

| Field | Value |
| --- | --- |
| ID | `tommyothen/librepods` |
| Entries | Service: `svc`; bar widget: `airpods`; panel: `status` |

A missing state file reads as "librepods is not running"; a file that says
`connected: false` reads as "no AirPods connected". The widget dims (or hides,
with **Hide When Disconnected**) for both, and the panel says which.

From a script or a keybind:

```sh
noctalia msg plugin tommyothen/librepods:svc all anc transparency
noctalia msg plugin tommyothen/librepods:svc all ca on
noctalia msg plugin tommyothen/librepods:svc all refresh
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `poll_interval_ms` | `int` | `1500` | How often the state file is re-read. |
| `librepods_binary` | `string` | `librepods` | The ctl binary; set an absolute path if it is not on the shell's PATH. |
| `glyph` (widget) | `glyph` | `device-airpods` | The bar icon. |
| `hide_when_disconnected` (widget) | `bool` | `false` | Remove the tile while disconnected instead of dimming it. |
