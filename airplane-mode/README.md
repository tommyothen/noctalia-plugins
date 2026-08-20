# Airplane Mode

Phone-style airplane mode for the noctalia control center: one tile that soft-blocks
every radio through `rfkill block all` and unblocks with a second tap. The tile is
lit while every soft-blockable radio is blocked; hard-blocked devices (a physical
kill switch) are ignored, since software cannot change them.

## Requirements

- `rfkill` (util-linux)
- Write access to `/dev/rfkill` — membership in the `rfkill` group under Arch's
  default udev rules. Without it the toggle fails with a notification.

## Usage

Enable the plugin and add its tile to the control center shortcuts:

```toml
[[control_center.shortcuts]]
type = "tommyothen/airplane-mode:toggle"
```

The same toggle is reachable over shell IPC for keybinds:

```
noctalia msg plugin tommyothen/airplane-mode:svc all toggle
```
