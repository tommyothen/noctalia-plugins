--!nonstrict
-- Bongo Cat. A cat that sits in your bar and slaps when you type or to the beat.
--
-- Fork of noctalia/bongocat 1.1.4 (MIT). Everything below the input reader is
-- upstream's; the reader is rewritten. Upstream asks you to name input devices
-- by hand and steers you at /dev/input/by-id or by-path, neither of which exists
-- for the uinput device a key remapper (keyd, kmonad, evremap, xremap) replays
-- your keystrokes on. With `auto_detect` on, this reader reads
-- /proc/bus/input/devices, keeps every device advertising EV_KEY and EV_REP
-- (that pair is what makes a device a keyboard rather than a power button or a
-- touchpad), and rescans every few seconds so a keyboard plugged in later gets
-- picked up. `input_devices` still overrides when you want a specific device.
--
-- A grabbed keyboard is silent rather than duplicated, so reading both the
-- physical keyboard and the remapper's virtual one at once is fine: only the
-- ungrabbed one emits.
--
-- Requirements: `evtest` installed, and your user in the `input` group.
--
-- Audio reactivity (audio_spectrum) uses the PipeWire spectrum and delivers
-- frames to onAudioSpectrum below.
--
-- The typing speed readout (show_wpm) is this fork's, and it is the reason the
-- widget draws through barWidget.render rather than setText: the cat and the
-- number need different fonts in one row.
--
-- Font glyph map (fonts/bongocat.otf):
--   b=left paw up, d=left paw down, c=right paw up, a=right paw down
--   bc=idle, dc=left slap, ba=right slap, da=both slap
--   ef=sleep, gh=blink

local bongocatFont = noctalia.loadFont("fonts/bongocat.otf")
if bongocatFont then
  barWidget.setFont(bongocatFont, "pictographic")
end
barWidget.setText("bc")

local TICK_MS = 50
local TICK_SECONDS = TICK_MS / 1000
-- Asleep or paused there is no animation to step, and keys arrive on the evtest
-- stream rather than the tick, so waking up does not depend on the tick rate.
local SLEEP_TICK_MS = 500
local tickMs = TICK_MS
noctalia.setUpdateInterval(TICK_MS)

local STATE_IDLE = 0
local STATE_LEFT = 1
local STATE_RIGHT = 2
local STATE_BOTH = 3

local glyphs = { [STATE_IDLE] = "bc", [STATE_LEFT] = "dc", [STATE_RIGHT] = "ba", [STATE_BOTH] = "da" }
local SLEEP_GLYPH = "ef"
local BLINK_GLYPH = "gh"

local catState = STATE_IDLE
local leftWasLast = false
local paused = false
local waiting = false
local blinking = false

local AUDIO_SPECTRUM_ENABLED = noctalia.getConfig("audio_spectrum") == true
local RAVE_MODE = noctalia.getConfig("rave_mode") == true
local TAPPY_MODE = noctalia.getConfig("tappy_mode") == true
local USE_MPRIS_FILTER = noctalia.getConfig("use_mpris_filter") == true
local SHOW_WPM = noctalia.getConfig("show_wpm") ~= false

local idleTicks = 0
local waitingTicks = 0
local blinkDuration = 0
local nextBlinkIn = 0

local IDLE_TICKS = 5       -- 250ms to return paws to idle after typing stops
local WAITING_TICKS = 100  -- 5s of idle -> sleeping
local BLINK_DURATION = 9   -- ~450ms blink
local BLINK_MIN = 120      -- ~6s minimum between blinks
local BLINK_MAX = 280      -- ~14s max between blinks

local rainbowIndex = 1
local rainbowColors = { "#aa0000", "#b65c02", "#bb9c14", "#00a100", "#01019b", "#37005c", "#6a0196" }
local audioIntensity = 0
local smoothedIntensity = 0
local previousIntensity = 0
local bassIntensity = 0
local beatThreshold = 0.07
local bigBeatThreshold = 0.67
local beatDeltaThreshold = 0.014
local beatCooldownTicks = 0 -- ~100ms
local raveFlashTicks = 0    -- ~100ms
local audioConfigWarned = false

