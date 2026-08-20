--!nonstrict
-- LibrePods: bar widget.
--
-- A pure subscriber: the service owns the state file, this only reflects what
-- landed in noctalia.state. It both watches and polls, because a state.watch
-- callback is not reliably delivered to a bar widget; the widget already has an
-- update() tick, so the poll costs nothing.
--
-- The text is the lowest battery among the connected bud or headphone
-- components, because that number is when the music stops; the case only rounds
-- out the tooltip. Colour carries the rest: primary while anything charges,
-- error once the worst bud runs low, muted when nothing is connected.

-- The service already throttles the data; this only has to be often enough that
-- the bar does not lag behind a state change the watch failed to deliver.
local POLL_MS = 1000

-- Below this the worst bud turns the tile red. Matches the point where AirPods
-- start announcing low battery themselves.
local LOW_PCT = 20

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function glyphName()
  local glyph = noctalia.getConfig("glyph")
  if type(glyph) ~= "string" or glyph == "" then glyph = "device-airpods" end
  return glyph
end

local function snapshot()
  local snap = noctalia.state.get("snapshot")
  if type(snap) ~= "table" then return nil end
  return snap
end

local function battery(snap)
  if snap == nil or type(snap.battery) ~= "table" then return {} end
  return snap.battery
end

-- The daemon can grow a component or mode this plugin has never heard of; show
-- the raw token rather than a missing translation key.
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

-- The lowest level among connected non-case components, and whether anything at
-- all is charging (the case included: a tile that goes primary on the charger is
-- the confirmation the lid click was for).
local function summary(snap)
  local worst = nil
  local charging = false
  for _, entry in ipairs(battery(snap)) do
    if entry.connected then
      if entry.charging then charging = true end
      if entry.component ~= "case" and (worst == nil or entry.level < worst) then
        worst = entry.level
      end
    end
  end
  return worst, charging
end

-- Exactly the fields drawn below, plus the two widget settings, so a settings
-- change re-renders on the next tick without its own callback.
local function fingerprint(snap)
  local parts = { glyphName(), tostring(noctalia.getConfig("hide_when_disconnected")) }
  if snap == nil or snap.daemonRunning ~= true then
    table.insert(parts, "down")
  else
    table.insert(parts, tostring(snap.connected))
    table.insert(parts, tostring(snap.name))
    table.insert(parts, tostring(snap.mode))
    for _, entry in ipairs(battery(snap)) do
      table.insert(parts, table.concat({
        tostring(entry.component), tostring(entry.level),
        tostring(entry.charging), tostring(entry.connected),
      }, "\2"))
    end
  end
  return table.concat(parts, "\1")
end

local lastFingerprint = nil

local function render()
  local snap = snapshot()
  local connected = snap ~= nil and snap.daemonRunning == true and snap.connected == true

  if not connected then
    if noctalia.getConfig("hide_when_disconnected") == true then
      barWidget.setVisible(false)
      return
    end
    barWidget.setVisible(true)
    barWidget.setGlyph(glyphName())
    barWidget.setText("")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setColor("on_surface_variant")
    local down = snap == nil or snap.daemonRunning ~= true
    barWidget.setTooltip(down and tr("widget.daemon_down") or tr("widget.disconnected"))
    return
  end

  local worst, charging = summary(snap)

  local role = "on_surface"
  if charging then
    role = "primary"
  elseif worst ~= nil and worst <= LOW_PCT then
    role = "error"
  end

  barWidget.setVisible(true)
  barWidget.setGlyph(glyphName())
  barWidget.setText(worst ~= nil and `{worst}%` or "")
  barWidget.setGlyphColor(role)
  barWidget.setColor(role)

  local rows = {
    { key = type(snap.name) == "string" and snap.name ~= "" and snap.name or tr("title"),
      value = tr("widget.connected") },
  }
  for _, entry in ipairs(battery(snap)) do
    if entry.connected then
      local value = `{entry.level}%`
      if entry.charging then value ..= " " .. tr("widget.charging") end
      table.insert(rows, { key = componentLabel(entry.component), value = value })
    end
  end
  if type(snap.mode) == "string" and snap.mode ~= "" then
    table.insert(rows, { key = tr("widget.mode"), value = modeLabel(snap.mode) })
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

function update()
  renderIfChanged()
end

-- panel-open rather than togglePanel: open is idempotent, so it survives the
-- click handler firing more than once for a single click (a toggle nets back to
-- closed and the widget reads as dead). Dismiss is click-outside or Esc.
function onClick()
  if not noctalia.runAsync("noctalia msg panel-open 'tommyothen/librepods:status'") then
    noctalia.notifyError(tr("title"), tr("widget.panel_failed"))
  end
end

noctalia.state.watch("snapshot", function(_)
  renderIfChanged()
end)

noctalia.setUpdateInterval(POLL_MS)
lastFingerprint = fingerprint(snapshot())
render()
