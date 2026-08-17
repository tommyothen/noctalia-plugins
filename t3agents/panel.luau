--!nonstrict
-- T3 Agents — dashboard.
--
-- A pure view over the three state keys the service publishes: "limits" (how much
-- of each subscription window is spent), "snapshot" (live threads, their running
-- subagents, per-thread context occupancy) and "sessions" (Claude Code sessions
-- started by hand, outside t3). It reads no file and spawns no process.
--
-- Re-rendering is gated on a fingerprint of exactly the fields drawn below. The
-- fast loop republishes a snapshot every second or two and an unconditional
-- render would reset the scroll position out from under whoever is reading it.
--
-- Note: Noctalia plugin entries are sandboxed and the relative-require story is
-- not settled across API levels, so the small formatting helpers are duplicated
-- from widget.luau rather than shared.

local ROW_GAP = 12
local CARD_RADIUS = 12
local CARD_PADDING = 10
local BAR_HEIGHT = 6

local SMALL_BAR_HEIGHT = 4

-- Above this fraction of the context window, the occupancy bar turns red: past
-- roughly this point a long turn is one tool result away from a compaction.
local CONTEXT_ALARM = 0.9

-- Where a subscription window stops being background information. Providers can
-- supply a severity; the percentage thresholds cover unknown values.
local LIMIT_WARN_PCT = 70
local LIMIT_ALARM_PCT = 90
local SEVERITY_ELEVATED = { warning = true, elevated = true, mid = true }
local SEVERITY_CRITICAL = { critical = true, exceeded = true, exhausted = true, blocked = true, high = true }

-- Remote threads come off a cache that only moves while the t3-code app runs. Past
-- this age since an environment's newest thread was touched, its subheader carries
-- a "last seen" hint, so a frozen cache reads as frozen rather than as live.
local REMOTE_STALE_S = 300

local lastFingerprint = nil

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- ==============================================================================
-- ── FORMATTING ─────────────────────────────────────────────────────────────
-- ==============================================================================

-- State crosses a serialisation boundary on its way here, so nothing is assumed
-- to have survived as the string the service published.
local function text(value, fallback)
  if type(value) == "string" and value ~= "" then return value end
  return fallback
end

local function compact(n)
  n = tonumber(n) or 0
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 10000 then return string.format("%.0fk", n / 1000) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

local function nowS()
  return math.floor(noctalia.nowMs() / 1000)
end

local function ago(epochSeconds, now)
  local seconds = tonumber(epochSeconds) or 0
  if seconds <= 0 then return "" end
  local delta = now - seconds
  if delta < 45 then return tr("time.now") end
  if delta < 3600 then return tr("time.minutes", { n = math.floor(delta / 60) }) end
  if delta < 86400 then return tr("time.hours", { n = math.floor(delta / 3600) }) end
  return tr("time.days", { n = math.floor(delta / 86400) })
end

-- Two units at most, and never the smaller one when the larger makes it noise:
-- what a countdown is for is deciding whether to start something now.
local function countdown(epochSeconds, now)
  local delta = (tonumber(epochSeconds) or 0) - now
  if delta <= 0 then return tr("limits.reset_due") end
  if delta < 3600 then return tr("time.in_minutes", { m = math.floor(delta / 60) }) end
  if delta < 86400 then
    return tr("time.in_hours", { h = math.floor(delta / 3600), m = math.floor((delta % 3600) / 60) })
  end
  return tr("time.in_days", { d = math.floor(delta / 86400), h = math.floor((delta % 86400) / 3600) })
end

local function percent(value)
  return string.format("%d%%", math.floor((tonumber(value) or 0) + 0.5))
end

local function limitColor(pct, severity, stale)
  if stale then return "on_surface_variant" end
  if SEVERITY_CRITICAL[severity] then return "error" end
  if SEVERITY_ELEVATED[severity] then return "tertiary" end
  pct = tonumber(pct) or 0
  if pct >= LIMIT_ALARM_PCT then return "error" end
  if pct >= LIMIT_WARN_PCT then return "tertiary" end
  return "primary"
end

