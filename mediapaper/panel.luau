--!nonstrict
-- Media wallpaper picker.
--
-- Walks the configured source directories, shows images and videos in one grid,
-- and hands the pick to the headless service through the shared "command" state
-- channel. The service decides what to do with it: images go to the host, videos
-- go to mpvpaper.
--
-- Note: Noctalia sandboxed plugins have no `require`, so the extension tables and
-- the shell-quoting helper are duplicated from mediapaper_service.luau.

local PANEL_WIDTH = 920
local PANEL_PADDING = 28
local COLUMNS = 4
local COLUMN_GAP = 12
local PAGE_SIZE = 24
local THUMB_MAX_CONCURRENT = 4
local TILE_RADIUS = 12

-- Tiles are 214x120 logical pixels, so 480 on the long edge covers them twice over
-- at any sane display scale. The host's ui.image has no decode-size cap, so whatever
-- is cached here is what gets decoded into memory: a 4K source is 8.3 megapixels for
-- a tile that can show 0.026 of them.
local THUMB_LONG_EDGE = 480
-- Part of the cache file name. Bump it whenever the extraction changes, so entries
-- written by an older version are ignored rather than reused at the wrong size.
local THUMB_SUFFIX = ".t480.jpg"

-- Refuse to walk forever into a pathological tree. Hit either ceiling and the
-- picker says so rather than silently showing a truncated library.
local MAX_ITEMS = 2000

local VIDEO_EXTENSIONS = { mp4 = true, webm = true, mkv = true, mov = true, m4v = true, avi = true, gif = true }
local IMAGE_EXTENSIONS = {
  jpg = true, jpeg = true, png = true, webp = true, bmp = true,
  avif = true, jxl = true, tif = true, tiff = true,
}