-- Drops the tick to a slow poll whenever nothing is moving: no paws to bring
-- back to idle, no blink to time, no rave flash to end.
local function syncTickRate()
  local idle = (paused or waiting) and raveFlashTicks <= 0 and beatCooldownTicks <= 0
  local wanted = if idle then SLEEP_TICK_MS else TICK_MS
  if wanted ~= tickMs then
    tickMs = wanted
    noctalia.setUpdateInterval(wanted)
  end
end

local function randomBlinkDelay()
  return BLINK_MIN + math.floor(math.random() * (BLINK_MAX - BLINK_MIN))
end

nextBlinkIn = randomBlinkDelay()

-- ── Typing speed ──────────────────────────────────────────────────────────
-- Words per minute over a rolling window, one bucket of keystrokes per tick.
-- A word is the conventional five characters, so wpm = (chars / 5) / minutes.
--
-- Only keys that produce a character count. Modifiers, arrows and F-keys are
-- typing, but they are not words, and counting them would read as a burst of
-- speed every time you reach for Ctrl. Autorepeat is left out for the same
-- reason: holding a key down is not typing fast.
local WPM_WINDOW_TICKS = 100    -- 5s of history
local WPM_MIN_SECONDS = 1       -- floor on the divisor, so the first keys ramp in
local WPM_MIN_KEYSTROKES = 5    -- below this the number is noise, so show nothing
local CHARS_PER_WORD = 5

local TYPING_KEYS = {
  KEY_SPACE = true, KEY_COMMA = true, KEY_DOT = true, KEY_SLASH = true,
  KEY_SEMICOLON = true, KEY_APOSTROPHE = true, KEY_GRAVE = true,
  KEY_MINUS = true, KEY_EQUAL = true, KEY_BACKSLASH = true,
  KEY_LEFTBRACE = true, KEY_RIGHTBRACE = true, KEY_102ND = true,
  KEY_KPASTERISK = true, KEY_KPMINUS = true, KEY_KPPLUS = true,
  KEY_KPDOT = true, KEY_KPSLASH = true, KEY_KPCOMMA = true, KEY_KPEQUAL = true,
}
for byte = string.byte("A"), string.byte("Z") do
  TYPING_KEYS[`KEY_{string.char(byte)}`] = true
end
for digit = 0, 9 do
  TYPING_KEYS[`KEY_{digit}`] = true
  TYPING_KEYS[`KEY_KP{digit}`] = true
end

local wpmBuckets = table.create(WPM_WINDOW_TICKS, 0)
local wpmCursor = 1
local wpmKeystrokes = 0
local wpmBurstTicks = 0
local shownWpm: string? = nil
local tooltipLabel: string? = nil
local isVertical = false

local function countKeystroke(keyName: string?)
  if not SHOW_WPM or paused or keyName == nil or not TYPING_KEYS[keyName] then return end
  wpmBuckets[wpmCursor] += 1
  wpmKeystrokes += 1
end

-- Steps the ring one tick on: the cursor lands on the oldest bucket, which
-- drops out of the window and becomes the bucket for the tick starting now.
local function advanceWpmWindow()
  wpmCursor = (wpmCursor % WPM_WINDOW_TICKS) + 1
  wpmKeystrokes -= wpmBuckets[wpmCursor]
  wpmBuckets[wpmCursor] = 0
  wpmBurstTicks = if wpmKeystrokes > 0 then math.min(wpmBurstTicks + 1, WPM_WINDOW_TICKS) else 0
end

-- Emptied when the cat sleeps or pauses, because the window is not stepped
-- while it is down and stale buckets would otherwise count towards the first
-- number after it wakes.
local function resetWpmWindow()
  for i = 1, WPM_WINDOW_TICKS do
    wpmBuckets[i] = 0
  end
  wpmCursor = 1
  wpmKeystrokes = 0
  wpmBurstTicks = 0