local function basename(path)
  if type(path) ~= "string" or path == "" then return "" end
  return path:match("([^/]+)/?$") or path
end

local function statusColor(status)
  if status == "running" or status == "starting" then return "primary" end
  if status == "error" then return "error" end
  return "on_surface_variant"
end

-- t3 can grow a status this plugin has never heard of. Showing the raw token
-- beats showing a missing translation key.
local KNOWN_STATUS = {
  idle = true, starting = true, running = true, ready = true,
  interrupted = true, stopped = true, error = true,
}

local function statusLabel(status)
  if type(status) ~= "string" or status == "" then return tr("status.idle") end
  if KNOWN_STATUS[status] then return tr("status." .. status) end
  return status
end

-- ==============================================================================
-- ── STATE ──────────────────────────────────────────────────────────────────
-- ==============================================================================

local function snapshot()
  local snap = noctalia.state.get("snapshot")
  if type(snap) ~= "table" then
    return { t3Running = false, threads = {}, agents = {}, contextByThread = {}, errorBanner = "", schemaNote = "" }
  end
  return {
    t3Running = snap.t3Running == true,
    threads = type(snap.threads) == "table" and snap.threads or {},
    agents = type(snap.agents) == "table" and snap.agents or {},
    contextByThread = type(snap.contextByThread) == "table" and snap.contextByThread or {},
    errorBanner = type(snap.errorBanner) == "string" and snap.errorBanner or "",
    schemaNote = type(snap.schemaNote) == "string" and snap.schemaNote or "",
  }
end

local function sessions()
  local data = noctalia.state.get("sessions")
  if type(data) ~= "table" then return { standalone = {} } end
  return { standalone = type(data.standalone) == "table" and data.standalone or {} }
end

local function remote()
  local data = noctalia.state.get("remote")
  if type(data) ~= "table" then return { environments = {} } end
  return { environments = type(data.environments) == "table" and data.environments or {} }
end

local function remoteThreadCount(rem)
  local count = 0
  for _, env in ipairs(rem.environments) do
    if type(env.threads) == "table" then count += #env.threads end
  end
  return count
end

local function limits()
  local data = noctalia.state.get("limits")
  if type(data) ~= "table" or data.available ~= true then
    return { available = false, stale = false, at = 0, providers = {} }
  end
  return {
    available = true,
    stale = data.stale == true,
    at = tonumber(data.at) or 0,
    providers = type(data.providers) == "table" and data.providers or {},
  }
end

local function limitPart(window)
  if type(window) ~= "table" then return "" end
  return table.concat({
    tostring(tonumber(window.pct) or 0), tostring(window.resetsAt or 0), tostring(window.severity or ""),
  }, "\3")
end

-- Only the drawn fields, so a re-render tracks what is actually visible.
local function fingerprint(snap, sess, lim, rem)
  local parts = { tostring(snap.t3Running), snap.errorBanner, snap.schemaNote }
  for _, thread in ipairs(snap.threads) do
    local context = snap.contextByThread[thread.id]
    table.insert(parts, table.concat({
      thread.id, thread.title, thread.project, thread.branch, thread.status, thread.model,
      tostring(thread.approvals), tostring(thread.inputs), tostring(thread.updatedAt),
      tostring(context and context.used or 0), tostring(context and context.max or 0),
    }, "\2"))
  end
  for _, agent in ipairs(snap.agents) do
    table.insert(parts, table.concat({
      tostring(agent.taskId), tostring(agent.title), tostring(agent.detail),
      tostring(agent.tool), tostring(agent.tokens),
    }, "\2"))
  end
  for _, session in ipairs(sess.standalone) do
    table.insert(parts, table.concat({ tostring(session.pid), tostring(session.name) }, "\2"))
  end
  for _, env in ipairs(rem.environments) do
    table.insert(parts, table.concat({
      tostring(env.environmentId), tostring(env.name), tostring(env.newestUpdatedAt),
    }, "\6"))
    for _, thread in ipairs(env.threads) do
      table.insert(parts, table.concat({
        tostring(thread.id), tostring(thread.title), tostring(thread.project),
        tostring(thread.branch), tostring(thread.status), tostring(thread.model),
        tostring(thread.approvals), tostring(thread.inputs), tostring(thread.updatedAt),
      }, "\2"))
    end
  end
  for _, provider in ipairs(lim.providers) do
    local providerParts = {
      tostring(provider.id), tostring(provider.name), tostring(provider.plan),
    }
    if type(provider.windows) == "table" then
      for _, window in ipairs(provider.windows) do
        table.insert(providerParts, tostring(window.label or "") .. "\4" .. limitPart(window))
      end
    end
    if type(provider.blocks) == "table" then
      for _, block in ipairs(provider.blocks) do
        local first = type(block.lines) == "table" and block.lines[1] or ""
        table.insert(providerParts, tostring(block.label or "") .. "\4" .. tostring(first or ""))
      end
    end
    table.insert(parts, table.concat(providerParts, "\5"))
  end
  table.insert(parts, table.concat({ tostring(lim.stale), tostring(lim.at) }, "\2"))
  return table.concat(parts, "\1")
