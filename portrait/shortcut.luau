--!nonstrict
-- Portrait. Control-center tile.
--
-- The same toggle as the bar widget, over the same command key, so whichever
-- one you reach for the service sees an identical request.

local status = noctalia.state.get("portrait_status") or {
  transform = "normal",
  busy = false,
  available = true,
}
local nonce = 0

local function tr(key)
  return noctalia.tr(key)
end

local function render()
  local rotated = status.transform ~= nil and status.transform ~= "normal"
  shortcut.setLabel(if rotated then tr("shortcut.on") else tr("shortcut.off"))
  shortcut.setIcon("rotate-clockwise", "rotate")
  shortcut.setActive(rotated)
  shortcut.setEnabled(status.available ~= false and status.busy ~= true)
end

noctalia.state.watch("portrait_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

function onClick()
  if status.available == false or status.busy == true then return end
  nonce += 1
  noctalia.state.set("portrait_command", { action = "toggle", nonce = `shortcut-{nonce}` })
end

render()
