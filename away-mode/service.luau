--!nonstrict
-- Away Mode — headless service.
--
-- Owns the one piece of real state in this plugin: a transient systemd unit that
-- runs `systemd-inhibit --mode=block --what=sleep:handle-lid-switch sleep
-- infinity`. While that unit is alive logind refuses every suspend path — the
-- lid switch, the idle timer, `loginctl suspend`, `systemctl suspend` — and the
-- polkit action that would let a caller override a block inhibitor
-- (login1.suspend-ignore-inhibit) is auth_admin, so nothing unprivileged can
-- talk its way past it. `idle` is deliberately not in the --what list: leaving it
-- alone is what keeps the host's own lock and screen-off timers working, which
-- is the entire difference between this and caffeine.
--
-- Because the state is the unit, "am I on?" is answered by `systemctl --user
-- is-active` rather than by a variable, and it stays correct across a plugin
-- reload, a shell restart or a crash. Starting the service while the unit is
-- already up adopts it instead of resetting it.
--
-- Noctalia's Luau sandbox has no `require`, so the widget and the shortcut talk
-- to this singleton through the shared "away_command" state key and read
-- "away_status" back.

-- ==============================================================================
-- ── COMMANDS ────────────────────────────────────────────────────────────────
-- ==============================================================================

local UNIT = "away-mode-inhibit"
local UNIT_FULL = `{UNIT}.service`

-- reset-failed first, so a unit left in `failed` by an earlier crash does not
-- block the name. `--collect` garbage-collects the unit the moment it stops, so
-- a clean exit never leaves a corpse behind either.
local START_COMMAND = `systemctl --user reset-failed {UNIT_FULL} >/dev/null 2>&1 || true; ` .. table.concat({
  `systemd-run --user --quiet --collect --unit={UNIT}`,
  `--description='Noctalia Away Mode'`,
  `systemd-inhibit --what=sleep:handle-lid-switch`,
  `--who='Away Mode'`,
  `--why='Away mode: work keeps running while nobody is at the machine'`,
  `--mode=block sleep infinity`,
}, " ")

local STOP_COMMAND = `systemctl --user stop {UNIT_FULL}`
local CHECK_COMMAND = `systemctl --user is-active --quiet {UNIT_FULL}`

-- When the unit is adopted rather than started by us, systemd is the only thing
-- that still knows when it went up. `date` is coreutils, but it is not declared
-- as a dependency: a host without it just loses the "since" row in the tooltip.
local SINCE_COMMAND =
  `date -d "$(systemctl --user show {UNIT_FULL} -p ActiveEnterTimestamp --value)" +%s 2>/dev/null || echo 0`

local LOCK_COMMAND = "noctalia msg session lock"
local DPMS_OFF_COMMAND = "noctalia msg dpms-off"
local STATUS_COMMAND = "noctalia msg status"

-- Muting goes through wpctl rather than `noctalia msg volume-mute` because the
-- CLI only offers a blind toggle, and this step has to read the state first: a
-- sink that was already muted on the way out must stay muted on the way back.
-- The marker file is how the off path learns the mute was ours, and it lives on
-- disk for the same reason the inhibitor lives in a unit: a shell restart in
-- the middle of an away period must not orphan the mute. The path is shared
-- with the standalone away-mode script, so either side restores what the other
-- muted.
local MUTE_MARKER = '"${XDG_RUNTIME_DIR:-/tmp}/away-mode/restore-unmute"'
local MUTE_COMMAND = 'mkdir -p "${XDG_RUNTIME_DIR:-/tmp}/away-mode"; '
  .. "if wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -q MUTED; "
  .. `then rm -f {MUTE_MARKER}; `
  .. `else wpctl set-mute @DEFAULT_AUDIO_SINK@ 1 && touch {MUTE_MARKER}; fi`
local UNMUTE_COMMAND = `if [ -e {MUTE_MARKER} ]; `
  .. "then wpctl set-mute @DEFAULT_AUDIO_SINK@ 0; "
  .. `rm -f {MUTE_MARKER}; fi`

-- ==============================================================================
-- ── TUNING ──────────────────────────────────────────────────────────────────
-- ==============================================================================

-- The tick drives the unlock poll. Three seconds is under the time it takes to
-- type a password and press Enter, so "on" never outlives the return by long,
-- and one `noctalia msg status` per tick is a single IPC round trip.
local POLL_INTERVAL_MS = 3000

-- Reconcile against systemd every other tick, which catches the unit being
-- stopped from outside the plugin (`systemctl --user stop`, an OOM kill).
local RECONCILE_EVERY_TICKS = 2

