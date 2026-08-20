--!nonstrict
-- Airplane Mode: control-center tile.
--
-- A pure subscriber over the service's "airplane_status"; the toggle goes back
-- through the shared command key, same shape as tommyothen/away-mode.

local status = noctalia.state.get("airplane_status") or {
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
  shortcut.setIcon("plane", "plane")
  shortcut.setActive(isOn)
  shortcut.setEnabled(status.available ~= false and status.busy ~= true)
end

noctalia.state.watch("airplane_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

function onClick()
  if status.available == false or status.busy == true then return end
  nonce += 1
  noctalia.state.set("airplane_command", { action = "toggle", nonce = `shortcut-{nonce}` })
end

render()
