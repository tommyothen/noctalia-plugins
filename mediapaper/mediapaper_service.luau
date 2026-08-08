--!nonstrict
-- Media wallpaper, headless service.
--
-- Owns the per-output assignments and decides, per file, which of the two
-- wallpaper paths to take:
--
--   image -> noctalia.setWallpaper(), the host draws it like any other wallpaper
--   video -> an mpvpaper instance on that output, with the video's extracted still
--            frame left on the host wallpaper underneath it
--
-- The mpvpaper surface is mapped after the host's, so it composites on top and the
-- host wallpaper below is never seen. Keeping it alive is what lets host UI that
-- reads the current wallpaper keep working (see keep_host_wallpaper below).
--
-- Note: Noctalia plugin scripts run in an isolated sandbox without `require`, so
-- everything the service needs (IPC, state, process supervision) lives in here,
-- and the handful of helpers the picker also needs are duplicated in panel.luau.

-- The only thing update() does is poll for wallpaper changes made outside this plugin,
-- so the tick rate is the poll period: no idle ticks that exist just to be counted.
local POLL_INTERVAL_MS = 10000
noctalia.setUpdateInterval(POLL_INTERVAL_MS)

-- ==============================================================================
-- ── PATHS AND STATE ────────────────────────────────────────────────────────
-- ==============================================================================