end

-- The number to draw, or nil when there is nothing worth drawing. Until the
-- window fills, the divisor is how long you have been typing rather than the
-- full 5s, so a burst reads at its own speed instead of a fifth of it.
local function wpmLabel(): string?
  if not SHOW_WPM or paused or wpmKeystrokes < WPM_MIN_KEYSTROKES then
    return nil
  end
  local seconds = math.max(wpmBurstTicks * TICK_SECONDS, WPM_MIN_SECONDS)
  local wpm = (wpmKeystrokes / CHARS_PER_WORD) * (60 / seconds)
  return tostring(math.floor(wpm + 0.5))
end

local function catColor()
  if RAVE_MODE and raveFlashTicks > 0 then
    return rainbowColors[rainbowIndex]
  end
  return "on_surface"
end

local function applyTooltip(label: string?)
  if label == tooltipLabel then
    return
  end
  tooltipLabel = label
  if label == nil then
    -- clearTooltip on a widget that has no tooltip takes the plugin down with
    -- it. Getting here means the previous label was not nil, so there is one.
    barWidget.clearTooltip()
  else
    barWidget.setTooltip(noctalia.tr("wpm.tooltip", { n = label }))
  end
end

local function refreshDisplay()
  local glyph = if paused or waiting then SLEEP_GLYPH elseif blinking then BLINK_GLYPH else glyphs[catState] or "bc"
  local color = catColor()

  if not SHOW_WPM then
    if color == "on_surface" then
      barWidget.setColor(color)
    else
      barWidget.setColor(color, "script")
    end
    barWidget.setText(glyph)
    return
  end

  shownWpm = wpmLabel()
  applyTooltip(shownWpm)

  -- The number stacks under the cat on a vertical bar and sits beside it on a
  -- horizontal one, which is also the difference between a 36px bar fitting it
  -- and not.
  local layout = if isVertical then ui.column else ui.row
  local children = { ui.label({ text = glyph, fontFamily = bongocatFont, color = color }) }
  if shownWpm ~= nil then
    table.insert(children, ui.label({ text = shownWpm, fontSize = 11, color = "on_surface_variant" }))
  end
  barWidget.render(layout({ align = "center", gap = if isVertical then 0 else 4 }, children))
end

if SHOW_WPM then
  isVertical = barWidget.isVertical()
  refreshDisplay()
end

local function onKeyDown(isBigHit)
  if paused then return end
  waiting = false
  waitingTicks = 0
  blinking = false

  if isBigHit or catState ~= STATE_IDLE then
    catState = STATE_BOTH
  else
    leftWasLast = not leftWasLast
    catState = if leftWasLast then STATE_LEFT else STATE_RIGHT
  end
  idleTicks = 0
  syncTickRate()
  refreshDisplay()
end

local function onKeyUp()
  if paused then return end
  waiting = false
  waitingTicks = 0

  catState = if catState == STATE_BOTH then if leftWasLast then STATE_LEFT else STATE_RIGHT else STATE_IDLE
  idleTicks = 0
  syncTickRate()
  refreshDisplay()
end

local function onKeyRepeat(isBigHit)
  if paused then return end
  waiting = false
  waitingTicks = 0

  if catState == STATE_IDLE then
    catState = if isBigHit then STATE_BOTH elseif leftWasLast then STATE_LEFT else STATE_RIGHT
  end
  idleTicks = 0
  syncTickRate()
  refreshDisplay()
end

local function onBeatTap(isBigHit)
  if paused then return end
  waiting = false
  waitingTicks = 0
  blinking = false

  if isBigHit then
    catState = STATE_BOTH
  else
    leftWasLast = not leftWasLast
    catState = if leftWasLast then STATE_LEFT else STATE_RIGHT
  end

  idleTicks = 0
  syncTickRate()
  refreshDisplay()
end

-- ── Input reader (noctalia.runStream → evtest) ────────────────────────────
local function has(line, needle)
  return line:find(needle, 1, true) ~= nil