end

-- ==============================================================================
-- ── PIECES ─────────────────────────────────────────────────────────────────
-- ==============================================================================

local function pill(text, role)
  return ui.row({ fill = role .. "/0.20", radius = 8, paddingH = 6, paddingV = 2, align = "center" }, {
    ui.label({ text = text, fontSize = 10, color = role }),
  })
end

local function sectionHeader(glyph, text, trailing)
  local children = {
    ui.glyph({ name = glyph, size = 13, color = "on_surface_variant" }),
    ui.label({ text = text, fontSize = 12, fontWeight = "bold", color = "on_surface_variant", flexGrow = 1 }),
  }
  if trailing ~= nil and trailing ~= "" then
    table.insert(children, ui.label({ text = trailing, fontSize = 11, color = "on_surface_variant" }))
  end
  return ui.row({ gap = 6, align = "center" }, children)
end

local function dimLine(text)
  return ui.label({ text = text, fontSize = 11, color = "on_surface_variant" })
end

local function threadCard(thread, context, now)
  local head = {
    ui.glyph({ name = "folder", size = 12, color = "on_surface_variant" }),
    ui.label({
      text = text(thread.project, tr("panel.untitled_project")),
      fontSize = 12, fontWeight = "bold", color = "on_surface", maxLines = 1, flexGrow = 1,
    }),
    pill(statusLabel(thread.status), statusColor(thread.status)),
  }

  local rows = {
    ui.row({ gap = 6, align = "center" }, head),
    ui.label({
      text = text(thread.title, tr("panel.untitled_thread")),
      fontSize = 12, color = "on_surface", maxLines = 1,
    }),
  }

  local meta = {}
  if type(thread.branch) == "string" and thread.branch ~= "" then
    table.insert(meta, ui.glyph({ name = "git-branch", size = 11, color = "on_surface_variant" }))
    table.insert(meta, ui.label({ text = thread.branch, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
  end
  if type(thread.model) == "string" and thread.model ~= "" then
    table.insert(meta, ui.label({ text = thread.model, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }))
  end
  table.insert(meta, ui.label({ text = ago(thread.updatedAt, now), fontSize = 11, color = "on_surface_variant" }))
  table.insert(rows, ui.row({ gap = 6, align = "center" }, meta))

  if context ~= nil then
    local used = tonumber(context.used) or 0
    local max = tonumber(context.max) or 0
    if max > 0 then
      local fraction = used / max
      if fraction > 1 then fraction = 1 end
      table.insert(rows, ui.row({ gap = 8, align = "center" }, {
        ui.progress({
          progress = fraction,
          fill = fraction >= CONTEXT_ALARM and "error" or "primary",
          height = BAR_HEIGHT,
          radius = BAR_HEIGHT / 2,
          flexGrow = 1,
        }),
        ui.label({
          text = compact(used) .. " / " .. compact(max),
          fontSize = 11,
          color = fraction >= CONTEXT_ALARM and "error" or "on_surface_variant",
        }),
      }))
    end
  end

  local waiting = (tonumber(thread.approvals) or 0) + (tonumber(thread.inputs) or 0)
  if waiting > 0 then
    table.insert(rows, ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 12, color = "error" }),
      ui.label({ text = tr("panel.waiting", { n = waiting }), fontSize = 11, color = "error" }),
    }))
  end

  return ui.column({
    key = "thread-" .. tostring(thread.id),
    gap = 6,
    align = "stretch",
    fill = "surface_variant",
    radius = CARD_RADIUS,
    padding = CARD_PADDING,
  }, rows)