-- The lockscreen surface takes a moment to map, and mapping it wakes the
-- outputs. Blanking before that settles gets undone; blanking after sticks.
local LOCK_SETTLE_SECONDS = "0.4"

local STATUS_TIMEOUT_MS = 3000

-- ==============================================================================
-- ── STATE ───────────────────────────────────────────────────────────────────
-- ==============================================================================

local on = false          -- is the inhibitor unit active?
local since = 0           -- unix seconds the unit went up, 0 when unknown
local busy = false        -- a start/stop is in flight
local tick = 0

-- The last set of fields handed to subscribers, so a reconcile that finds
-- nothing moved does not make every bar re-render.
local published = nil

-- nil until the first successful lock poll of the current "on" period, so the
-- arming poll can never look like a true -> false unlock all by itself.
local lastLocked = nil
local lockPollInFlight = false

local hasSystemd = noctalia.commandExists("systemctl")
  and noctalia.commandExists("systemd-run")
  and noctalia.commandExists("systemd-inhibit")
  and noctalia.commandExists("sleep")
local hasCli = noctalia.commandExists("noctalia")
local hasWpctl = noctalia.commandExists("wpctl")

-- ==============================================================================
-- ── HELPERS ─────────────────────────────────────────────────────────────────
-- ==============================================================================

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function cfg(key)
  return noctalia.getConfig(key) == true
end

-- `force` re-publishes an unchanged set, which is how a command path
-- acknowledges itself: repeating a failure is news even when the fields match.
local function publish(errorMessage, force)
  local status = {
    on = on,
    since = since,
    busy = busy,
    available = hasSystemd,
    error = errorMessage or "",
  }

  if not force and published ~= nil
    and published.on == status.on
    and published.since == status.since
    and published.busy == status.busy
    and published.available == status.available
    and published.error == status.error
  then
    return
  end

  published = status
  noctalia.state.set("away_status", status)
end

local function fail(detail)
  local message = noctalia.string.trim(detail or "")
  if message == "" then message = tr("error.command_failed") end
  noctalia.log(`away-mode: {message}`)
  publish(message, true)
  noctalia.notifyError(tr("title"), message)
end

-- The coming-back half of the mute step. Deliberately not gated on the setting:
-- if the marker exists the mute was ours, and switching the option off while
-- away must not strand it. Without the marker this is a no-op.
local function restoreMute()
  if hasWpctl then noctalia.runAsync(UNMUTE_COMMAND) end
end

-- ==============================================================================
-- ── THE UNIT ────────────────────────────────────────────────────────────────
-- ==============================================================================

-- Ask systemd when the unit went up. Only worth doing for a unit we adopted;
-- one we started ourselves already has an exact timestamp.
local function fetchSince()
  noctalia.runAsync(SINCE_COMMAND, function(result)
    local stamp = tonumber(noctalia.string.trim(result.stdout or "")) or 0
    if stamp > 0 and on then
      since = stamp
      publish()
    end
  end)
end

-- The single source of truth. Everything else in this file reads state through
-- here rather than trusting its own bookkeeping.
local function refresh(callback)
  if not hasSystemd then
    on = false
    publish(tr("error.missing_dependencies"))
    if callback then callback(false) end
    return
  end

  noctalia.runAsync(CHECK_COMMAND, function(result)
    local wasOn = on
    on = result.exitCode == 0

    if on and not wasOn then
      -- Adopted from a previous shell lifetime, or turned on behind our back.
      lastLocked = nil
      if since == 0 then fetchSince() end
    elseif not on then
      -- Fires for our own stop and for one from outside the plugin alike.
      if wasOn then restoreMute() end
      since = 0
      lastLocked = nil
    end

    publish()
    if callback then callback(on) end
  end)
end

-- ==============================================================================
-- ── LEAVING AND COMING BACK ─────────────────────────────────────────────────
-- ==============================================================================

-- Mute, lock and blank, in that order and in one detached shell, so the sleep
-- between lock and blank costs nothing here. All three are opt-out, and all
-- three are no-ops that the host absorbs harmlessly when the sink is already
-- muted, the session already locked or the screens already dark.
local function runLeaveActions()
  local steps = {}
  if cfg("mute_on_enable") and hasWpctl then table.insert(steps, MUTE_COMMAND) end

  if hasCli then
    if cfg("lock_on_enable") then table.insert(steps, LOCK_COMMAND) end
    if cfg("screen_off_on_enable") then
      if cfg("lock_on_enable") then table.insert(steps, `sleep {LOCK_SETTLE_SECONDS}`) end
      table.insert(steps, DPMS_OFF_COMMAND)
    end
  end

  if #steps > 0 then noctalia.runAsync(table.concat(steps, " ; ")) end
