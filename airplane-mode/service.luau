--!nonstrict
-- Airplane Mode: headless owner of the rfkill state.
--
-- One `rfkill -J` poll per tick decides "on": every soft-blockable radio is
-- blocked. Hard-blocked devices (a physical kill switch) are excluded from the
-- count entirely, because software can neither block nor unblock them; a
-- machine with only a hard-blocked radio reports off rather than on.
--
-- Commands arrive over the shared "airplane_command" state key (the shortcut
-- runs in another Luau runtime, so state is its only way in) and run
-- `rfkill block all` or `rfkill unblock all`, re-polling on completion so the
-- tile catches up in one round trip rather than at the next interval.

local POLL_MS = 2000

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local available = noctalia.commandExists("rfkill")
local on = false
local busy = false
local pollBusy = false

local lastPublished = nil

local function publish()
  local key = `{tostring(on)}\1{tostring(busy)}\1{tostring(available)}`
  if key == lastPublished then return end
  lastPublished = key
  noctalia.state.set("airplane_status", { on = on, busy = busy, available = available })
end

local function poll()
  if not available or pollBusy then return end
  pollBusy = true
  local accepted = noctalia.runAsync("rfkill -J", function(result)
    pollBusy = false
    if type(result) ~= "table" or result.exitCode ~= 0 then
      publish()
      return
    end
    local payload = noctalia.json.decode(noctalia.string.trim(result.stdout or ""))
    if type(payload) ~= "table" then return end
    -- util-linux names the array "rfkilldevices"; older builds used "".
    local devices = payload.rfkilldevices or payload[""]
    if type(devices) ~= "table" then return end
    local considered = 0
    local blocked = 0
    for _, device in ipairs(devices) do
      if device.hard ~= "blocked" then
        considered += 1
        if device.soft == "blocked" then blocked += 1 end
      end
    end
    on = considered > 0 and blocked == considered
    publish()
  end, 5000)
  if not accepted then
    pollBusy = false
  end
end

local function handleCommand(command)
  if type(command) ~= "table" or command.action ~= "toggle" then return end
  if busy or not available then return end
  busy = true
  publish()
  local verb = on and "unblock" or "block"
  noctalia.runAsync(`rfkill {verb} all`, function(result)
    busy = false
    if type(result) ~= "table" or result.exitCode ~= 0 then
      local detail = type(result) == "table" and noctalia.string.trim(result.stderr or "") or ""
      if detail == "" then detail = tr("error.command_failed") end
      noctalia.log(`airplane-mode: rfkill {verb} all: {detail}`)
      noctalia.notifyError(tr("title"), detail)
    end
    poll()
  end, 10000)
end

noctalia.state.watch("airplane_command", handleCommand)

-- The same toggle over shell IPC, for keybinds:
--   noctalia msg plugin tommyothen/airplane-mode:svc all toggle
function onIpc(event, _payload)
  if event == "toggle" then
    handleCommand({ action = "toggle" })
  end
end

function update()
  poll()
end

noctalia.setUpdateInterval(POLL_MS)
publish()
poll()