end

-- A remote environment's subheader: the name the user gave it (or a short id),
-- the count under it, and a "last seen" age when the cache behind it has stopped
-- moving. Subtler than a section header, so the cards below still read as threads.
local function remoteHeader(env, now)
  local children = {
    ui.glyph({ name = "cloud", size = 12, color = "on_surface_variant" }),
    ui.label({
      text = text(env.name, ""),
      fontSize = 11, fontWeight = "bold", color = "on_surface_variant", maxLines = 1, flexGrow = 1,
    }),
  }
  local newest = tonumber(env.newestUpdatedAt) or 0
  if newest > 0 and (now - newest) > REMOTE_STALE_S then
    table.insert(children, ui.label({
      text = tr("panel.remote_last_seen", { age = ago(newest, now) }),
      fontSize = 10, color = "on_surface_variant",
    }))
  end
  table.insert(children, ui.label({ text = tostring(#env.threads), fontSize = 11, color = "on_surface_variant" }))
  return ui.row({ key = "renv-" .. tostring(env.environmentId), gap = 6, align = "center" }, children)
end

local function agentRow(agent)
  local detail = text(agent.detail, "")
  local tool = text(agent.tool, "")

  local footer = {}
  if detail ~= "" then
    table.insert(footer, ui.label({ text = detail, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }))
  else
    table.insert(footer, ui.spacer({ flexGrow = 1 }))
  end
  if tool ~= "" then
    table.insert(footer, ui.glyph({ name = "tool", size = 11, color = "on_surface_variant" }))
    table.insert(footer, ui.label({ text = tool, fontSize = 11, color = "on_surface_variant" }))
  end

  return ui.column({ key = "agent-" .. tostring(agent.taskId), gap = 2, align = "stretch" }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "subtask", size = 12, color = "primary" }),
      ui.label({
        text = text(agent.title, tr("panel.untitled_agent")),
        fontSize = 12, color = "on_surface", maxLines = 1, flexGrow = 1,
      }),
      ui.label({ text = compact(agent.tokens), fontSize = 11, color = "on_surface_variant" }),
    }),
    ui.row({ gap = 6, align = "center" }, footer),
  })
end

local function limitBar(pct, color, height)
  local fraction = (tonumber(pct) or 0) / 100
  if fraction < 0 then fraction = 0 end
  if fraction > 1 then fraction = 1 end
  return ui.progress({
    progress = fraction,
    fill = color,
    height = height,
    radius = height / 2,
    flexGrow = 1,
  })
end