local CACHE_DIR = (noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")) .. "/noctalia/mediapaper"
local STATE_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")) .. "/noctalia/mediapaper"
local STATE_FILE = STATE_DIR .. "/assignments.json"

-- Kept in sync with panel.luau. GIF counts as video so it keeps animating:
-- mpvpaper loops it, where the host wallpaper would show a single frame.
local VIDEO_EXTENSIONS = { mp4 = true, webm = true, mkv = true, mov = true, m4v = true, avi = true, gif = true }
local IMAGE_EXTENSIONS = {
  jpg = true, jpeg = true, png = true, webp = true, bmp = true,
  avif = true, jxl = true, tif = true, tiff = true,
}

local assignments = {}      -- connector -> media path ("*" for all outputs)
local launchedAsSystemd = {} -- connector -> true when the instance is a systemd scope
local lastPresent = {}      -- connector -> true (monitors seen last tick)
local isPaused = {}         -- connector -> true (frozen video)
local mpvpaperAvailable = false -- is the mpvpaper binary installed?
local expectedWall = {}     -- output name -> wallpaper path this plugin last set
local tick = 0              -- poll counter, one per update()
local graceUntil = {}       -- connector -> tick before which polling is skipped
local POLL_GRACE = 1        -- poll cycles to wait after an assignment before polling again

-- Render options the picker has changed since install, keyed the same as the settings
-- they shadow. Plugins cannot write their own settings (there is no setConfig), so the
-- panel routes changes through here and this service persists them alongside the
-- assignments; the plugin.toml settings stay the default for anything not overridden.
local overrides = {}

-- ==============================================================================
-- ── HELPERS ────────────────────────────────────────────────────────────────
-- ==============================================================================

local function cfg(key)
  return noctalia.getConfig(key)
end

-- Safely quotes strings for shell execution to prevent injection.
local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function extensionOf(path)
  local ext = path:match("%.([%a%d]+)$")
  return ext and ext:lower() or ""
end

-- "video", "image", or nil when the extension is not one we handle.
local function kindOf(path)
  if type(path) ~= "string" then return nil end
  local ext = extensionOf(path)
  if VIDEO_EXTENSIONS[ext] then return "video" end
  if IMAGE_EXTENSIONS[ext] then return "image" end
  return nil
end

local function isVideo(path)
  return kindOf(path) == "video"
end

-- Returns the systemd unit name for a given connector.
-- E.g., "*" -> "mediapaper.scope", "DP-1" -> "mediapaper-DP-1.scope".
local function unitNameFor(connector)
  if connector == "*" then
    return "mediapaper.scope"
  end
  return "mediapaper-" .. connector:gsub("[^%w%-]", "_") .. ".scope"
end

-- Builds a precise pkill -f pattern that matches only the exact connector.
-- Targets the '-p <connector>' argument followed by a space, preventing partial
-- matches (e.g., DP-1 accidentally matching DP-10 or DP-11).
local function pkillPattern(connector)
  -- Escape POSIX ERE metacharacters in the connector name (e.g., '*' for wildcard).
  local escaped = connector:gsub("([%.%*%+%?%(%)%[%]%^%$|\\{}])", "\\%1")
  return shellQuote("(^|/)mpvpaper .* " .. escaped .. " ")
end

-- Executes a function for every affected physical output.
-- Avoids massive code duplication for wildcard ("*") assignments.
local function forEachOutput(connector, fn)
  if connector == "*" then
    for _, output in ipairs(noctalia.outputs()) do
      fn(output.name)
    end
  else
    fn(connector)
  end
end

local function beginGrace(connector)
  graceUntil[connector] = tick + POLL_GRACE
end

-- ==============================================================================
-- ── RENDER OPTIONS ─────────────────────────────────────────────────────────
-- ==============================================================================
--
-- Declared above the state file because loading it validates against them.

-- How the video is framed inside the output. `fill` scales until both axes are
-- covered and crops the overflow; `fit` scales until the first axis fits and letterboxes
-- the rest, which leaves a source no larger than the output at 1:1 and therefore sharp;
-- `stretch` drops the aspect ratio and distorts to fit exactly.
local FIT_MODES = {
  fill = { "panscan=1.0" },
  fit = { "panscan=0.0" },
  stretch = { "panscan=0.0", "keepaspect=no" },
}

-- Renderer presets. `high` pays off when the source is smaller than the output and mpv
-- has to scale it up: ewa_lanczossharp holds edges that the default lanczos softens, and
-- deband covers the banding that upscaling flat gradients exposes. Both run on every
-- frame for as long as the wallpaper plays, so this is a standing GPU cost.
local RENDER_QUALITY = {
  default = {},
  high = {
    "scale=ewa_lanczossharp",
    "scale-antiring=0.7",
    "dscale=mitchell",
    "deband=yes",
    "deband-iterations=2",
  },
}

-- The options the picker can drive, listed in the order its dropdowns show them.
-- Every value is checked against this before being stored or used, so neither a hand
-- edited state file nor a stale config can put arbitrary text on the mpv command line.
local RENDER_OPTIONS = {
  fit_mode = { keys = { "fill", "fit", "stretch" }, fallback = "fill" },
  render_quality = { keys = { "default", "high" }, fallback = "default" },
}

local function isValidOption(key, value)
  local spec = RENDER_OPTIONS[key]
  if spec == nil or type(value) ~= "string" then return false end
  for _, candidate in ipairs(spec.keys) do
    if candidate == value then return true end
  end
  return false
end

-- A picker override wins over the settings entry, which itself gives way to the
-- declared default whenever the config holds something unrecognised.
local function renderOption(key)
  if isValidOption(key, overrides[key]) then return overrides[key] end
  local configured = cfg(key)
  if isValidOption(key, configured) then return configured end
  return RENDER_OPTIONS[key].fallback
end

-- ==============================================================================
-- ── STATE PERSISTENCE ──────────────────────────────────────────────────────
-- ==============================================================================

-- The state directory is created once at boot, so this is only the write.
local function persist()
  noctalia.writeFile(STATE_FILE, noctalia.json.encode({
    assignments = assignments,
    launchedAsSystemd = launchedAsSystemd,
    overrides = overrides
  }) or "")
end

local function loadAssignments()
  local content = noctalia.readFile(STATE_FILE)
  if type(content) == "string" and content ~= "" then
    local decoded = noctalia.json.decode(content)
    if type(decoded) == "table" then
      if decoded.assignments then
        assignments = decoded.assignments
        launchedAsSystemd = decoded.launchedAsSystemd or {}
        if type(decoded.overrides) == "table" then
          for key, value in pairs(decoded.overrides) do
            if isValidOption(key, value) then overrides[key] = value end
          end
        end
      else
        assignments = decoded
      end
    end
  end
end

-- Every published key the panel watches costs it a full widget tree rebuild, and one
-- pick touches at most one of them, so the last published value of each is kept here
-- and unchanged keys are left alone. The values are flat maps of strings and booleans,
-- which is all the comparison and the copy have to handle.
local published = {}

local function flatEqual(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  for key, value in pairs(a) do
    if b[key] ~= value then return false end
  end
  for key, value in pairs(b) do
    if a[key] ~= value then return false end
  end
  return true
end

local function publishKey(key, value)
  if flatEqual(published[key], value) then return end
  if type(value) == "table" then
    local copy = {}
    for k, v in pairs(value) do copy[k] = v end
    published[key] = copy
  else
    published[key] = value
  end
  noctalia.state.set(key, value)
end

-- Publishes the internal state so the panel can read it (tile highlights, paused UI).
local function publish()
  publishKey("assignments", assignments)
  publishKey("available", mpvpaperAvailable)
  publishKey("paused", isPaused)
  -- Resolved rather than raw, so the picker's dropdowns show what mpv is actually
  -- running even for the options nobody has touched.
  publishKey("renderOptions", {
    fit_mode = renderOption("fit_mode"),
    render_quality = renderOption("render_quality"),
  })
end

-- ==============================================================================
-- ── COMMAND BUILDERS ───────────────────────────────────────────────────────
-- ==============================================================================

-- Builds the -o options string forwarded to the internal mpv process.
local function mpvOptions()
  local parts = { "loop-file=inf" }

  local function appendAll(list)
    for _, option in ipairs(list) do table.insert(parts, option) end
  end

  appendAll(FIT_MODES[renderOption("fit_mode")])
  appendAll(RENDER_QUALITY[renderOption("render_quality")])

  -- mpvpaper splits this string on whitespace before handing it to mpv, so a shader
  -- path containing a space cannot survive the trip and is dropped rather than passed
  -- through as two broken options.
  local shader = cfg("glsl_shader")
  if type(shader) == "string" and shader ~= "" and not shader:find("%s") then
    table.insert(parts, "glsl-shaders-append=" .. shader)
  end

  if cfg("mute") then table.insert(parts, "no-audio") end
  table.insert(parts, "hwdec=" .. (cfg("hardware_decode") and "auto" or "no"))

  -- Last, so a hand-written option wins over anything the settings above produced.
  local extra = cfg("mpv_options")
  if type(extra) == "string" and extra ~= "" then table.insert(parts, extra) end
  return table.concat(parts, " ")
end

local function mpvpaperFlags()
  if cfg("auto_pause") then return "--auto-pause" end
  return ""
end

-- Collects systemd-specific cgroup properties (e.g., CPUQuota).
local function systemdProperties()
  local props = {}
  local cpu_quota = cfg("cpu_quota")
  if type(cpu_quota) == "number" and cpu_quota > 0 then table.insert(props, "CPUQuota=" .. tostring(cpu_quota) .. "%") end

  local allowed_cpus = cfg("allowed_cpus")
  if type(allowed_cpus) == "string" and allowed_cpus ~= "" then table.insert(props, "AllowedCPUs=" .. allowed_cpus) end

  local memory_max = cfg("memory_max")
  if type(memory_max) == "string" and memory_max ~= "" then table.insert(props, "MemoryMax=" .. memory_max) end

  local cpu_weight = cfg("cpu_weight")
  if type(cpu_weight) == "number" and cpu_weight > 0 then table.insert(props, "CPUWeight=" .. tostring(cpu_weight)) end

  return props
end

-- ==============================================================================
-- ── THUMBNAILS & FRAME EXTRACTION ──────────────────────────────────────────
-- ==============================================================================

-- The still frame for a video, at the source's own resolution. It stands in for the
-- video on the host wallpaper twice over: underneath a playing mpvpaper surface, and
-- on its own once playback stops. The picker's thumbnails are far too small to serve
-- either purpose, so this is a separate cache entry keyed by the video path, extracted
-- once and reused.
local function stillPath(videoPath)
  return CACHE_DIR .. "/" .. videoPath:gsub("[^%w]", "_") .. "_still.jpg"
end

local function ensureStill(videoPath, done)
  local outPath = stillPath(videoPath)
  if noctalia.fileExists(outPath) then
    done(outPath)
    return
  end

  noctalia.runAsync("mkdir -p " .. shellQuote(CACHE_DIR), function()
    local cmd = "ffmpeg -y -ss 1 -i " .. shellQuote(videoPath) .. " -frames:v 1 -q:v 2 " .. shellQuote(outPath)
    noctalia.runAsync(cmd, function(success)
      done(success and noctalia.fileExists(outPath) and outPath or nil)
    end)
  end)
end

local function applyStill(connector, path)
  forEachOutput(connector, function(name)
    noctalia.setWallpaper(name, path)
    noctalia.setWallpaperEnabled(name, true)
    expectedWall[name] = path
  end)
end

-- Stopping a video leaves the output with whatever the host last had, which is
-- usually the still this plugin set at launch. Putting the still back gives a
-- static wallpaper that matches what was playing. Turn the setting off to fall
-- back to the host's own wallpaper instead, which (if the last thing you picked
-- here was an image) is that image.
local function extractStaticWallpaper(connector, videoPath)
  if not cfg("extract_last_frame") then
    forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
    return
  end

  ensureStill(videoPath, function(outPath)
    if outPath then
      applyStill(connector, outPath)
    else
      forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
    end
  end)
end

-- ==============================================================================
-- ── PROCESS MANAGEMENT ─────────────────────────────────────────────────────
-- ==============================================================================

-- Kills the mpvpaper process.
-- Note on pkill: The sandboxed noctalia.runAsync API does not return PIDs. Thus,
-- without systemd, matching by command line via pkill is the only reliable way to terminate it.
local function killMpvpaper(connector, callback, signal)
  local sig = (type(signal) == "number" and signal > 0) and signal or 15
  local killCmd
  local pattern = pkillPattern(connector)
  if launchedAsSystemd[connector] then
    local unitName = unitNameFor(connector)
    if isPaused[connector] then
      -- A frozen cgroup ignores SIGTERM. We must thaw it right before stopping.
      killCmd = "systemctl --user thaw " .. shellQuote(unitName) .. " ; systemctl --user stop " .. shellQuote(unitName)
    else
      killCmd = "systemctl --user stop " .. shellQuote(unitName)
    end
  elseif isPaused[connector] then
    -- A SIGSTOP'd process ignores SIGTERM. We must resume it right before killing.
    killCmd = "pkill -CONT -f -- " .. pattern .. " ; pkill -" .. sig .. " -f -- " .. pattern
  else
    killCmd = "pkill -" .. sig .. " -f -- " .. pattern
  end

  isPaused[connector] = false

  if callback then
    noctalia.runAsync(killCmd, callback)
  else
    noctalia.runAsync(killCmd)
  end
end

-- Spawns a new mpvpaper instance for the given connector.
local function startMpvpaper(connector, path)
  -- Set the cached still as the background to prevent black screens during startup,
  -- and, with keep_host_wallpaper on, to leave host UI that reads the current
  -- wallpaper something that matches the video. The first launch of a given video has
  -- nothing cached yet, so it is extracted and applied a moment late instead.
  beginGrace(connector)
  local still = stillPath(path)
  if noctalia.fileExists(still) then
    applyStill(connector, still)
  elseif cfg("keep_host_wallpaper") then
    ensureStill(path, function(ready)
      if ready and assignments[connector] == path then
        beginGrace(connector)
        applyStill(connector, ready)
      end
    end)
  end

  killMpvpaper(connector, function()
    launchedAsSystemd[connector] = cfg("run_as_systemd")
    persist()
    local flags = mpvpaperFlags()
    local cmd = "mpvpaper "
    if flags ~= "" then cmd = cmd .. flags .. " " end
    cmd = cmd .. "-o " .. shellQuote(mpvOptions()) .. " " .. shellQuote(connector) .. " " .. shellQuote(path) -- mpvpaper -o [mpv-options] [connector] [video-path]

    local nice = cfg("nice")
    if type(nice) == "number" and nice ~= 0 then
      cmd = "nice -n " .. tostring(nice) .. " " .. cmd
    end

    if launchedAsSystemd[connector] then
      local unitName = unitNameFor(connector)
      local propsCmd = ""
      for _, prop in ipairs(systemdProperties()) do
        propsCmd = propsCmd .. "--property=" .. shellQuote(prop) .. " "
      end
      cmd = "systemd-run --user --scope " .. propsCmd .. "--unit=" .. shellQuote(unitName) .. " " .. cmd
    end

    -- Run mpvpaper in background
    noctalia.runAsync("exec " .. cmd .. " >/dev/null 2>&1 &", function() end)
    -- Dropping the host wallpaper surface saves it rendering a frame nobody sees, but
    -- Noctalia's Wallpaper::currentPath() only reports paths from live wallpaper
    -- instances. With the surface gone, the control center user card (which draws the
    -- current wallpaper as its background) renders blank. Leaving it up costs one
    -- static texture and keeps that working, so it is the default.
    if not cfg("keep_host_wallpaper") then
      noctalia.runAsync("sleep 0.8", function()
        forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, false) end)
      end)
    end
  end)
