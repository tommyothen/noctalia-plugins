--!nonstrict
-- LibrePods: enhanced volume tile.
--
-- The built-in volume widget's face with AirPods awareness: while the librepods
-- daemon reports a connected device the tile wears the AirPods glyph and the
-- tooltip carries battery and noise mode; otherwise it is a plain volume icon.
-- Scroll and right click are declared as widget action defaults in plugin.toml
-- (volume-up / volume-down / volume-mute), so stepping and the OSD are the
-- shell's own, identical to the built-in widget; only the face changes here.
-- Click routes by state: the AirPods panel while connected, the control
-- center's audio section otherwise.
--
-- Volume itself has no Luau API, so one `wpctl get-volume` poll per tick reads
-- the default sink ("Volume: 0.45 [MUTED]"). A static command line, nothing
-- user-supplied on it.

local POLL_MS = 1000

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local volumePercent = nil
local muted = false
local pollBusy = false

local KNOWN_COMPONENTS = { left = true, right = true, case = true, headphone = true }
local KNOWN_MODES = { off = true, noise_cancellation = true, transparency = true, adaptive = true }

local function componentLabel(component)
  if KNOWN_COMPONENTS[component] then return tr("component." .. component) end
  return component
end

local function modeLabel(mode)
  if KNOWN_MODES[mode] then return tr("mode." .. mode) end
  return mode
end

local function snapshot()
  local snap = noctalia.state.get("snapshot")
  if type(snap) ~= "table" then return nil end
  return snap
end

local function airpodsConnected(snap)
  return snap ~= nil and snap.daemonRunning == true and snap.connected == true
end

local function volumeGlyph()
  if muted then return "volume-off" end
  if volumePercent ~= nil and volumePercent < 50 then return "volume-2" end
  return "volume"
end

-- Everything drawn below, so identical polls never rebuild the tile.
local function fingerprint(snap)
  local parts = {
    tostring(volumePercent), tostring(muted),
    tostring(noctalia.getConfig("show_percent")),
  }
  if airpodsConnected(snap) then
    table.insert(parts, tostring(snap.name))
    table.insert(parts, tostring(snap.mode))
    for _, entry in ipairs(snap.battery) do
      if entry.connected then
        table.insert(parts, table.concat({
          tostring(entry.component), tostring(entry.level), tostring(entry.charging),
        }, "\2"))
      end
    end
  end
  return table.concat(parts, "\1")
end

local lastFingerprint = nil

local function render()
  local snap = snapshot()
  local connected = airpodsConnected(snap)

  barWidget.setGlyph(connected and "device-airpods" or volumeGlyph())
  local role = muted and "on_surface_variant" or "on_surface"
  barWidget.setGlyphColor(role)
  barWidget.setColor(role)

  if noctalia.getConfig("show_percent") == true and volumePercent ~= nil then
    barWidget.setText(`{volumePercent}%`)
  else
    barWidget.setText("")
  end

  local rows = {}
  local volumeValue = volumePercent ~= nil and `{volumePercent}%` or "?"
  if muted then volumeValue ..= " " .. tr("volume.muted") end
  table.insert(rows, { key = tr("volume.volume"), value = volumeValue })
  if connected then
    table.insert(rows, { key = type(snap.name) == "string" and snap.name ~= "" and snap.name or tr("title"),
      value = tr("widget.connected") })
    for _, entry in ipairs(snap.battery) do
      if entry.connected then
        local value = `{entry.level}%`
        if entry.charging then value ..= " " .. tr("widget.charging") end
        table.insert(rows, { key = componentLabel(entry.component), value = value })
      end
    end
    if type(snap.mode) == "string" and snap.mode ~= "" then
      table.insert(rows, { key = tr("widget.mode"), value = modeLabel(snap.mode) })
    end
  end
  barWidget.setTooltip(rows)
end

local function renderIfChanged()
  local fp = fingerprint(snapshot())
  if fp ~= lastFingerprint then
    lastFingerprint = fp
    render()
  end
end

local function poll()
  if pollBusy then return end
  pollBusy = true
  local accepted = noctalia.runAsync("wpctl get-volume @DEFAULT_AUDIO_SINK@", function(result)
    pollBusy = false
    if type(result) ~= "table" or result.exitCode ~= 0 then
      volumePercent = nil
      muted = false
      renderIfChanged()
      return
    end
    local out = noctalia.string.trim(result.stdout or "")
    local value = string.match(out, "Volume:%s*([%d%.]+)")
    volumePercent = value ~= nil and math.floor(tonumber(value) * 100 + 0.5) or nil
    muted = string.find(out, "%[MUTED%]") ~= nil
    renderIfChanged()
  end, 2000)
  if not accepted then
    pollBusy = false
  end
end

function update()
  poll()
  renderIfChanged()
end

-- Left click routes by state; scroll and right click are action bindings in
-- plugin.toml, so they never reach this script.
function onClick()
  local target = airpodsConnected(snapshot())
      and "noctalia msg panel-open 'tommyothen/librepods:status'"
    or "noctalia msg panel-toggle control-center audio"
  if not noctalia.runAsync(target) then
    noctalia.notifyError(tr("title"), tr("widget.panel_failed"))
  end
end

noctalia.state.watch("snapshot", function(_)
  renderIfChanged()
end)

noctalia.setUpdateInterval(POLL_MS)
poll()
render()