end

local function onEvtestLine(line)
  -- evtest prints one line per event, e.g.:
  --   Event: time 1700.0, type 1 (EV_KEY), code 57 (KEY_SPACE), value 1
  if not has(line, "EV_KEY") or has(line, "BTN_TOOL_") then
    return
  end
  local isBigHit = has(line, "KEY_SPACE") or has(line, "KEY_ENTER")
  if has(line, "value 1") then
    -- The KEY_ name, skipping the line's own "(EV_KEY)". Unknown codes print
    -- as "(?)" and simply do not match.
    countKeystroke(line:match("%((KEY_[%u%d_]+)%)"))
    onKeyDown(isBigHit)
  elseif has(line, "value 0") then
    onKeyUp()
  elseif has(line, "value 2") then
    onKeyRepeat(isBigHit)
  end
end

local function isAllowedInputPatternByte(byte)
  return (byte >= 48 and byte <= 57) -- 0-9
      or (byte >= 65 and byte <= 90) -- A-Z
      or (byte >= 97 and byte <= 122) -- a-z
      or byte == 47 -- /
      or byte == 46 -- .
      or byte == 95 -- _
      or byte == 45 -- -
      or byte == 58 -- :
      or byte == 43 -- +
      or byte == 42 -- *
      or byte == 63 -- ?
      or byte == 91 -- [
      or byte == 93 -- ]
end

local function isSupportedInputPattern(pattern)
  return pattern:match("^/dev/input/event") ~= nil
      or pattern:match("^/dev/input/by%-id/") ~= nil
      or pattern:match("^/dev/input/by%-path/") ~= nil
end

local function validateInputPattern(pattern)
  if type(pattern) ~= "string" or pattern == "" then
    return false
  end
  if pattern:find("..", 1, true) ~= nil or not isSupportedInputPattern(pattern) then
    return false
  end
  for i = 1, #pattern do
    if not isAllowedInputPatternByte(pattern:byte(i)) then
      return false
    end
  end
  return true
end

-- Reads the configured input_devices, or nil when none are set. Returns false on
-- a malformed entry, having already notified.
local function configuredPatterns()
  local devices = noctalia.getConfig("input_devices")
  if devices == nil then
    return nil
  end
  if type(devices) ~= "table" then
    noctalia.notifyError("Bongo Cat", "Invalid input_devices (expected a list of /dev/input paths or globs)")
    return false
  end

  local patterns = {}
  local seen = {}
  for _, pattern in ipairs(devices) do
    if not validateInputPattern(pattern) then
      noctalia.notifyError("Bongo Cat", `Invalid input_devices entry: {tostring(pattern)}`)
      return false
    end
    if seen[pattern] == nil then
      seen[pattern] = true
      table.insert(patterns, pattern)
    end
  end
  if #patterns == 0 then
    return nil
  end
  return patterns
end

-- One long-lived POSIX shell: it resolves the device list, runs an evtest per
-- device, and every RESCAN_SECONDS re-resolves and restarts them if the list
-- changed. Restarting inside the shell matters because runStream hands back no
-- handle, so the script cannot stop and restart the stream itself.
--
-- EV bit 1 is EV_KEY and bit 20 (0x100000) is EV_REP. Requiring both is what
-- separates a keyboard from the power button, the lid switch and the touchpad,
-- all of which also report EV_KEY.
local READER_SCRIPT = [[
parent=$PPID
pids=''

stop_readers() {
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null
    pids=''
  fi
}

trap 'stop_readers; exit 0' INT TERM
trap stop_readers EXIT

list_devices() {
__LIST_DEVICES__
}

previous=''
while kill -0 "$parent" 2>/dev/null; do
  current=$(list_devices)
  if [ "$current" != "$previous" ]; then
    stop_readers
    for device in $current; do
      [ -r "$device" ] || continue
      __EVTEST__ "$device" 2>/dev/null &
      pids="$pids $!"
    done
    previous=$current
  fi
  sleep __RESCAN__
done

stop_readers
]]