end

-- mpvpaper reads its mpv options and its systemd wrapper once, at launch, and has no way
-- to be told about either afterwards, so a change to one of them only reaches a playing
-- video by relaunching it. Images are untouched: none of these options mean anything to
-- a still wallpaper.
local function restartVideos()
  if not mpvpaperAvailable then return end
  for connector, path in pairs(assignments) do
    if isVideo(path) then startMpvpaper(connector, path) end
  end
end

-- ==============================================================================
-- ── PAUSE / RESUME / TOGGLE ────────────────────────────────────────────────
-- ==============================================================================

local function freezeMpvpaper(connector)
  if not isVideo(assignments[connector]) then return end
  isPaused[connector] = true
  if cfg("run_as_systemd") then
    local unitName = unitNameFor(connector)
    noctalia.runAsync("systemctl --user freeze " .. shellQuote(unitName))
  else
    -- Send SIGSTOP to freeze the process in place, preserving the last frame on screen.
    noctalia.runAsync("pkill -STOP -f -- " .. pkillPattern(connector))
  end
end

local function thawMpvpaper(connector)
  if not isVideo(assignments[connector]) then return end
  isPaused[connector] = false
  if cfg("run_as_systemd") then
    local unitName = unitNameFor(connector)
    noctalia.runAsync("systemctl --user thaw " .. shellQuote(unitName))
  else
    -- Send SIGCONT to resume the frozen process.
    noctalia.runAsync("pkill -CONT -f -- " .. pkillPattern(connector))
  end
