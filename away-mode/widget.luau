--!nonstrict
-- Away Mode — bar widget.
--
-- A subscriber and nothing else: it seeds from the service's published status,
-- watches for changes, and sends toggles back through the shared command key.
-- It runs no commands of its own, so a widget on every bar is still exactly one
-- state machine.

local GLYPH_ON = "door-exit"
local GLYPH_OFF = "door-exit"
local GLYPH_BUSY = "loader-2"
local GLYPH_UNAVAILABLE = "door-off"

local status = noctalia.state.get("away_status") or {
  on = false,
  since = 0,
  busy = false,
  available = true,
}
local nonce = 0

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- The tooltip is where the "what is actually inhibited" answer lives, because
-- the interesting part of this mode is what it leaves alone, not what it blocks.
local function tooltipRows()
  local rows = {
    { key = tr("title"), value = tr("state.on") },
    { key = tr("tooltip.suspend"), value = tr("tooltip.blocked") },
    { key = tr("tooltip.lid"), value = tr("tooltip.blocked") },
    { key = tr("tooltip.lock"), value = tr("tooltip.allowed") },
    { key = tr("tooltip.screen_off"), value = tr("tooltip.allowed") },
  }

  local since = tonumber(status.since) or 0
  if since > 0 then
    table.insert(rows, { key = tr("tooltip.since"), value = noctalia.formatTime("%H:%M", since) })
  end

  return rows
end

local function render()
  if status.available == false then
    barWidget.setGlyph(GLYPH_UNAVAILABLE)
    barWidget.setGlyphColor("error")
    barWidget.setTooltip(tr("tooltip.unavailable"))
  elseif status.busy == true then
    barWidget.setGlyph(GLYPH_BUSY)
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip(tr("tooltip.changing"))
  elseif status.on == true then
    barWidget.setGlyph(GLYPH_ON)
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip(tooltipRows())
  else
    barWidget.setGlyph(GLYPH_OFF)
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip(tr("tooltip.off"))
  end
end

local function send(action)
  nonce += 1
  noctalia.state.set("away_command", { action = action, nonce = `widget-{nonce}` })
end

noctalia.state.watch("away_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

function onClick()
  if status.available == false then
    local detail = status.error
    if type(detail) ~= "string" or detail == "" then detail = tr("error.missing_dependencies") end
    noctalia.notifyError(tr("title"), detail)
    return
  end
  if status.busy == true then return end
  send("toggle")
end

-- An escape hatch for the one case the poll cannot see coming: the unit stopped
-- from a terminal, leaving the bar a few seconds stale.
function onRightClick()
  send("refresh")
end

render()
