--!nonstrict
-- Bar presence for the agent fleet.
--
-- A pure subscriber: the service owns every read, this only reflects what landed
-- in noctalia.state. It both watches and polls, because a state.watch callback is
-- not reliably delivered to a bar widget — the widget already has an update()
-- tick, so the poll costs nothing.
--
-- The colour is the whole point of the widget. `error` means t3 is waiting on you
-- (a pending approval), which is the one state worth interrupting for; `primary`
-- means work is in flight; anything else stays quiet.

-- The service already throttles the data; this only has to be often enough that
-- the bar does not lag behind a state change the watch failed to deliver.
local POLL_MS = 1000

local glyph = noctalia.getConfig("glyph")
if type(glyph) ~= "string" or glyph == "" then glyph = "robot" end

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- State crosses a serialisation boundary on its way here, so nothing is assumed
-- to have survived as the string the service published.
local function text(value, fallback)
  if type(value) == "string" and value ~= "" then return value end
  return fallback
end

local function compact(n)
  n = tonumber(n) or 0
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 10000 then return string.format("%.0fk", n / 1000) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

-- t3 can grow a status this plugin has never heard of; show the raw token rather
-- than a missing translation key.
local KNOWN_STATUS = {
  idle = true, starting = true, running = true, ready = true,
  interrupted = true, stopped = true, error = true,
}

local function statusLabel(status)
  if type(status) ~= "string" or status == "" then return tr("status.idle") end
  if KNOWN_STATUS[status] then return tr("status." .. status) end
  return status
end

local function snapshot()
  local snap = noctalia.state.get("snapshot")
  if type(snap) ~= "table" then return nil end
  return snap
end

-- Exactly the fields drawn below, as one string. Both the poll and the watch land
-- here, and the bar is a glyph, a count and a tooltip: redrawing it because the
-- service republished the same fleet is a widget tree the host has to rebuild for
-- nothing.
local function fingerprint(snap)
  if snap == nil or snap.t3Running ~= true then return "down" end
  local threads = type(snap.threads) == "table" and snap.threads or {}
  local agents = type(snap.agents) == "table" and snap.agents or {}
  local parts = {}
  for _, thread in ipairs(threads) do
    table.insert(parts, table.concat({
      tostring(thread.project), tostring(thread.title), tostring(thread.status),
      tostring(thread.approvals), tostring(thread.inputs),
    }, "\2"))
  end
  for _, agent in ipairs(agents) do
    table.insert(parts, table.concat({ tostring(agent.title), tostring(agent.tokens) }, "\2"))
  end
  return table.concat(parts, "\3")
end

local lastFingerprint = nil

local function render()
  barWidget.setGlyph(glyph)

  local snap = snapshot()
  if snap == nil or snap.t3Running ~= true then
    barWidget.setText("")
    barWidget.setColor("on_surface_variant")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip(tr("widget.t3_down"))
    return
  end

  local threads = type(snap.threads) == "table" and snap.threads or {}
  local agents = type(snap.agents) == "table" and snap.agents or {}

  local approvals, running = 0, 0
  for _, thread in ipairs(threads) do
    approvals += (tonumber(thread.approvals) or 0) + (tonumber(thread.inputs) or 0)
    if thread.status == "running" or thread.status == "starting" then running += 1 end
  end

  local role = "on_surface_variant"
  if approvals > 0 then
    role = "error"
  elseif running > 0 or #agents > 0 then
    role = "primary"
  end

  barWidget.setText(#agents > 0 and tostring(#agents) or "")
  barWidget.setColor(role)
  barWidget.setGlyphColor(role)

  local rows = {}
  if approvals > 0 then
    table.insert(rows, { key = tr("widget.attention"), value = tostring(approvals) })
  end
  for _, thread in ipairs(threads) do
    local label = text(thread.project, tr("widget.untitled"))
    local title = text(thread.title, "")
    if title ~= "" then label = label .. " · " .. title end
    table.insert(rows, { key = label, value = statusLabel(thread.status) })
  end
  for _, agent in ipairs(agents) do
    table.insert(rows, {
      key = text(agent.title, tr("widget.untitled_agent")),
      value = compact(agent.tokens),
    })
  end
  if #rows == 0 then
    table.insert(rows, { key = tr("widget.idle"), value = "" })
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
  if not noctalia.runAsync("noctalia msg panel-open 'tommyothen/t3agents:dashboard'") then
    noctalia.notifyError(tr("title"), tr("widget.panel_failed"))
  end
end

noctalia.state.watch("snapshot", function(_)
  renderIfChanged()
end)

noctalia.setUpdateInterval(POLL_MS)
lastFingerprint = fingerprint(snapshot())
render()