end

local function toggleMpvpaper(connector)
  if isPaused[connector] then
    thawMpvpaper(connector)
  else
    freezeMpvpaper(connector)
  end
end

-- ==============================================================================
-- ── CORE ASSIGNMENT LOGIC ──────────────────────────────────────────────────
-- ==============================================================================

-- Drops an assignment without touching the host wallpaper, then runs `done`.
-- Used when a new pick is about to replace this one, so there is no point
-- extracting a frame or restoring a surface that is about to change again.
local function stopAssignment(connector, done)
  local path = assignments[connector]
  assignments[connector] = nil
  forEachOutput(connector, function(name) expectedWall[name] = nil end)
  if isVideo(path) then
    killMpvpaper(connector, done)
  elseif done then
    done()
  end
end

-- A wildcard assignment and a per-output one cannot both hold an output, so
-- picking one side clears the other.
local function resolveOverlaps(connector, done)
  local pending = {}
  if connector == "*" then
    for conn in pairs(assignments) do
      if conn ~= "*" then table.insert(pending, conn) end
    end
  elseif assignments["*"] then
    table.insert(pending, "*")
  end

  if #pending == 0 then
    done()
    return
  end

  -- stopAssignment is asynchronous for videos; wait for all of them before applying.
  local remaining = #pending
  for _, conn in ipairs(pending) do
    stopAssignment(conn, function()
      remaining -= 1
      if remaining == 0 then done() end
    end)
  end