local CACHE_DIR = (noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")) .. "/noctalia/mediapaper"

local media = {}        -- { { path=, label=, kind= }, ... } after filtering
local allMedia = {}     -- everything the scan found, unfiltered
local imageCount = 0    -- counted while scanning, not while rendering
local videoCount = 0
local filterKind = ""   -- "" = everything, else "image" or "video"
local page = 1
local outputsList = {}
local selectedConnectorName = "" -- empty = all outputs
local mpvpaperAvailable = true
local errorMessage = ""
local truncated = false
local cmdNonce = 0

local thumbPaths = {}   -- path -> displayable image path (ready)
local thumbPending = {} -- path -> true while mpv is extracting
local thumbQueue = {}
local thumbActive = 0

local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function extensionOf(name)
  local ext = name:match("%.([%a%d]+)$")
  return ext and ext:lower() or ""
end

local function kindOf(name)
  local ext = extensionOf(name)
  if VIDEO_EXTENSIONS[ext] then return "video" end
  if IMAGE_EXTENSIONS[ext] then return "image" end
  return nil
end

-- ── Source directories ─────────────────────────────────────────────────────

local function configuredDir(key)
  local dir = noctalia.getConfig(key)
  if type(dir) == "string" and dir ~= "" then
    return noctalia.expandPath(dir)
  end
  return nil
end

-- The primary directory falls back to whatever the host already uses for
-- wallpapers, so a fresh install lists something useful without being configured.
local function sourceRoots()
  local roots = {}
  local primary = configuredDir("media_directory")
  if primary == nil then
    local hostDir = noctalia.wallpaperDirectory()
    if type(hostDir) == "string" and hostDir ~= "" then
      primary = hostDir
    else
      primary = (noctalia.getenv("HOME") or "/tmp") .. "/Pictures"
    end
  end
  table.insert(roots, primary)

  local extra = configuredDir("extra_directory")
  if extra ~= nil and extra ~= primary then
    table.insert(roots, extra)
  end
  return roots
end

local function maxDepth()
  if noctalia.getConfig("recursive") ~= true then return 0 end
  local depth = noctalia.getConfig("max_depth")
  if type(depth) == "number" and depth > 0 then return math.floor(depth) end
  return 4
end

-- ── State shared with the service ──────────────────────────────────────────
--
-- Read once into a snapshot rather than per lookup: a render asks about the
-- assignment of every tile, times every output under "All Outputs", and the whole
-- tree is built from one consistent view of the service's state either way.

local snapAssignments = {}
local snapPaused = {}
local snapRenderOptions = {}

local function refreshState()
  local assignments = noctalia.state.get("assignments")
  snapAssignments = type(assignments) == "table" and assignments or {}

  local paused = noctalia.state.get("paused")
  snapPaused = type(paused) == "table" and paused or {}

  local options = noctalia.state.get("renderOptions")
  snapRenderOptions = type(options) == "table" and options or {}

  mpvpaperAvailable = noctalia.state.get("available") ~= false
end

local function assignmentFor(connector)
  return snapAssignments[connector]
end

-- The path currently assigned to whatever the output selector is pointing at.
local function activeAssignment()
  if selectedConnectorName == "" then
    local wildcard = assignmentFor("*")
    if wildcard then return wildcard end
    for _, output in ipairs(outputsList) do
      local path = assignmentFor(output.name)
      if path then return path end
    end
    return nil
  end
  return assignmentFor(selectedConnectorName) or assignmentFor("*")
end

local function isPausedForSelection()
  if selectedConnectorName == "" then
    for _, value in pairs(snapPaused) do
      if value == true then return true end
    end
    return false
  end
  return snapPaused[selectedConnectorName] == true or snapPaused["*"] == true
end

-- True when the selected individual connector has no per-connector assignment
-- but inherits one from the wildcard ("*"). Pause/stop then has to go through
-- "All Outputs" instead.
local function isWildcardOnly()
  if selectedConnectorName == "" then return false end
  return assignmentFor(selectedConnectorName) == nil and assignmentFor("*") ~= nil
end

local function sendCommand(action, connector, path)
  cmdNonce += 1
  noctalia.state.set("command", { action = action, connector = connector, path = path, nonce = cmdNonce })
end

-- ── Render options ─────────────────────────────────────────────────────────
--
-- Framing and scaler quality live next to the grid because they are things you
-- judge by looking at the wallpaper, not things you set once in a settings window.
-- The service owns the values (a plugin cannot write its own settings), so these
-- read from the state it publishes and change through the same command channel.
-- Keep the value order in step with RENDER_OPTIONS in mediapaper_service.luau.
local RENDER_OPTION_VALUES = {
  fit_mode = { "fill", "fit", "stretch" },
  render_quality = { "default", "high" },
}

local function renderOptionValue(key)
  if type(snapRenderOptions[key]) == "string" then
    return snapRenderOptions[key]
  end
  return RENDER_OPTION_VALUES[key][1]
end

local function renderOptionIndex(key)
  local current = renderOptionValue(key)
  for i, value in ipairs(RENDER_OPTION_VALUES[key]) do
    if value == current then return i - 1 end
  end
  return 0
end

local function renderOptionLabels(key)
  local labels = {}
  for _, value in ipairs(RENDER_OPTION_VALUES[key]) do
    table.insert(labels, tr("settings." .. key .. "." .. value))
  end
  return labels
end

local function applyRenderOption(key, index)
  local optionIndex = tonumber(index)
  if optionIndex == nil then
    noctalia.log("mediapaper: invalid " .. key .. " index: " .. tostring(index))
    return
  end
  local value = RENDER_OPTION_VALUES[key][optionIndex + 1]
  if value == nil then
    noctalia.log("mediapaper: " .. key .. " index out of range: " .. tostring(index))
    return
  end
  cmdNonce += 1
  noctalia.state.set("command", { action = "set-option", key = key, value = value, nonce = cmdNonce })
  -- The dropdown has already moved itself. Redrawing from the published state puts it
  -- back if the service refuses the value; if it accepts, the renderOptions watcher
  -- redraws again with the new one.
  render()
end

-- The commands below all take effect by changing what the service publishes, and the
-- watchers at the bottom of this file redraw when it does. Rendering here as well
-- would only rebuild the tree from state that has not moved yet.

local function applyMedia(path)
  local target = selectedConnectorName == "" and "*" or selectedConnectorName
  sendCommand("set", target, path)
end

local function stopSelected()
  if selectedConnectorName == "" then
    sendCommand("clear-all", nil, nil)
  else
    sendCommand("clear", selectedConnectorName, nil)
  end
end

local function toggleSelected()
  refreshState()
  local action = isPausedForSelection() and "thaw" or "freeze"
  sendCommand(action, selectedConnectorName, nil)
end

-- ── Thumbnails ─────────────────────────────────────────────────────────────
--
-- Every tile is fed a downscaled JPEG from the cache, images included: handing the
-- grid a source file means the host decodes it whole, and a wall of 4K sources costs
-- hundreds of megabytes of RGBA to paint tiles the size of a business card. mpv does
-- the extraction because mpvpaper already depends on it and it reads both stills and
-- video containers.

local function cachePath(path)
  return CACHE_DIR .. "/" .. path:gsub("[^%w]", "_") .. THUMB_SUFFIX
end

-- A fresh page finishes its thumbnails in a burst, and rendering on each one would
-- rebuild the whole grid up to PAGE_SIZE times in a row. The first completion schedules
-- a render through the event loop (a trivial runAsync is the only way back to it) and
-- every completion until that render lands rides along with it.
local thumbRenderPending = false

local function scheduleRender()
  if thumbRenderPending then return end
  thumbRenderPending = true
  noctalia.runAsync("true", function()
    thumbRenderPending = false
    render()
  end)
end

local function pumpThumbQueue()
  while thumbActive < THUMB_MAX_CONCURRENT and #thumbQueue > 0 do
    local path = table.remove(thumbQueue, 1)
    if thumbPaths[path] == nil and not thumbPending[path] then
      thumbPending[path] = true
      thumbActive += 1
      local dest = cachePath(path)
      local tmpdir = dest .. ".d"
      -- force_original_aspect_ratio=decrease bounds the frame by the long edge whichever
      -- way round it is; force_divisible_by keeps the odd dimension the JPEG encoder
      -- rejects from ever appearing. Written with `=` parameter names because mpv splits
      -- filter arguments on the same colons libavfilter does.
      local scale = "scale=w=" .. THUMB_LONG_EDGE .. ":h=" .. THUMB_LONG_EDGE ..
        ":force_original_aspect_ratio=decrease:force_divisible_by=2"
      -- mpv's image VO writes 00000001.jpg into an output dir (the encode path -o
      -- file.jpg is not available on every mpv build); move it to the cache name.
      local cmd = "mkdir -p " .. shellQuote(tmpdir) ..
        " && mpv " .. shellQuote(path) ..
        " --no-config --no-terminal --really-quiet --frames=1 --start=10% --no-audio" ..
        " --vf=" .. shellQuote(scale) ..
        " --vo=image --vo-image-format=jpg --vo-image-outdir=" .. shellQuote(tmpdir) ..
        " && mv " .. shellQuote(tmpdir .. "/00000001.jpg") .. " " .. shellQuote(dest) ..
        "; rm -rf " .. shellQuote(tmpdir)
      noctalia.runAsync(cmd, function(result)
        thumbActive -= 1
        thumbPending[path] = nil
        if result and noctalia.fileExists(dest) then
          thumbPaths[path] = dest
          scheduleRender()
        end
        pumpThumbQueue()
      end, 20000)
    end
  end
