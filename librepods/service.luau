--!nonstrict
-- LibrePods: headless collector and control channel.
--
-- The only entry that touches disk or spawns a process. Each update() tick reads
-- the daemon's state file with readFileAsync and publishes a normalized snapshot
-- to plugin state "snapshot"; the widget and panel are pure subscribers. The
-- file is rewritten atomically by the daemon on every device event, so a read
-- never sees a half-written document. A missing file means the daemon is not
-- running, which the snapshot reports separately from "daemon up, no AirPods".
--
-- Control goes the other way through the shared "command" state key (the widget
-- and panel are in other Luau runtimes, so state is their only way in, exactly
-- as away-mode does it). A command shells out to `librepods ctl …` and re-polls
-- the moment it returns, so a mode change lands in the UI in one round trip
-- rather than at the next interval.
--
-- API level 23 is the highest this host accepts (5.0.0_beta.8 supports 3-23),
-- so the subprocess goes through the string form of runAsync. The subcommand
-- half is whitelisted before it gets near a command line, and the binary path,
-- the one user-supplied piece, goes through shellQuote.

-- ==============================================================================
-- ── CONSTANTS ──────────────────────────────────────────────────────────────
-- ==============================================================================

-- The daemon writes under XDG_RUNTIME_DIR and falls back to /tmp when that is
-- unset; this resolves the path the same way so both sides always agree.
local RUNTIME_BASE = noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp"
local STATE_FILE = RUNTIME_BASE .. "/librepods/state.json"

-- The whole vocabulary a command may put on a command line. Anything not in
-- here is dropped before runControl ever sees it.
local ANC_MODES = {
  off = true,
  noise_cancellation = true,
  transparency = true,
  adaptive = true,
}

-- ctl is a one-shot round trip to a local daemon; anything slower than this is
-- a hung daemon, not a slow one.
local CONTROL_TIMEOUT_MS = 10000

-- ==============================================================================
-- ── HELPERS ────────────────────────────────────────────────────────────────
-- ==============================================================================

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- Safely quotes strings for shell execution to prevent injection.
local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function intConfig(key, fallback, low, high)
  local value = tonumber(noctalia.getConfig(key))
  if value == nil then return fallback end
  value = math.floor(value)
  if value < low then return low end
  if value > high then return high end
  return value
end

local function nowS()
  return math.floor(noctalia.nowMs() / 1000)
end

-- ==============================================================================
-- ── SNAPSHOT ───────────────────────────────────────────────────────────────
-- ==============================================================================

local pollBusy = false

-- Everything a consumer draws, as one string, so a tick that read the same file
-- never wakes the widget's or panel's watcher. updatedAt is deliberately left
-- out: it moves every publish by construction, so including it would defeat the
-- comparison.
local function snapshotKey(snapshot)
  local parts = {
    tostring(snapshot.daemonRunning), tostring(snapshot.connected),
    snapshot.name, snapshot.address, snapshot.mode,
    tostring(snapshot.conversationAwareness),
    table.concat(snapshot.allowedModes, ","),
    table.concat(snapshot.earDetection, ","),
  }
  for _, entry in ipairs(snapshot.battery) do
    table.insert(parts, table.concat({
      entry.component, tostring(entry.level),
      tostring(entry.charging), tostring(entry.connected),
    }, "\2"))
  end
  return table.concat(parts, "\1")
end

local lastSnapshotKey = nil

local function publishSnapshot(snapshot)
  local key = snapshotKey(snapshot)
  if key == lastSnapshotKey then return end
  lastSnapshotKey = key
  noctalia.state.set("snapshot", snapshot)
end

-- The daemon-is-down shape. Also what an unparsable file publishes: a document
-- the daemon did not write whole is not a state worth trusting.
local function downSnapshot()
  publishSnapshot({
    daemonRunning = false,
    connected = false,
    name = "",
    address = "",
    battery = {},
    earDetection = {},
    mode = "",
    allowedModes = {},
    conversationAwareness = nil,
    updatedAt = nowS(),
  })
end

-- Every field can be null or absent early in a connection, so nothing from the
-- file is trusted to be the type the schema promises.
local function normalizeBattery(rows)
  local battery = {}
  if type(rows) ~= "table" then return battery end
  for _, row in ipairs(rows) do
    if type(row) == "table" and type(row.component) == "string" then
      table.insert(battery, {
        component = row.component,
        level = tonumber(row.level) or 0,
        charging = row.charging == true,
        connected = row.connected == true,
      })
    end
  end
  return battery