end

-- Clears an assignment and hands the output back to the host.
local function clearMedia(connector)
  if type(connector) ~= "string" or connector == "" then return end

  local path = assignments[connector]
  assignments[connector] = nil
  persist()
  beginGrace(connector)
  forEachOutput(connector, function(name) expectedWall[name] = nil end)

  if isVideo(path) then
    killMpvpaper(connector, function()
      extractStaticWallpaper(connector, path)
    end)
  else
    -- An image assignment is just a highlight in the picker: the wallpaper itself
    -- belongs to the host and stays exactly where it is.
    forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
  end

  publish()
end

-- The wallpaper changed from outside this plugin (detected by the poll in
-- update()): let go of the output WITHOUT extracting a frame or otherwise
-- overwriting whatever the user just chose.
local function releaseMedia(connector)
  local path = assignments[connector]
  if not path then return end
  assignments[connector] = nil
  persist()
  forEachOutput(connector, function(name) expectedWall[name] = nil end)
  if isVideo(path) then
    killMpvpaper(connector, function()
      forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
    end)
  end
  publish()
end

local function applyImage(connector, path)
  beginGrace(connector)
  forEachOutput(connector, function(name)
    noctalia.setWallpaper(name, path)
    noctalia.setWallpaperEnabled(name, true)
    expectedWall[name] = path
  end)
