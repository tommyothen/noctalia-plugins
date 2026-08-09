--!nonstrict
-- Away Mode — control-center tile.
--
-- The same toggle as the bar widget, over the same command key, so whichever one
-- you reach for the service sees an identical request.

local status = noctalia.state.get("away_status") or {
  on = false,
  busy = false,
  available = true,
}
local nonce = 0

local function tr(key)
  return noctalia.tr(key)
end

local function render()
  local isOn = status.on == true
  shortcut.setLabel(if isOn then tr("shortcut.on") else tr("shortcut.off"))
  shortcut.setIcon("door-exit", "door")
  shortcut.setActive(isOn)
  shortcut.setEnabled(status.available ~= false and status.busy ~= true)
end

noctalia.state.watch("away_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

function onClick()
  if status.available == false or status.busy == true then return end
  nonce += 1
  noctalia.state.set("away_command", { action = "toggle", nonce = `shortcut-{nonce}` })
end

render()