local AUTO_DETECT_BODY = [[
  handlers=''
  while IFS= read -r line; do
    case "$line" in
      'H: Handlers='*)
        handlers=${line#H: Handlers=}
        ;;
      'B: EV='*)
        bits=${line#B: EV=}
        case "$bits" in
          '' | *[!0-9A-Fa-f]*) bits=0 ;;
        esac
        ev=$((0x$bits))
        if [ $((ev & 2)) -ne 0 ] && [ $((ev & 1048576)) -ne 0 ]; then
          for handler in $handlers; do
            case "$handler" in
              event*) printf '/dev/input/%s\n' "$handler" ;;
            esac
          done
        fi
        ;;
    esac
  done < /proc/bus/input/devices
]]

local RESCAN_SECONDS = 5

local function shellSingleQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function startInputReader()
  local patterns = configuredPatterns()
  if patterns == false then
    return
  end

  local autoDetect = noctalia.getConfig("auto_detect") ~= false
  if patterns == nil and not autoDetect then
    return
  end

  local executable = noctalia.getConfig("executable_path")
  if executable == nil or executable == "" then
    executable = "evtest"
  end

  if not noctalia.commandExists(executable) then
    noctalia.notifyError("Bongo Cat", "the evtest path is invalid (" .. executable .. "), so input devices cannot be read")
    return
  end

  -- Explicit devices still expand as globs, so an unplugged device that comes
  -- back later is picked up by the same rescan as an auto-detected one.
  local listBody = AUTO_DETECT_BODY
  if patterns ~= nil then
    listBody = "  for device in " .. table.concat(patterns, " ")
      .. "; do [ -e \"$device\" ] && printf '%s\\n' \"$device\"; done"
  end

  local command = READER_SCRIPT
    :gsub("__LIST_DEVICES__", function() return listBody end)
    :gsub("__EVTEST__", function() return shellSingleQuote(executable) end)
    :gsub("__RESCAN__", function() return tostring(RESCAN_SECONDS) end)

  if not noctalia.runStream(command, onEvtestLine) then
    noctalia.notifyError("Bongo Cat", "Unable to start input device reader")
  end
end

startInputReader()

local function parseCsvNumbers(csv)
  local values = {}
  if csv == nil or csv == "" then
    return values
  end
  for part in csv:gmatch("([^,]+)") do
    table.insert(values, tonumber(part) or 0)
  end
  return values
end

local function parseAudioState(csv)
  local parts = parseCsvNumbers(csv)
  return parts[1] == 1, parts[2] == 1
end

local function average(values, firstIndex, lastIndex)
  if lastIndex < firstIndex then
    return 0
  end
  local sum = 0
  local count = 0
  for i = firstIndex, lastIndex do
    sum = sum + (values[i] or 0)
    count += 1
  end
  if count == 0 then
    return 0
  end
  return sum / count
end

