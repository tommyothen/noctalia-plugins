--!nonstrict
-- Portrait. Headless service.
--
-- The one piece of real state is niri's output transform, and niri already owns
-- it, so this service keeps no bookkeeping it could get wrong: every answer to
-- "which way is the screen turned?" comes from `niri msg -j outputs`, polled on
-- a slow tick and re-read after every change. A rotation done from a terminal
-- shows up here within one poll.
--
-- Noctalia's Luau sandbox keeps each entry in its own runtime, so the widget
-- and the shortcut talk to this singleton through the shared "portrait_command"
-- state key and read "portrait_status" back.

-- ==============================================================================
-- ── COMMANDS ────────────────────────────────────────────────────────────────
-- ==============================================================================

local OUTPUTS_COMMAND = "niri msg -j outputs"

local function transformCommand(outputName, transform)
  return `niri msg output "{outputName}" transform {transform}`
end

-- ==============================================================================
-- ── TUNING ──────────────────────────────────────────────────────────────────
-- ==============================================================================

-- The poll only exists to catch rotations done outside the plugin, so it can be
-- lazy. One `niri msg` every five seconds is one IPC round trip.
local POLL_INTERVAL_MS = 5000

local COMMAND_TIMEOUT_MS = 5000

-- The transforms this plugin will set. Flipped variants are deliberately out of
-- scope: nobody mirrors a monitor to watch a video.
local ROTATIONS = { ["90"] = true, ["180"] = true, ["270"] = true }

-- ==============================================================================
-- ── STATE ───────────────────────────────────────────────────────────────────
-- ==============================================================================

local transform = "normal" -- lowercase transform of the target output
local output = ""          -- connector the transform was last read from
local busy = false         -- a rotate is in flight

-- The last set of fields handed to subscribers, so a poll that finds nothing
-- moved does not make every bar re-render.
local published = nil

local hasNiri = noctalia.commandExists("niri")

-- ==============================================================================
-- ── HELPERS ─────────────────────────────────────────────────────────────────
-- ==============================================================================

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- `force` re-publishes an unchanged set, which is how a command path
-- acknowledges itself: repeating a failure is news even when the fields match.
local function publish(errorMessage, force)
  local status = {
    transform = transform,
    output = output,
    busy = busy,
    available = hasNiri,
    error = errorMessage or "",
  }

  if not force and published ~= nil
    and published.transform == status.transform
    and published.output == status.output
    and published.busy == status.busy
    and published.available == status.available
    and published.error == status.error
  then
    return
  end

  published = status
  noctalia.state.set("portrait_status", status)
end

local function fail(detail)
  local message = noctalia.string.trim(detail or "")
  if message == "" then message = tr("error.command_failed") end
  noctalia.log(`portrait: {message}`)
  publish(message, true)
  noctalia.notifyError(tr("title"), message)
end

-- The configured rotation, guarded so a typo in the setting degrades to the
-- default instead of handing niri an invalid transform.
local function configuredRotation()
  local value = noctalia.string.trim(tostring(noctalia.getConfig("rotation") or ""))
  if ROTATIONS[value] then return value end
  return "270"
end

-- Which output the next command targets. A pinned connector wins; otherwise a
-- screen we rotated stays the target until it is back to normal, so the reset
-- lands on the right monitor even after focus has moved; otherwise the focused
-- output.
local function targetOutput()
  local pinned = noctalia.string.trim(tostring(noctalia.getConfig("output") or ""))
  if pinned ~= "" then return pinned end
  if output ~= "" and transform ~= "normal" then return output end
  return noctalia.focusedOutputName() or output
end

-- ==============================================================================
-- ── READING AND SETTING ─────────────────────────────────────────────────────
-- ==============================================================================

-- The single source of truth. niri reports transforms as "Normal", "90",
-- "Flipped90" and friends; everything downstream compares lowercase, and any
-- flipped state simply counts as "not normal".
local function refresh(callback)
  if not hasNiri then
    publish(tr("error.missing_dependencies"))
    if callback then callback() end
    return
  end

  noctalia.runAsync(OUTPUTS_COMMAND, function(result)
    if result.exitCode ~= 0 then
      publish(noctalia.string.trim(result.stderr))
      if callback then callback() end
      return
    end

    local outputs = noctalia.json.decode(result.stdout or "")
    if type(outputs) ~= "table" then
      publish(tr("error.command_failed"))
      if callback then callback() end
      return
    end

    local entry = outputs[targetOutput()]
    if entry == nil then
      -- The pinned or remembered connector is gone (unplugged, renamed). Fall
      -- back to any connected output rather than going dark.
      for _, candidate in outputs do
        entry = candidate
        break
      end
    end

    if type(entry) == "table" then
      output = tostring(entry.name or "")
      local logical = entry.logical
      if type(logical) == "table" and logical.transform ~= nil then
        transform = string.lower(tostring(logical.transform))
      else
        transform = "normal" -- output disabled; treat as upright
      end
    end

    publish()
    if callback then callback() end
  end, COMMAND_TIMEOUT_MS)
end

local function setTransform(wanted)
  if busy or not hasNiri then return end

  local target = targetOutput()
  if target == "" then
    fail(tr("error.no_output"))
    return
  end

  busy = true
  publish()

  noctalia.runAsync(transformCommand(target, wanted), function(result)
    busy = false
    if result.exitCode ~= 0 then
      fail(result.stderr)
      refresh()
      return
    end
    output = target
    refresh()
  end, COMMAND_TIMEOUT_MS)
end

-- Toggle re-reads before deciding, so it flips the real state rather than a
-- possibly stale copy of it.
local function toggle()
  refresh(function()
    if transform == "normal" then
      setTransform(configuredRotation())
    else
      setTransform("normal")
    end
  end)
end

-- ==============================================================================
-- ── WIRING ──────────────────────────────────────────────────────────────────
-- ==============================================================================

-- The widget and the shortcut are in other Luau runtimes; this is their only
-- way in. The nonce makes a second identical request a distinct value, so the
-- watch actually fires for it.
noctalia.state.watch("portrait_command", function(command)
  if type(command) ~= "table" then return end

  if command.action == "toggle" then
    toggle()
  elseif command.action == "set" and (command.transform == "normal" or ROTATIONS[command.transform]) then
    setTransform(command.transform)
  elseif command.action == "refresh" then
    refresh()
  end
end)

function onIpc(event, _payload)
  if event == "toggle" then
    toggle()
  elseif event == "normal" or event == "reset" then
    setTransform("normal")
  elseif ROTATIONS[event] then
    setTransform(event)
  elseif event == "refresh" or event == "status" then
    refresh()
  end
end

function update()
  if not busy then refresh() end
end

-- A rotated screen with the plugin gone would have no toggle left to un-rotate
-- it, so being disabled or uninstalled puts the monitor back upright. A plain
-- reload leaves it alone.
function onExit(_signal, reason)
  if (reason == "disable" or reason == "uninstall") and transform ~= "normal" and output ~= "" and hasNiri then
    noctalia.runAsync(transformCommand(output, "normal"))
  end
end

noctalia.setUpdateInterval(POLL_INTERVAL_MS)
publish(if hasNiri then nil else tr("error.missing_dependencies"))
refresh()
