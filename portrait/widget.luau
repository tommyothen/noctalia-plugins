--!nonstrict
-- Portrait. Bar widget.
--
-- A subscriber and nothing else: it seeds from the service's published status,
-- watches for changes, and sends toggles back through the shared command key.
-- It runs no commands of its own, so a widget on every bar is still exactly one
-- state machine.

local GLYPH = "rotate-clockwise"
local GLYPH_BUSY = "loader-2"

local status = noctalia.state.get("portrait_status") or {
  transform = "normal",
  output = "",
  busy = false,
  available = true,
}
local nonce = 0

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- "90" -> "90°"; flipped and friends fall through verbatim, which is still an
-- honest answer for a state this plugin never sets itself.
local function describeTransform(value)
  if tonumber(value) then return `{value}°` end
  return tostring(value)
end

local function render()
  if status.available == false then
    barWidget.setGlyph(GLYPH)
    barWidget.setGlyphColor("error")
    barWidget.setTooltip(tr("tooltip.unavailable"))
  elseif status.busy == true then
    barWidget.setGlyph(GLYPH_BUSY)
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip(tr("tooltip.changing"))
  elseif status.transform ~= "normal" then
    barWidget.setGlyph(GLYPH)
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip({
      { key = tr("tooltip.output"), value = tostring(status.output) },
      { key = tr("tooltip.rotation"), value = describeTransform(status.transform) },
    })
  else
    barWidget.setGlyph(GLYPH)
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip(tr("tooltip.off"))
  end
end

local function send(action)
  nonce += 1
  noctalia.state.set("portrait_command", { action = action, nonce = `widget-{nonce}` })
end

noctalia.state.watch("portrait_status", function(value)
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

-- An escape hatch for the few seconds between a terminal-made rotation and the
-- next poll catching it.
function onRightClick()
  send("refresh")
end

render()