function update()
  if (RAVE_MODE or TAPPY_MODE) and not AUDIO_SPECTRUM_ENABLED and not audioConfigWarned then
    audioConfigWarned = true
    noctalia.notifyError("Bongo Cat", "Set audio_spectrum = true to use rave_mode or tappy_mode.")
  end

  -- Nothing to step while the cat is down: the window was emptied on the way
  -- there and nothing counts into it until it wakes.
  if SHOW_WPM and not paused and not waiting then
    local vertical = barWidget.isVertical()
    local orientationChanged = vertical ~= isVertical
    isVertical = vertical
    advanceWpmWindow()
    -- Redrawing only when the number changes keeps this to the ticks that have
    -- something to say, rather than twenty renders a second.
    if orientationChanged or wpmLabel() ~= shownWpm then
      refreshDisplay()
    end
  end

  if beatCooldownTicks > 0 then
    beatCooldownTicks -= 1
    if beatCooldownTicks == 0 then
      syncTickRate()
    end
  end

  if raveFlashTicks > 0 then
    raveFlashTicks -= 1
    if raveFlashTicks == 0 then
      syncTickRate()
      refreshDisplay()
    end
  end

  if paused then return end

  -- Idle timeout: return paws to rest
  if catState ~= STATE_IDLE then
    idleTicks += 1
    if idleTicks >= IDLE_TICKS then
      catState = STATE_IDLE
      refreshDisplay()
    end
  end

  -- Waiting timeout: go to sleep
  if not waiting then
    waitingTicks += 1
    if waitingTicks >= WAITING_TICKS then
      waiting = true
      blinking = false
      if SHOW_WPM then
        resetWpmWindow()
      end
      syncTickRate()
      refreshDisplay()
    end
  end

  -- Blink logic (only when awake and idle)
  if not waiting and catState == STATE_IDLE then
    if blinking then
      blinkDuration += 1
      if blinkDuration >= BLINK_DURATION then
        blinking = false
        blinkDuration = 0
        nextBlinkIn = randomBlinkDelay()
        refreshDisplay()
      end
    else
      nextBlinkIn -= 1
      if nextBlinkIn <= 0 then
        blinking = true
        blinkDuration = 0
        refreshDisplay()
      end
    end
  end
end

function onAudioSpectrum(valuesCsv, stateCsv)
  if paused then return end
  if not RAVE_MODE and not TAPPY_MODE then return end

  local audioActive, mprisPlaying = parseAudioState(stateCsv)
  if not audioActive then
    audioIntensity = 0
    return
  end
  if USE_MPRIS_FILTER and not mprisPlaying then
    return
  end

  local values = parseCsvNumbers(valuesCsv)
  if #values == 0 then
    audioIntensity = 0
    return
  end

  local subBassCount = math.clamp(#values, 1, 4)
  local bassCount = math.clamp(#values, 1, 8)
  local midCount = math.clamp(#values, 9, 16)
  local subBassAvg = average(values, 1, subBassCount)
  local bassAvg = average(values, 1, bassCount)
  local midAvg = average(values, 9, midCount)

  bassIntensity = subBassAvg
  audioIntensity = (bassAvg * 0.8) + (midAvg * 0.6)

  local alpha = 0.75
  previousIntensity = smoothedIntensity
  smoothedIntensity = alpha * audioIntensity + (1 - alpha) * smoothedIntensity

  local intensityDelta = smoothedIntensity - previousIntensity
  local isBeat = (intensityDelta > beatDeltaThreshold and smoothedIntensity > beatThreshold * 0.5)
      or (smoothedIntensity > beatThreshold and intensityDelta > 0)

  if isBeat and beatCooldownTicks <= 0 then
    if RAVE_MODE then
      rainbowIndex = (rainbowIndex % #rainbowColors) + 1
      raveFlashTicks = 2
      refreshDisplay()
    end

    if TAPPY_MODE then
      onBeatTap(bassIntensity > bigBeatThreshold)
    end

    beatCooldownTicks = 2
    -- The flash and the cooldown are counted in ticks, so a sleeping cat has to
    -- come back up to speed for them to run out on time.
    syncTickRate()
  end
end

function onClick()
  paused = not paused
  if not paused then
    waitingTicks = 0
    waiting = false
    catState = STATE_IDLE
  elseif SHOW_WPM then
    resetWpmWindow()
  end
  syncTickRate()
  refreshDisplay()
end

function onIpc(event, payload)
  if event == "pause" then
    paused = true
    if SHOW_WPM then
      resetWpmWindow()
    end
    syncTickRate()
    refreshDisplay()
  elseif event == "resume" then
    paused = false
    waiting = false
    waitingTicks = 0
    catState = STATE_IDLE
    syncTickRate()
    refreshDisplay()
  elseif event == "toggle" then
    paused = not paused
    if not paused then
      waiting = false
      waitingTicks = 0
      catState = STATE_IDLE
    elseif SHOW_WPM then
      resetWpmWindow()
    end
    syncTickRate()
    refreshDisplay()
  end
end
