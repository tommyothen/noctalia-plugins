# Media Wallpaper

One picker for still wallpapers and video wallpapers. Click a photo and Noctalia sets it
as the wallpaper the way it always does. Click a video and it plays through
[mpvpaper](https://github.com/GhostNaN/mpvpaper) instead.

Noctalia cannot decode video itself. mpvpaper draws its own `wlr-layer-shell` background
surface, so when you assign a video the plugin asks Noctalia to drop its wallpaper on that
output and the video shows through. The bar and the dock still draw on top. Picking an
image on the same output kills the video and hands the surface back.

Derived from [`noctalia/mpvpaper`](https://github.com/noctalia-dev/official-plugins/tree/main/mpvpaper)
1.0.7 by the Noctalia team, which is MIT licensed. The video path is largely theirs. Image
support, recursive scanning, the second source directory and the auto release behaviour are
additions.

## Plugin

| Field | Value |
| --- | --- |
| ID | `tommyothen/mediapaper` |
| Entries | Service: `service`; Panel: `picker`; bar widget: `mediapaper` |

## Requirements

Setting an image needs nothing installed beyond Noctalia, though `mpv` makes its grid
thumbnail. Without `mpv` the tile falls back to an empty frame and the picker still works.
If `mpvpaper` is missing the picker says so and carries on as an image picker.

Videos need `mpvpaper` and `mpv` on `PATH`. mpvpaper renders the wallpaper surface and mpv
makes the grid thumbnails, for images as well as videos. `ffmpeg` captures the full size
still frame of a video, which sits on Noctalia's wallpaper under the playing surface and
stays there when you stop it. The stop half of that can be turned off.

The video half works on `wlr-layer-shell` compositors (Niri, Hyprland, Sway, Mango). The
image half has no compositor requirement.

## Usage

1. Set **Media directory** in the plugin settings. Leave it empty and the plugin uses the
   wallpaper folder from your Noctalia settings.
2. Add the **Media Wallpaper** bar widget, or open the picker with

   ```sh
   noctalia msg panel-toggle tommyothen/mediapaper:picker
   ```

3. Choose a target output (or **All outputs**), then click a tile to apply it. The **All**,
   **Images** and **Videos** buttons filter the grid; the refresh button rescans the
   directories.
4. **Pause** freezes a playing video on its current frame. It does nothing for an image, so
   the button is disabled for one.
5. **Stop** releases the output. For a video that means killing the process and leaving a
   still frame behind. For an image it only clears the highlight in the grid, because the
   wallpaper itself already belongs to Noctalia.

Assignments survive restarts and reconnected monitors.

### Where your files live

Two layouts work. If you keep everything under one root, point **Media directory** at it and
leave **Search subfolders** on:

```
~/Wallpapers/
  images/
  videos/
```

If you would rather be explicit, turn **Search subfolders** off and set **Media directory**
to `~/Wallpapers/images` and **Extra directory** to `~/Wallpapers/videos`. Both directories
are scanned either way, so you can also combine them.

Files starting with a dot are skipped. The scan stops at 2000 files and tells you when it
has, so a stray symlink into your home directory cannot hang the picker.

### File types

| Kind | Extensions |
| --- | --- |
| Image | `jpg`, `jpeg`, `png`, `webp`, `bmp`, `avif`, `jxl`, `tif`, `tiff` |
| Video | `mp4`, `webm`, `mkv`, `mov`, `m4v`, `avi`, `gif` |

`gif` is treated as video on purpose. Routing it through mpvpaper keeps it animating, where
Noctalia's own wallpaper would show a single frame. Its grid tile is a still, like every
other tile.

### Thumbnails

Every tile in the grid is drawn from a downscaled JPEG in
`$XDG_CACHE_HOME/noctalia/mediapaper`, bounded to 480 pixels on the long edge and named
`*.t480.jpg`. Source files are never handed to the grid directly: a tile is 214x120, and the
panel has no way to ask Noctalia to decode an image at less than its full size, so a wall of
4K sources would cost hundreds of megabytes of decoded pixels for tiles that can show a
fraction of one percent of them. The first open of a directory extracts them in the background, four at a time, and the grid
fills in as they land. Entries written under a different naming scheme are deleted on open.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `media_directory` | `folder` | *(empty)* | Folder scanned for images and videos. Empty falls back to the wallpaper folder in your Noctalia settings. |
| `extra_directory` | `folder` | *(empty)* | Optional second folder to scan. |
| `recursive` | `bool` | `true` | Walk subfolders of both directories. |
| `max_depth` | `int` | `4` | How many levels below each source folder to walk. Requires `recursive`. |
| `mute` | `bool` | `true` | Starts video wallpapers muted. |
| `fit_mode` | `select` | `fill` | How a video is framed when its aspect ratio does not match the output: `fill` crops the overflowing edges, `fit` letterboxes, `stretch` distorts. Also in the picker, which overrides this. |
| `render_quality` | `select` | `default` | `high` switches to a sharper scaler (`ewa_lanczossharp`) and enables debanding. Also in the picker, which overrides this. |
| `glsl_shader` | `file` | *(empty)* | Optional `mpv` GLSL user shader, for upscalers such as Anime4K or FSRCNNX. The path cannot contain spaces. |
| `hardware_decode` | `bool` | `true` | Uses `mpv` hardware decoding. |
| `auto_pause` | `bool` | `true` | Pauses playback while a fullscreen window covers the wallpaper. |
| `mpv_options` | `string` | *(empty)* | Additional space-separated `mpv` options, applied last so they override every setting above. |
| `extract_last_frame` | `bool` | `true` | Captures a frame to use as the wallpaper when a video stops. Off falls back to whatever wallpaper Noctalia already holds, which is usually the last image you picked here. |
| `keep_host_wallpaper` | `bool` | `true` | Keeps Noctalia's own wallpaper alive under a playing video, set to that video's still frame. The video covers it, and Noctalia panels that draw the current wallpaper keep working. Off drops the surface to save a texture. |
| `run_as_systemd` | `bool` | `false` | Runs instances inside systemd transient scopes (`systemd-run`) for resource control. |
| `cpu_quota` | `int` | `0` | Systemd `CPUQuota=` limit in percent. Requires `run_as_systemd`. |
| `allowed_cpus` | `string` | *(empty)* | Systemd `AllowedCPUs=` limit (e.g. `0-3`). Requires `run_as_systemd`. |
| `memory_max` | `string` | *(empty)* | Systemd `MemoryMax=` limit (e.g. `500M`). Requires `run_as_systemd`. |
| `cpu_weight` | `int` | `0` | Systemd `CPUWeight=` priority. Requires `run_as_systemd`. |
| `nice` | `int` | `0` | Process `nice` level. Requires `run_as_systemd`. |
| `glyph` | `glyph` | `photo-video` | Bar widget icon. |

## IPC

Replace `[connector]` with a display name such as `DP-1`, or leave it off to hit every
monitor. The pause commands only affect outputs playing a video.

- `noctalia msg plugin tommyothen/mediapaper:service all pause [connector]` freezes playback.
- `noctalia msg plugin tommyothen/mediapaper:service all resume [connector]` resumes it.
- `noctalia msg plugin tommyothen/mediapaper:service all toggle [connector]` flips between the two.
- `noctalia msg plugin tommyothen/mediapaper:service all clear <connector>` releases one output.
- `noctalia msg plugin tommyothen/mediapaper:service all clear-all` releases every output.

## Notes

### Changing the wallpaper elsewhere releases the output

Every ten seconds the service compares what Noctalia reports for an output against
what the plugin last set there. If they differ, something else changed the wallpaper: the
wallpaper panel, `noctalia msg wallpaper-set`, a rotation timer. The plugin then drops its
claim, and stops the video if one was running. Without this a video keeps covering the
wallpaper you just chose. Upstream `noctalia/mpvpaper` has no equivalent.

The plugin API has no wallpaper-changed callback to hang this on, so it is a poll, and each
one spawns `noctalia msg wallpaper-get` per claimed output. Ten seconds is the compromise:
a wallpaper picked elsewhere can spend up to that long hidden behind a video, and the rest
of the time nothing runs.

### Processes

One `mpvpaper` runs per output with a video assigned, optionally inside a
`systemd-run --user --scope` unit. `mpv` runs briefly to make each grid thumbnail and
`ffmpeg` runs briefly to capture a video's still frame. Both results are cached, so a file
costs each of them once. The plugin kills instances by matching their
command line with `pkill -f` when there is no systemd scope to stop, because the plugin API
does not hand back PIDs. When the plugin is disabled or Noctalia exits, `onExit` terminates
every instance, frozen ones included.

### Filesystem and network

The plugin reads the configured directories and writes nothing into them. Thumbnails go to
`$XDG_CACHE_HOME/noctalia/mediapaper` and saved assignments to
`$XDG_STATE_HOME/noctalia/mediapaper`. It makes no network requests.

### What recursive scanning costs

The walk is synchronous, so a huge tree is felt as a pause when the picker opens. Once a
scan has been done the picker draws it immediately on later opens and refreshes behind the
first frame, and the refresh button forces a fresh one. `max_depth` and `recursive` are the
levers if a directory is large enough to be worth bounding.