end

-- Assigns a file to a specific monitor or globally ("*"), routing on file type.
local function setMedia(connector, path)
  if type(connector) ~= "string" or connector == "" then return end
  if type(path) ~= "string" or path == "" then return end

  local kind = kindOf(path)
  if kind == nil then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("unsupported_file", { name = path }))
    return
  end
  if kind == "video" and not mpvpaperAvailable then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("not_installed"))
    return
  end

  resolveOverlaps(connector, function()
    local wasVideo = isVideo(assignments[connector])
    assignments[connector] = path
    persist()

    if kind == "video" then
      startMpvpaper(connector, path)
    elseif wasVideo then
      -- Tear the video down first, or its surface keeps covering the new image.
      killMpvpaper(connector, function()
        applyImage(connector, path)
      end)
    else
      applyImage(connector, path)
    end

    publish()
  end)
end

-- ==============================================================================
-- ── LIFECYCLE ──────────────────────────────────────────────────────────────
-- ==============================================================================

-- Returns a quick dictionary of currently attached physical monitors.
local function presentOutputs()
  local present = {}
  for _, output in ipairs(noctalia.outputs()) do present[output.name] = true end
  return present
end

local function applyAssignment(connector, path)
  if isVideo(path) then
    if mpvpaperAvailable then startMpvpaper(connector, path) end
  else
    applyImage(connector, path)
  end
end

-- Re-applies saved assignments on startup.
local function applyAll()
  for connector, path in pairs(assignments) do
    applyAssignment(connector, path)
  end
end

-- Poll whether the host's effective wallpaper still matches what this plugin set. A
-- mismatch means the wallpaper was changed from elsewhere (the wallpaper panel,
-- `noctalia msg wallpaper-set`, a rotation timer), so let go of the output instead of
-- keeping the user's choice hidden behind a video layer or a stale highlight.
--
-- There is no wallpaper-changed callback in the plugin API to hang this on, so it is a
-- poll, and every poll spawns `noctalia msg wallpaper-get` per output. POLL_INTERVAL_MS
-- trades how long a stale video stays on top of a wallpaper the user just picked (worst
-- case one interval) against a process spawn that otherwise never stops for as long as
-- an assignment exists. With nothing assigned there is nothing to poll for.
function update()
  tick = tick + 1
  if next(assignments) == nil then return end
  for connector in pairs(assignments) do
    if not (graceUntil[connector] and tick < graceUntil[connector]) then
      forEachOutput(connector, function(name)
        local expected = expectedWall[name]
        if not expected then return end
        noctalia.runAsync("noctalia msg wallpaper-get " .. shellQuote(name) .. " 2>/dev/null", function(result)
          if type(result) ~= "table" then return end
          local cur = (result.stdout or ""):gsub("%s+$", "")
          if cur ~= "" and cur ~= expected and assignments[connector] then
            releaseMedia(connector)
          end
        end)
      end)
    end
  end
end

-- Triggers when a monitor connects or disconnects.
function onOutputsChanged()
  local present = presentOutputs()

  local newMonitor = false
  for conn in pairs(present) do
    if not lastPresent[conn] then newMonitor = true end
  end

  -- Automatically apply the wildcard assignment to newly connected monitors.
  if newMonitor and assignments["*"] then
    applyAssignment("*", assignments["*"])
  end

  -- Relaunch specific assignments for monitors that just connected.
  for connector, path in pairs(assignments) do
    if connector ~= "*" then
      if present[connector] and not lastPresent[connector] then
        applyAssignment(connector, path)
      end
    end
  end

  lastPresent = present
end

-- Called when the plugin is disabled, removed, or Noctalia is shutting down.
-- Terminates every running mpvpaper instance so no orphan processes remain.
-- Handles both direct processes (pkill) and systemd scopes (systemctl stop),
-- including thawing frozen/paused instances before sending SIGTERM. Image
-- assignments own no process and need no teardown.
function onExit(signal)
  for connector, path in pairs(assignments) do
    if isVideo(path) then
      killMpvpaper(connector, nil, signal)
    end
  end
end

-- ==============================================================================
-- ── IPC (COMMUNICATION WITH PANEL) ─────────────────────────────────────────
-- ==============================================================================