end

local function queueThumb(item)
  if thumbPaths[item.path] ~= nil or thumbPending[item.path] then
    return
  end
  local cached = cachePath(item.path)
  if noctalia.fileExists(cached) then
    thumbPaths[item.path] = cached
    return
  end
  table.insert(thumbQueue, item.path)
end

-- Thumbnails cached under an earlier name were full-resolution copies and nothing
-- reads them any more. Confined to this plugin's own cache directory, and the two
-- names the plugin does still use are spared.
local function sweepLegacyThumbs()
  noctalia.runAsync("find " .. shellQuote(CACHE_DIR) ..
    " -maxdepth 1 -type f -name '*.jpg'" ..
    " ! -name " .. shellQuote("*" .. THUMB_SUFFIX) ..
    " ! -name '*_still.jpg' ! -name '*_static.jpg' -delete")
end

-- ── Scanning ───────────────────────────────────────────────────────────────

local function isDirectory(path)
  local info = noctalia.fileInfo(path)
  return type(info) == "table" and info.isDir == true
end

-- Walks `dir`, appending media files to `out` and descending into subdirectories
-- until `depth` runs out.
local function scanInto(dir, root, depth, out, seen)
  local entries = noctalia.listDir(dir)
  if type(entries) ~= "table" then return false end
  table.sort(entries)

  local subdirs = {}
  for _, name in ipairs(entries) do
    if name:sub(1, 1) ~= "." then
      local full = dir .. "/" .. name
      local kind = kindOf(name)
      if kind ~= nil then
        if not seen[full] then
          if #out >= MAX_ITEMS then
            truncated = true
            return true
          end
          seen[full] = true
          if kind == "video" then videoCount += 1 else imageCount += 1 end
          table.insert(out, {
            path = full,
            label = full:sub(#root + 2),
            kind = kind,
          })
        end
      elseif depth > 0 and isDirectory(full) then
        table.insert(subdirs, full)
      end
    end
  end

  for _, sub in ipairs(subdirs) do
    scanInto(sub, root, depth - 1, out, seen)
    if truncated then return true end
  end
  return true
end

local function applyFilter()
  if filterKind == "" then
    media = allMedia
  else
    media = {}
    for _, item in ipairs(allMedia) do
      if item.kind == filterKind then
        table.insert(media, item)
      end
    end
  end
  page = 1
end

local function loadMedia()
  allMedia = {}
  imageCount = 0
  videoCount = 0
  errorMessage = ""
  truncated = false

  local seen = {}
  local depth = maxDepth()
  local readable = 0
  for _, root in ipairs(sourceRoots()) do
    if scanInto(root, root, depth, allMedia, seen) then
      readable += 1
    end
  end

  if readable == 0 then
    errorMessage = tr("unreadable")
  elseif #allMedia == 0 then
    errorMessage = tr("empty")
  end

  table.sort(allMedia, function(a, b)
    return a.label:lower() < b.label:lower()
  end)
  applyFilter()
end

-- ── Rendering ──────────────────────────────────────────────────────────────

local function totalPages()
  return math.max(1, math.ceil(#media / PAGE_SIZE))
end

local function pageBounds()
  local first = (page - 1) * PAGE_SIZE + 1
  local last = math.min(first + PAGE_SIZE - 1, #media)
  return first, last
end

local function refreshOutputs()
  outputsList = noctalia.outputs() or {}
  if selectedConnectorName ~= "" then
    for _, output in ipairs(outputsList) do
      if output.name == selectedConnectorName then
        return
      end
    end
    noctalia.log("mediapaper: selected output is no longer available: " .. selectedConnectorName)
    selectedConnectorName = ""
  end
end

local function outputOptions()
  local options = { tr("all_outputs") }
  for _, output in ipairs(outputsList) do
    table.insert(options, output.name)
  end
  return options
end

local function selectedOutputIndex()
  if selectedConnectorName == "" then
    return 0
  end
  for i, output in ipairs(outputsList) do
    if output.name == selectedConnectorName then
      return i
    end
  end
  return 0
end

local function columnWidth()
  return math.floor(((PANEL_WIDTH - PANEL_PADDING) - COLUMN_GAP * (COLUMNS - 1)) / COLUMNS)
end

local function tileSize()
  local width = columnWidth()
  return width, math.floor(width * 9 / 16)
end

local function isAssignedToSelection(path)
  -- A wildcard assignment covers every output, so it stays highlighted whichever
  -- output the selector is pointing at.
  if assignmentFor("*") == path then
    return true
  end

  if selectedConnectorName == "" then
    for _, output in ipairs(outputsList) do
      if assignmentFor(output.name) == path then
        return true
      end
    end
    return false
  end
  return assignmentFor(selectedConnectorName) == path
end

local function mediaTile(item)
  local frameWidth, frameHeight = tileSize()
  local path = item.path
  local selected = isAssignedToSelection(path)
  local thumb = thumbPaths[path]
  local onClick = function()
    applyMedia(path)
  end

  local preview
  if thumb ~= nil then
    preview = ui.image({
      width = frameWidth,
      height = frameHeight,
      path = thumb,
      fit = "cover",
      radius = TILE_RADIUS,
      border = selected and "primary" or "outline",
      borderWidth = selected and 3 or 1,
      onClick = onClick,
    })
  else
    preview = ui.box({
      width = frameWidth,
      height = frameHeight,
      fill = "surface_variant",
      radius = TILE_RADIUS,
      border = selected and "primary" or "outline",
      borderWidth = selected and 3 or 1,
      onClick = onClick,
    })
  end

  local accent = selected and "primary" or "on_surface_variant"

  return ui.column({ gap = 4, key = path, flexGrow = 1, align = "center" }, {
    preview,
    ui.row({ gap = 4, align = "center", justify = "center", maxWidth = frameWidth }, {
      ui.glyph({
        name = item.kind == "video" and "player-play" or "photo",
        size = 12,
        color = accent,
      }),
      ui.label({
        text = item.label,
        fontSize = 11,
        color = accent,
        maxLines = 1,
        maxWidth = frameWidth - 20,
        textAlign = "center",
      }),
    }),
  })
end

local function mediaGrid()
  if #media == 0 then
    return ui.label({
      text = errorMessage ~= "" and errorMessage or tr("empty_filter"),
      color = errorMessage ~= "" and "error" or "on_surface_variant",
    })
  end

  local first, last = pageBounds()
  local rows = {}
  local row = {}
  for i = first, last do
    table.insert(row, mediaTile(media[i]))
    if #row == COLUMNS or i == last then
      -- Tiles share the row width evenly, so a short final row would blow each
      -- of its tiles up. Pad it out to keep every tile the same size.
      for _ = #row + 1, COLUMNS do
        table.insert(row, ui.column({ flexGrow = 1 }, {}))
      end
      table.insert(rows, ui.row({ gap = COLUMN_GAP, align = "stretch" }, row))
      row = {}
    end
  end
  return ui.column({ gap = 12, align = "stretch" }, rows)
end

-- Only the visible page is worth extracting frames for; a recursive scan can
-- easily turn up more videos than anyone will scroll past.
local function queueVisibleThumbs()
  if #media == 0 then return end
  local first, last = pageBounds()
  for i = first, last do
    queueThumb(media[i])
  end
  pumpThumbQueue()
end

local function filterChip(labelKey, kind)
  return ui.button({
    key = "filter_" .. (kind == "" and "all" or kind),
    text = tr(labelKey),
    variant = filterKind == kind and "primary" or "outline",
    onClick = kind == "" and "onFilterAll" or (kind == "image" and "onFilterImages" or "onFilterVideos"),
  })
end

local function countsText()
  if truncated then
    return tr("truncated", { count = MAX_ITEMS })
  end
  return tr("counts", { images = imageCount, videos = videoCount })
end

render = function()
  refreshState()
  refreshOutputs()
  queueVisibleThumbs()

  local paused = isPausedForSelection()
  local active = activeAssignment()
  local activeIsVideo = active ~= nil and kindOf(active) == "video"
  local wildcardOnly = isWildcardOnly()

  -- Pause only means something while a video is playing; Stop also releases an
  -- image assignment, which is just the highlight in this grid.
  local pauseEnabled = activeIsVideo and not wildcardOnly
  local stopEnabled = active ~= nil and not wildcardOnly

  -- Lock the output selector while a wildcard assignment owns every output.
  local selectEnabled = assignmentFor("*") == nil

  local header = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("rescan"), onClick = "onRescan" }),
      ui.button({ glyph = "close", onClick = "onClose" }),
    }),

    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("output"), fontSize = 12, color = "on_surface_variant" }),
      ui.select({
        key = "output",
        options = outputOptions(),
        selectedIndex = selectedOutputIndex(),
        onChange = "onOutputChange",
        flexGrow = 1,
        enabled = selectEnabled,
      }),
      ui.button({
        text = paused and tr("resume") or tr("pause"),
        glyph = paused and "player-play" or "player-pause",
        variant = "outline",
        onClick = "onToggle",
        enabled = pauseEnabled,
      }),
      ui.button({ text = tr("stop"), glyph = "player-stop", variant = "outline", onClick = "onStop", enabled = stopEnabled }),
    }),

    ui.row({ gap = 8, align = "center" }, {
      filterChip("filter_all", ""),
      filterChip("filter_images", "image"),
      filterChip("filter_videos", "video"),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = countsText(), fontSize = 11, color = "on_surface_variant" }),
    }),

    -- These only affect video, but they stay live with nothing playing so the choice
    -- can be made ahead of the pick; without mpvpaper there is no video at all.
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("settings.fit_mode.label"), fontSize = 12, color = "on_surface_variant" }),
      ui.select({
        key = "fit_mode",
        options = renderOptionLabels("fit_mode"),
        selectedIndex = renderOptionIndex("fit_mode"),
        onChange = "onFitModeChange",
        flexGrow = 1,
        enabled = mpvpaperAvailable,
      }),
      ui.label({ text = tr("settings.render_quality.label"), fontSize = 12, color = "on_surface_variant" }),
      ui.select({
        key = "render_quality",
        options = renderOptionLabels("render_quality"),
        selectedIndex = renderOptionIndex("render_quality"),
        onChange = "onRenderQualityChange",
        flexGrow = 1,
        enabled = mpvpaperAvailable,
      }),
    }),
  }

  if not mpvpaperAvailable then
    table.insert(header, ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "movie-off", size = 14, color = "error" }),
      ui.label({ text = tr("not_installed_hint"), fontSize = 11, color = "error" }),
    }))
  end

  table.insert(header, ui.scroll({ flexGrow = 1, gap = 12 }, { mediaGrid() }))
  table.insert(header, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.button({ key = "prev_page", glyph = "chevron-left", variant = "ghost", onClick = "onPrevPage", enabled = page > 1 }),
    ui.label({ text = `{page} / {totalPages()}`, color = "on_surface_variant" }),
    ui.button({ key = "next_page", glyph = "chevron-right", variant = "ghost", onClick = "onNextPage", enabled = page < totalPages() }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, header))
