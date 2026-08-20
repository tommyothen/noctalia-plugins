--!nonstrict
-- LibrePods: status and control panel.
--
-- A pure view over the "snapshot" the service publishes; it reads no file and
-- spawns no process. Controls go back through the shared "command" state key,
-- and the service re-polls the moment a command returns, so the highlighted
-- mode catches up in one round trip.
--
-- Re-rendering is gated on a fingerprint of exactly the fields drawn below,
-- because the service republishes on every device event and an unconditional
-- render would rebuild the tree for nothing.

local ROW_GAP = 10
local BAR_HEIGHT = 6

-- Below this a component's bar and figure turn red; the same threshold as the
-- widget, so the panel never contradicts the tile that opened it.
local LOW_PCT = 20

-- Case first would mirror the JSON, but left/right/case is how the components
-- sit in your head; anything unexpected keeps its file order after these.
local COMPONENT_ORDER = { left = 1, right = 2, headphone = 3, case = 4 }

local lastFingerprint = nil
local nonce = 0

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- The daemon can grow a component, mode or ear state this plugin has never
-- heard of; show the raw token rather than a missing translation key.
local KNOWN_COMPONENTS = { left = true, right = true, case = true, headphone = true }
local KNOWN_MODES = { off = true, noise_cancellation = true, transparency = true, adaptive = true }
local KNOWN_EAR = { in_ear = true, out_of_ear = true, in_case = true, disconnected = true }

local function componentLabel(component)
  if KNOWN_COMPONENTS[component] then return tr("component." .. component) end
  return component
end

local function modeLabel(mode)
  if KNOWN_MODES[mode] then return tr("mode." .. mode) end
  return mode
end

local function earLabel(state)
  if KNOWN_EAR[state] then return tr("ear." .. state) end
  return state
end

-- ==============================================================================
-- ── STATE ──────────────────────────────────────────────────────────────────
-- ==============================================================================

local function snapshot()
  local snap = noctalia.state.get("snapshot")
  if type(snap) ~= "table" then
    return { daemonRunning = false, connected = false, name = "", battery = {},
      earDetection = {}, mode = "", allowedModes = {}, conversationAwareness = nil }
  end
  return {
    daemonRunning = snap.daemonRunning == true,
    connected = snap.connected == true,
    name = type(snap.name) == "string" and snap.name or "",
    battery = type(snap.battery) == "table" and snap.battery or {},
    earDetection = type(snap.earDetection) == "table" and snap.earDetection or {},
    mode = type(snap.mode) == "string" and snap.mode or "",
    allowedModes = type(snap.allowedModes) == "table" and snap.allowedModes or {},
    conversationAwareness = type(snap.conversationAwareness) == "boolean"
      and snap.conversationAwareness or nil,
  }
end

-- Only the drawn fields, so a re-render tracks what is actually visible.
local function fingerprint(snap)
  local parts = {
    tostring(snap.daemonRunning), tostring(snap.connected), snap.name, snap.mode,
    tostring(snap.conversationAwareness),
    table.concat(snap.allowedModes, ","),
  }
  for _, state in ipairs(snap.earDetection) do
    table.insert(parts, tostring(state))
  end
  for _, entry in ipairs(snap.battery) do
    table.insert(parts, table.concat({
      tostring(entry.component), tostring(entry.level),
      tostring(entry.charging), tostring(entry.connected),
    }, "\2"))
  end
  return table.concat(parts, "\1")
end

-- The nonce is what makes a second identical command a distinct value, so the
-- service's watch actually fires for it.
local function send(command)
  nonce += 1
  command.nonce = `panel-{nonce}`
  noctalia.state.set("command", command)
end

-- ==============================================================================
-- ── PIECES ─────────────────────────────────────────────────────────────────
-- ==============================================================================

local function dimLine(text)
  return ui.label({ text = text, fontSize = 12, color = "on_surface_variant" })
end

local function batteryRow(entry)
  local low = entry.level <= LOW_PCT and not entry.charging
  local color = low and "error" or "primary"

  local children = {
    -- Fixed-width wrapper so every bar starts at the same x. Width is a
    -- container prop, not a label one.
    ui.row({ width = 64, align = "center" }, {
      ui.label({ text = componentLabel(entry.component), fontSize = 12, color = "on_surface", maxLines = 1 }),
    }),
    ui.progress({
      progress = math.clamp(entry.level / 100, 0, 1),
      fill = color,
      height = BAR_HEIGHT,
      radius = BAR_HEIGHT / 2,
      flexGrow = 1,
    }),
    ui.label({ text = `{entry.level}%`, fontSize = 12, color = low and "error" or "on_surface" }),
  }
  if entry.charging then
    table.insert(children, ui.glyph({ name = "bolt", size = 12, color = "primary" }))
  end
  return ui.row({ key = "battery-" .. tostring(entry.component), gap = 8, align = "center" }, children)