-- A secondary window: named, thinner, and otherwise the primary bar's twin. Every
-- window under a provider's headline one is drawn this way, whether it is a
-- longer period or a single model's own ceiling.
local function smallLimitRow(label, window, stale)
  local pct = tonumber(window.pct) or 0
  local color = limitColor(pct, window.severity, stale)
  return ui.row({ gap = 6, align = "center" }, {
    -- Fixed-width wrapper so every small bar starts at the same x. Width is a
    -- container prop, not a label one.
    ui.row({ width = 64, align = "center" }, {
      ui.label({ text = label, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
    }),
    limitBar(pct, color, SMALL_BAR_HEIGHT),
    ui.label({ text = percent(pct), fontSize = 10, color = color }),
  })
end

local function providerTitle(name, plan)
  if type(plan) ~= "string" or plan == "" then return name end
  return tr("limits.provider_plan", { name = name, plan = plan:sub(1, 1):upper() .. plan:sub(2) })
end

-- One provider: the first window as a bar, then its remaining windows and blocks.
local function limitCard(key, name, window, sublabel, extras, stale, at, now)
  local pct = tonumber(window.pct) or 0
  local color = limitColor(pct, window.severity, stale)

  local head = {
    ui.label({
      text = name, fontSize = 12, fontWeight = "bold",
      color = stale and "on_surface_variant" or "on_surface", maxLines = 1,
    }),
  }
  if sublabel ~= "" then
    table.insert(head, ui.label({ text = sublabel, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
  end
  table.insert(head, ui.spacer({ flexGrow = 1 }))
  if (tonumber(window.resetsAt) or 0) > 0 then
    table.insert(head, ui.label({
      text = tr("limits.resets_in", { time = countdown(window.resetsAt, now) }),
      fontSize = 11, color = "on_surface_variant",
    }))
  end
  table.insert(head, ui.label({ text = percent(pct), fontSize = 12, fontWeight = "bold", color = color }))

  local rows = {
    ui.row({ gap = 6, align = "center" }, head),
    ui.row({ gap = 8, align = "center" }, { limitBar(pct, color, BAR_HEIGHT) }),
  }
  for _, extra in ipairs(extras) do
    table.insert(rows, extra)
  end
  if stale and (tonumber(at) or 0) > 0 then
    table.insert(rows, ui.label({ text = tr("limits.stale", { age = ago(at, now) }), fontSize = 10, color = "on_surface_variant" }))
  end

  return ui.column({ key = key, gap = 4, align = "stretch" }, rows)
end

local function providerCard(provider, now, stale, at)
  local primary = type(provider.windows) == "table" and provider.windows[1] or nil
  if type(primary) ~= "table" then return nil end
  local extras = {}
  for i = 2, #provider.windows do
    local window = provider.windows[i]
    if type(window) == "table" then
      table.insert(extras, smallLimitRow(text(window.label, ""), window, stale))
    end
  end
  if type(provider.blocks) == "table" then
    for _, block in ipairs(provider.blocks) do
      local first = type(block.lines) == "table" and block.lines[1] or nil
      if type(first) == "string" and first ~= "" then
        first = first:gsub("(%d+%.%d%d)%d+", "%1")
        local label = type(block.label) == "string" and block.label or ""
        table.insert(extras, ui.row({ gap = 6, align = "center" }, {
          ui.glyph({ name = label == "Credits" and "coin" or "info-circle", size = 11, color = "on_surface_variant" }),
          ui.label({ text = label .. ": " .. first, fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
        }))
      end
    end
  end

  return limitCard("limit-" .. tostring(provider.id), providerTitle(text(provider.name, tostring(provider.id)), provider.plan),
    primary, text(primary.label, ""), extras, stale, at, now)
end

local function sessionRow(session, now)
  local title = text(session.name, tr("panel.untitled_session"))
  local where = basename(session.cwd)
  return ui.row({ key = "session-" .. tostring(session.pid), gap = 6, align = "center" }, {
    ui.glyph({ name = "terminal-2", size = 12, color = "on_surface_variant" }),
    ui.label({ text = title, fontSize = 12, color = "on_surface", maxLines = 1 }),
    ui.label({ text = where, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
    ui.label({ text = ago(session.startedAt, now), fontSize = 11, color = "on_surface_variant" }),
  })
end

-- ==============================================================================
-- ── RENDER ─────────────────────────────────────────────────────────────────
-- ==============================================================================

local function render()
  local snap = snapshot()
  local sess = sessions()
  local lim = limits()
  local rem = remote()
  local now = nowS()
  local remoteCount = remoteThreadCount(rem)
  local hasRemote = remoteCount > 0

  -- The header is the title and a close button. The plan the account is on says
  -- more sitting on the row that spends it, so that is where it lives.
  local headerChildren = {
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    ui.button({ glyph = "x", variant = "ghost", onClick = "onCloseClicked" }),
  }

  local body = {}

  -- Subscription windows go first: they are the one thing on this panel that
  -- decides whether the work below it can happen at all. A provider that is not
  -- available contributes nothing, and no cards means no section.
  local limitCards = {}
  for _, provider in ipairs(lim.providers) do
    local card = providerCard(provider, now, lim.stale, lim.at)
    if card ~= nil then table.insert(limitCards, card) end
  end
  if #limitCards > 0 then
    table.insert(body, sectionHeader("gauge", tr("panel.limits"), ""))
    for _, card in ipairs(limitCards) do
      table.insert(body, card)
    end
  end

  if snap.errorBanner ~= "" then
    table.insert(body, ui.row({
      key = "banner", gap = 6, align = "center", fill = "error/0.15",
      radius = 8, paddingH = 8, paddingV = 6,
    }, {
      ui.glyph({ name = "alert-circle", size = 13, color = "error" }),
      ui.label({ text = snap.errorBanner, fontSize = 11, color = "error", flexGrow = 1 }),
    }))
  end
  if snap.schemaNote ~= "" then
    table.insert(body, dimLine(snap.schemaNote))
  end

  -- The big "not running" block only takes over when there is genuinely nothing
  -- to show. Remote threads live in a cache that outlives the local server, so
  -- when any are present the Threads section stands and the down state shrinks to
  -- one inline line above them.
  if not snap.t3Running and not hasRemote then
    table.insert(body, ui.column({ key = "down", gap = 8, align = "center", padding = 24 }, {
      ui.glyph({ name = "plug-off", size = 28, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.t3_down"), fontSize = 12, color = "on_surface_variant", textAlign = "center" }),
    }))
  else
    -- One count over both machines and the cloud, so the header matches the cards
    -- under it whether they are local, remote, or both.
    table.insert(body, sectionHeader("sitemap", tr("panel.threads"), tostring(#snap.threads + remoteCount)))
    if snap.t3Running then
      if #snap.threads == 0 and not hasRemote then
        table.insert(body, dimLine(tr("panel.no_threads")))
      else
        for _, thread in ipairs(snap.threads) do
          table.insert(body, threadCard(thread, snap.contextByThread[thread.id], now))
        end
      end
    else
      table.insert(body, dimLine(tr("panel.t3_down")))
    end

    -- Remote environments, each under its own subheader. threadCard renders them
    -- exactly as local ones minus the context bar, which is not cached for remote.
    for _, env in ipairs(rem.environments) do
      table.insert(body, remoteHeader(env, now))
      for _, thread in ipairs(env.threads) do
        table.insert(body, threadCard(thread, nil, now))
      end
    end

    -- Active agents stays local: remote carries no subagent detail to show here.
    if snap.t3Running then
      table.insert(body, sectionHeader("robot", tr("panel.agents"), tostring(#snap.agents)))
      if #snap.agents == 0 then
        table.insert(body, dimLine(tr("panel.no_agents")))
      else
        for _, agent in ipairs(snap.agents) do
          table.insert(body, agentRow(agent))
        end
      end
    end
  end

  if #sess.standalone > 0 then
    table.insert(body, sectionHeader("terminal-2", tr("panel.standalone"), tostring(#sess.standalone)))
    for _, session in ipairs(sess.standalone) do
      table.insert(body, sessionRow(session, now))
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = ROW_GAP, align = "stretch" }, {
    ui.row({ gap = 8, align = "center", justify = "space_between" }, headerChildren),
    ui.scroll({ flexGrow = 1, gap = ROW_GAP }, body),
  }))
end

-- ==============================================================================
-- ── CALLBACKS ──────────────────────────────────────────────────────────────
-- ==============================================================================

local function renderIfChanged()
  local fp = fingerprint(snapshot(), sessions(), limits(), remote())
  if fp ~= lastFingerprint then
    lastFingerprint = fp
    render()
  end
end

function onOpen(_context)
  panel.setWantsSecondTicks(true) -- the host stops ticks on close and re-arms on reopen
  lastFingerprint = fingerprint(snapshot(), sessions(), limits(), remote())
  render()
end

function update()
  renderIfChanged()
end

function onCloseClicked()
  panel.close()
end

noctalia.state.watch("snapshot", function(_)
  renderIfChanged()
end)

noctalia.state.watch("sessions", function(_)
  renderIfChanged()
end)

noctalia.state.watch("limits", function(_)
  renderIfChanged()
end)

noctalia.state.watch("remote", function(_)
  renderIfChanged()
end)