end

local function normalizeStrings(rows)
  local values = {}
  if type(rows) ~= "table" then return values end
  for _, value in ipairs(rows) do
    if type(value) == "string" then table.insert(values, value) end
  end
  return values
end

local function normalize(payload)
  return {
    daemonRunning = true,
    connected = payload.connected == true,
    name = type(payload.name) == "string" and payload.name or "",
    address = type(payload.address) == "string" and payload.address or "",
    battery = normalizeBattery(payload.battery),
    earDetection = normalizeStrings(payload.ear_detection),
    mode = type(payload.noise_control_mode) == "string" and payload.noise_control_mode or "",
    allowedModes = normalizeStrings(payload.allowed_noise_control_modes),
    -- nil survives as "unknown" so the panel can hide the toggle until the
    -- daemon has read the flag off the device.
    conversationAwareness = type(payload.conversation_awareness) == "boolean"
      and payload.conversation_awareness or nil,
    updatedAt = nowS(),
  }
end

local function poll()
  if pollBusy then return end
  pollBusy = true

  local accepted = noctalia.readFileAsync(STATE_FILE, function(contents, _err)
    pollBusy = false
    if contents == nil then
      downSnapshot()
      return
    end
    local payload = noctalia.json.decode(noctalia.string.trim(contents))
    if type(payload) ~= "table" then
      downSnapshot()
      return
    end
    publishSnapshot(normalize(payload))
  end)

  -- A rejected read would otherwise leave the busy flag set forever.
  if not accepted then
    pollBusy = false
    downSnapshot()
  end
end

-- ==============================================================================
-- ── CONTROL ────────────────────────────────────────────────────────────────
-- ==============================================================================

-- args is built from the whitelists above, never from a caller's string. The
-- binary path is the one configurable piece and it is quoted.
local function runControl(args)
  local binary = noctalia.getConfig("librepods_binary")
  if type(binary) ~= "string" or binary == "" then binary = "librepods" end

  noctalia.runAsync(shellQuote(binary) .. " ctl " .. args, function(result)
    local ok = false
    local detail = ""

    if type(result) == "table" then
      local payload = noctalia.json.decode(noctalia.string.trim(result.stdout or ""))
      if type(payload) == "table" then
        ok = payload.ok == true
        if type(payload.error) == "string" then detail = payload.error end
      end
      if detail == "" then detail = noctalia.string.trim(result.stderr or "") end
    end

    if not ok then
      if detail == "" then detail = tr("error.command_failed") end
      noctalia.log(`librepods: ctl {args}: {detail}`)
      noctalia.notifyError(tr("title"), detail)
    end

    -- Success or failure, the daemon's state file is the truth; re-reading it
    -- now is what makes a mode click land in the bar before the next tick.
    poll()
  end, CONTROL_TIMEOUT_MS)
end

local function handleCommand(command)
  if type(command) ~= "table" then return end

  if command.action == "anc" and ANC_MODES[command.mode] then
    runControl("anc " .. command.mode)
  elseif command.action == "ca" then
    runControl("ca " .. (command.on == true and "on" or "off"))
  elseif command.action == "refresh" then
    poll()
  end
end

-- ==============================================================================
-- ── WIRING ─────────────────────────────────────────────────────────────────
-- ==============================================================================

-- The widget and the panel are in other Luau runtimes; this is their only way
-- in. Senders attach a nonce so a repeated identical command is still a
-- distinct value and the watch fires for it.
noctalia.state.watch("command", handleCommand)

-- The same verbs over shell IPC, for keybinds and scripts:
--   noctalia msg plugin tommyothen/librepods:svc all anc transparency
function onIpc(event, payload)
  if event == "anc" then
    handleCommand({ action = "anc", mode = payload })
  elseif event == "ca" then
    handleCommand({ action = "ca", on = payload == "on" })
  elseif event == "refresh" then
    poll()
  end
end

local function applyInterval()
  noctalia.setUpdateInterval(intConfig("poll_interval_ms", 1500, 500, 10000))
end

function update()
  poll()
end

function onConfigChanged()
  applyInterval()
end

function onEnable()
  applyInterval()
end

applyInterval()
downSnapshot()
poll()