end

-- ── Callbacks ──────────────────────────────────────────────────────────────

function onOpen(_context)
  refreshOutputs()
  if #allMedia == 0 then
    loadMedia()
    render()
    return
  end
  -- The walk is synchronous, so an already-scanned library is drawn first and the
  -- refresh runs from a runAsync callback, which is the only way back to the event
  -- loop once a frame is out. Files added since the last open show up a beat later.
  render()
  noctalia.runAsync("true", function()
    loadMedia()
    render()
  end)
end

function onRescan()
  loadMedia()
  render()
end

function onFilterAll()
  filterKind = ""
  applyFilter()
  render()
end

function onFilterImages()
  filterKind = "image"
  applyFilter()
  render()
end

function onFilterVideos()
  filterKind = "video"
  applyFilter()
  render()
end

function onOutputChange(index, label)
  local optionIndex = tonumber(index)
  if optionIndex == nil then
    noctalia.log("mediapaper: invalid output selection index: " .. tostring(index))
    return
  end
  if optionIndex == 0 then
    selectedConnectorName = ""
  elseif type(label) == "string" and label ~= "" then
    selectedConnectorName = label
  else
    noctalia.log("mediapaper: invalid output selection label: " .. tostring(label))
    return
  end
  render()
end

function onFitModeChange(index, _label)
  applyRenderOption("fit_mode", index)
end

function onRenderQualityChange(index, _label)
  applyRenderOption("render_quality", index)
end

function onStop()
  stopSelected()
end

function onToggle()
  toggleSelected()
end

function onPrevPage()
  if page > 1 then
    page -= 1
    render()
  end
end

function onNextPage()
  if page < totalPages() then
    page += 1
    render()
  end
end

function onClose()
  panel.close()
end

noctalia.runAsync("mkdir -p " .. shellQuote(CACHE_DIR), function()
  sweepLegacyThumbs()
end)

-- Re-render when the service publishes new assignments (tile highlights).
noctalia.state.watch("assignments", function(_)
  render()
end)

-- Re-render when the paused state changes (button label).
noctalia.state.watch("paused", function(_)
  render()
end)

-- Re-render when the service confirms a render option change (dropdown selection).
noctalia.state.watch("renderOptions", function(_)
  render()
end)