end

-- The selector is built from what this device actually allows, so a model
-- without Adaptive simply never shows the segment.
local function modeSelector(snap)
  local segments = {}
  for _, mode in ipairs(snap.allowedModes) do
    table.insert(segments, ui.button({
      key = "mode-" .. tostring(mode),
      text = modeLabel(mode),
      variant = mode == snap.mode and "primary" or "outline",
      onClick = function()
        send({ action = "anc", mode = mode })
      end,
      flexGrow = 1,
    }))
  end
  return ui.row({ key = "modes", gap = 6, align = "center" }, segments)
end

-- ==============================================================================
-- ── RENDER ─────────────────────────────────────────────────────────────────
-- ==============================================================================

local function render()
  local snap = snapshot()

  local body = {}

  if not snap.daemonRunning then
    table.insert(body, dimLine(tr("panel.daemon_down")))
  elseif not snap.connected then
    table.insert(body, dimLine(tr("panel.disconnected")))
  else
    table.insert(body, ui.row({ gap = 8, align = "center" }, {
      ui.label({
        text = snap.name ~= "" and snap.name or tr("title"),
        fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 1, flexGrow = 1,
      }),
      ui.label({ text = tr("panel.connected"), fontSize = 11, color = "on_surface_variant" }),
    }))

    -- Left, right, then case; a component the device reports as disconnected
    -- (an empty case, a bud left at home) contributes no row.
    local entries = {}
    for _, entry in ipairs(snap.battery) do
      if entry.connected then table.insert(entries, entry) end
    end
    table.sort(entries, function(a, b)
      return (COMPONENT_ORDER[a.component] or 9) < (COMPONENT_ORDER[b.component] or 9)
    end)
    for _, entry in ipairs(entries) do
      table.insert(body, batteryRow(entry))
    end

    if #snap.allowedModes > 0 then
      table.insert(body, modeSelector(snap))
    end

    -- Hidden rather than guessed while the daemon has not read the flag off the
    -- device yet: a toggle showing a made-up state invites a wrong click.
    if snap.conversationAwareness ~= nil then
      table.insert(body, ui.row({ key = "ca", gap = 8, align = "center" }, {
        ui.label({
          text = tr("panel.conversation_awareness"),
          fontSize = 12, color = "on_surface", flexGrow = 1,
        }),
        ui.toggle({ checked = snap.conversationAwareness, onChange = "onConversationToggle" }),
      }))
    end

    if #snap.earDetection > 0 then
      local states = {}
      for _, state in ipairs(snap.earDetection) do
        table.insert(states, earLabel(state))
      end
      table.insert(body, ui.row({ key = "ears", gap = 6, align = "center" }, {
        ui.glyph({ name = "ear", size = 12, color = "on_surface_variant" }),
        ui.label({
          text = table.concat(states, " · "),
          fontSize = 11, color = "on_surface_variant", maxLines = 1,
        }),
      }))
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = ROW_GAP, align = "stretch" }, {
    ui.row({ gap = 8, align = "center", justify = "space_between" }, {
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.column({ flexGrow = 1, gap = ROW_GAP, align = "stretch" }, body),
  }))
end

-- ==============================================================================
-- ── CALLBACKS ──────────────────────────────────────────────────────────────
-- ==============================================================================

local function renderIfChanged()
  local fp = fingerprint(snapshot())
  if fp ~= lastFingerprint then
    lastFingerprint = fp
    render()
  end
end

function onConversationToggle(value)
  send({ action = "ca", on = value == "true" })
end

function onCloseClicked()
  panel.close()
end

function onOpen(_context)
  panel.setWantsSecondTicks(true) -- the host stops ticks on close and re-arms on reopen
  -- Opening is also the moment stale data hurts most, so ask for a fresh read.
  send({ action = "refresh" })
  lastFingerprint = fingerprint(snapshot())
  render()
end

function update()
  renderIfChanged()
end

noctalia.state.watch("snapshot", function(_)
  renderIfChanged()
end)