end

-- Called with the state that was asked for; verifies against systemd rather
-- than assuming the command that just exited 0 did what it said.
local function finish(wanted, result, reason)
  if result.exitCode ~= 0 then
    busy = false
    fail(result.stderr)
    return
  end

  refresh(function(nowOn)
    busy = false
    publish()

    if nowOn ~= wanted then
      fail(tr("error.state_mismatch"))
      return
    end

    if nowOn then
      runLeaveActions()
      noctalia.notify(tr("notification.on.title"), tr("notification.on.body"))
    elseif reason == "unlock" then
      noctalia.notify(tr("notification.auto_off.title"), tr("notification.auto_off.body"))
    else
      noctalia.notify(tr("notification.off.title"), tr("notification.off.body"))
    end
  end)
end

local function setOn(wanted, reason)
  if busy or not hasSystemd then return end
  busy = true
  publish()

  if wanted then
    since = os.time()
    lastLocked = nil
    noctalia.runAsync(START_COMMAND, function(result)
      finish(true, result, reason)
    end)
  else
    noctalia.runAsync(STOP_COMMAND, function(result)
      finish(false, result, reason)
    end)
  end
end

local function toggle()
  refresh(function(nowOn)
    setOn(not nowOn, "manual")
  end)
end

-- ==============================================================================
-- ── UNLOCK WATCHER ──────────────────────────────────────────────────────────
-- ==============================================================================
--
-- The plugin API exposes no lock-state accessor and no lock/unlock callback, so
-- the shell's own IPC is the only reading available: `noctalia msg status`
-- returns a JSON document with a `locked` flag. This polls it, and only while
-- the mode is on, so a machine that is not away pays nothing for the feature.
--
-- The trigger is the transition, not the level: turning the mode on while the
-- session happens to be unlocked must not immediately turn it back off.

local function pollLock()
  if lockPollInFlight or not hasCli then return end
  if not on or not cfg("auto_off_on_unlock") then return end

  lockPollInFlight = true
  noctalia.runAsync(STATUS_COMMAND, function(result)
    lockPollInFlight = false
    if result.exitCode ~= 0 then return end

    local status = noctalia.json.decode(result.stdout or "")
    if type(status) ~= "table" or type(status.locked) ~= "boolean" then return end

    local wasLocked = lastLocked
    lastLocked = status.locked

    if wasLocked == true and status.locked == false and on and not busy then
      setOn(false, "unlock")
    end
  end, STATUS_TIMEOUT_MS)
end

-- ==============================================================================
-- ── WIRING ──────────────────────────────────────────────────────────────────
-- ==============================================================================

-- The widget and the shortcut are in other Luau runtimes; this is their only way
-- in. The nonce is what makes a second identical request a distinct value, so
-- the watch actually fires for it.
noctalia.state.watch("away_command", function(command)
  if type(command) ~= "table" then return end

  if command.action == "toggle" then
    toggle()
  elseif command.action == "on" then
    setOn(true, "manual")
  elseif command.action == "off" then
    setOn(false, "manual")
  elseif command.action == "refresh" then
    refresh()
  end
end)

function onIpc(event, _payload)
  if event == "toggle" then
    toggle()
  elseif event == "on" or event == "enable" then
    setOn(true, "manual")
  elseif event == "off" or event == "disable" then
    setOn(false, "manual")
  elseif event == "refresh" or event == "status" then
    refresh()
  end
end

function update()
  tick += 1
  if busy then return end

  pollLock()
  if tick % RECONCILE_EVERY_TICKS == 0 then refresh() end
end

-- A settings change can invalidate the watcher's memory of the lock state — the
-- user may have had auto-off switched off across a whole lock/unlock cycle — so
-- re-arm rather than act on a stale reading.
function onConfigChanged()
  lastLocked = nil
end

-- Surviving a reload is the point of the transient unit, so teardown leaves it
-- running. Being disabled or uninstalled is different: the toggle is about to
-- disappear, and leaving an invisible suspend block behind would be a trap.
function onExit(_signal, reason)
  if (reason == "disable" or reason == "uninstall") and on then
    noctalia.runAsync(STOP_COMMAND)
    restoreMute()
  end
end

noctalia.setUpdateInterval(POLL_INTERVAL_MS)
publish(if hasSystemd then nil else tr("error.missing_dependencies"))
refresh()
