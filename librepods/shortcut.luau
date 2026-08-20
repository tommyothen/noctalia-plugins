--!nonstrict
-- LibrePods: control-center tile.
--
-- A pure subscriber over the service's "snapshot": lit while AirPods are
-- connected, with the worst bud battery as the label. Clicking opens the
-- LibrePods panel (battery detail, noise control, conversation awareness);
-- the control center has no plugin tabs, so the tile is the entry point.

local snap = nil

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function connected()
  return type(snap) == "table" and snap.daemonRunning == true and snap.connected == true
end

-- Lowest battery among connected bud or headphone components; the case only
-- matters once a bud is in it.
local function worstBattery()
  if type(snap) ~= "table" or type(snap.battery) ~= "table" then return nil end
  local worst = nil
  for _, entry in ipairs(snap.battery) do
    if entry.connected and entry.component ~= "case" then
      if worst == nil or entry.level < worst then worst = entry.level end
    end
  end
  return worst
end

local function render()
  local isConnected = connected()
  local label = tr("title")
  if isConnected then
    local worst = worstBattery()
    if worst ~= nil then label = `{worst}%` end
  end
  shortcut.setLabel(label)
  shortcut.setIcon("device-airpods", "device-airpods")
  shortcut.setActive(isConnected)
  -- Enabled even while disconnected: the panel explains daemon-down versus
  -- no-AirPods better than a dead tile would.
  shortcut.setEnabled(true)
end

noctalia.state.watch("snapshot", function(value)
  if type(value) == "table" then
    snap = value
    render()
  end
end)

function onClick()
  if not noctalia.runAsync("noctalia msg panel-open 'tommyothen/librepods:status'") then
    noctalia.notifyError(tr("title"), tr("widget.panel_failed"))
  end
end

snap = noctalia.state.get("snapshot")
render()