function onIpc(event, payload)
  if event == "clear-all" then
    for connector, path in pairs(assignments) do
      if isVideo(path) then
        killMpvpaper(connector, function()
          extractStaticWallpaper(connector, path)
        end)
      else
        forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
      end
      forEachOutput(connector, function(name) expectedWall[name] = nil end)
    end
    assignments = {}
    persist()
    publish()

  elseif event == "clear" then
    clearMedia(payload)

  elseif event == "pause" or event == "freeze" then
    if type(payload) == "string" and payload ~= "" then
      freezeMpvpaper(payload)
    else
      for conn in pairs(assignments) do freezeMpvpaper(conn) end
    end
    publish()

  elseif event == "resume" or event == "thaw" then
    if type(payload) == "string" and payload ~= "" then
      thawMpvpaper(payload)
    else
      for conn in pairs(assignments) do thawMpvpaper(conn) end
    end
    publish()

  elseif event == "toggle" then
    if type(payload) == "string" and payload ~= "" then
      toggleMpvpaper(payload)
    else
      for conn in pairs(assignments) do toggleMpvpaper(conn) end
    end
    publish()
  end
end

-- Stores a render option the picker changed and restarts whatever is already playing.
local function setRenderOption(key, value)
  if not isValidOption(key, value) then
    noctalia.log("mediapaper: ignoring invalid render option " .. tostring(key) .. "=" .. tostring(value))
    return
  end
  if renderOption(key) == value then return end

  overrides[key] = value
  persist()

  restartVideos()
  publish()
end

-- Listen to the panel UI commands.
noctalia.state.watch("command", function(cmd)
  if type(cmd) ~= "table" then return end
  if cmd.action == "set" then setMedia(cmd.connector, cmd.path)
  elseif cmd.action == "set-option" then setRenderOption(cmd.key, cmd.value)
  elseif cmd.action == "clear" then clearMedia(cmd.connector)
  elseif cmd.action == "clear-all" then onIpc("clear-all", nil)
  elseif cmd.action == "freeze" then onIpc("freeze", cmd.connector)
  elseif cmd.action == "thaw" then onIpc("thaw", cmd.connector)
  elseif cmd.action == "toggle" then onIpc("toggle", cmd.connector) end
end)

-- ==============================================================================
-- ── BOOT ───────────────────────────────────────────────────────────────────
-- ==============================================================================

-- The wallcheck_* files are leftovers from when the wallpaper poll wrote its output to
-- disk instead of reading it from the callback. Nothing reads them any more.
noctalia.runAsync("mkdir -p " .. shellQuote(STATE_DIR) .. " ; rm -f " .. shellQuote(STATE_DIR) .. "/wallcheck_*")
loadAssignments()

-- Images work without mpvpaper, so a missing binary narrows the plugin to an
-- image picker rather than disabling it. The picker says so, and the error only
-- surfaces if a video is actually picked.
mpvpaperAvailable = noctalia.commandExists("mpvpaper")
lastPresent = presentOutputs()
applyAll()

publish()

-- The settings that end up on the mpvpaper command line, or in the nice/systemd-run
-- wrapper around it. These are the only ones a running video cannot pick up on its own.
-- The rest are read fresh the next time they matter: the source directories belong to
-- the picker, extract_last_frame is only consulted when an assignment goes away.
local LAUNCH_KEYS = {
  fit_mode = true,
  render_quality = true,
  glsl_shader = true,
  mute = true,
  hardware_decode = true,
  auto_pause = true,
  mpv_options = true,
  keep_host_wallpaper = true,
  run_as_systemd = true,
  nice = true,
  cpu_quota = true,
  allowed_cpus = true,
  memory_max = true,
  cpu_weight = true,
}

-- Called when any configuration setting is changed. Restarting playback is a visible
-- flicker per output, so it happens only for the settings that reach mpvpaper.
function onConfigChanged(key, value)
  if type(key) ~= "string" or not LAUNCH_KEYS[key] then return end

  if RENDER_OPTIONS[key] ~= nil then
    -- A picker override shadows the settings entry, so the setting moving underneath it
    -- changes nothing mpv would see.
    if isValidOption(key, overrides[key]) then return end
    -- The picker's dropdowns show the resolved value, so they have to hear about this.
    publish()
  end

  restartVideos()
end
