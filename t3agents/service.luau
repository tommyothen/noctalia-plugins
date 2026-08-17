--!nonstrict
-- T3 Agents — headless collector.
--
-- The only entry that touches disk. Four loops share one update() tick:
--
--   fast (poll_interval_ms)  gate file + one sqlite3 call -> state "snapshot"
--   sessions (30 s)          one /bin/sh scan of ~/.claude/sessions -> state "sessions"
--   remote (remote_poll_s)   copy of the t3-code IndexedDB cache -> state "remote"
--   limits (on demand)       one ai-usagebar read          -> state "limits"
--
-- The limit loop has no cadence of its own. What moves a subscription
-- window is work finishing, so the fast loop's own diff is the trigger: a thread
-- that stopped running or a subagent that is gone asks every provider again, no
-- more often than limits_gap_s. An idle machine makes no calls at all.
--
-- The fast loop reads t3-code's projection database over a `mode=ro` URI, so it
-- can never take a write lock or checkpoint the WAL out from under the server.
-- All five things it wants — threads, live subagents, per-thread context window,
-- the provider session ids, the migration level — come back as a single JSON
-- document from one process, because five sqlite3 spawns a second is a cost with
-- no payoff.
--
-- The session loop is a shell script rather than Luau because what it wants is a
-- pid check per file: a Claude session file outlives the process that wrote it,
-- and only /proc says which ones are still alive.
--
-- The remote loop is the only one that reads another machine's work. t3-code
-- caches each t3-connect environment's thread state as plaintext JSON in its
-- Electron IndexedDB, and this machine's cache holds the environments it is
-- connected to. The app keeps a POSIX lock on the store, so the loop copies the
-- directory to a scratch dir and reads the copy — a plain file read needs no
-- lock. A shipped remote_threads.py does the carve (a Luau callback has a CPU
-- budget and this is a multi-file text parse) and hands back a small JSON summary
-- of the remote environments' threads. This is thread-level data only: there is
-- no subagent detail cached for remote, so remote threads reach state "remote"
-- and the Threads section, never the Active agents one. Nothing under the cache
-- but the plaintext snapshot is read, and the scratch copy is always removed.
--
-- The limit loop delegates provider access to ai-usagebar. That CLI owns every
-- credential and its 60-second on-disk response cache; this plugin receives only
-- display-ready usage data and never reads or stores a token.
--
-- Nothing here is fatal. A missing gate file publishes t3Running = false and the
-- session scan carries on; a SQL failure becomes an errorBanner the panel renders;
-- a provider that cannot be reached keeps its last answer with a stale flag, and
-- a missing ai-usagebar binary leaves the limits section hidden.

-- ==============================================================================
-- ── CONSTANTS ──────────────────────────────────────────────────────────────
-- ==============================================================================

local HOME = noctalia.getenv("HOME") or ""
local T3_USERDATA = HOME .. "/.t3/userdata"
local RUNTIME_FILE = T3_USERDATA .. "/server-runtime.json"
local DB_FILE = T3_USERDATA .. "/state.sqlite"
local DB_URI = "file:" .. DB_FILE .. "?mode=ro"

-- The projection database runs in WAL mode: a write lands in the -wal sidecar and
-- only reaches state.sqlite at a checkpoint, so "did anything happen" is a question
-- about both files.
local DB_STAMP_FILES = { DB_FILE, DB_FILE .. "-wal" }

-- t3-code's IndexedDB thread cache: the store the remote loop copies and reads,
-- and the file naming this machine's own environment so the rest count as remote.
-- The paths are derived inside the shell script from $HOME as well, so nothing
-- crosses in on a command line.
local REMOTE_DIR = HOME .. "/.config/t3code/IndexedDB/t3code_app_0.indexeddb.leveldb"

-- Migration level this plugin's queries were written against. A different level
-- is not an error — the projections are additive in practice — but it is worth
-- saying out loud, because a renamed column shows up as empty sections rather
-- than as a crash.
local KNOWN_MIGRATION = 40

-- A subagent whose last task.progress row is older than this is treated as gone.
-- Progress rows are upserted on every tool use, so a live agent refreshes far
-- more often than this; the ceiling only exists to stop a task.completed that
-- never landed from pinning a ghost to the panel forever.
local AGENT_STALE_S = 1800

-- How often the hand-started Claude sessions are re-scanned. A session starts or
-- stops on a human timescale and the scan is a jq per file, so this is a fixed
-- constant rather than a setting.
local SESSIONS_REFRESH_S = 30

-- How long the fast loop will trust an unchanged database before querying anyway.
-- The stamp below is what normally decides, and it is exact; this only exists so a
-- filesystem whose mtimes lie (a coarse-granularity or network mount) still costs
-- one stale panel every half minute rather than forever.
local FAST_FORCE_S = 30

local FAST_TIMEOUT_MS = 5000
local SESSIONS_TIMEOUT_MS = 15000
local REMOTE_TIMEOUT_MS = 15000
local AIUB_TIMEOUT_MS = 30000

-- ==============================================================================
-- ── HELPERS ────────────────────────────────────────────────────────────────
-- ==============================================================================

local function cfg(key)
  return noctalia.getConfig(key)
end

-- Safely quotes strings for shell execution to prevent injection.
local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function intConfig(key, fallback, low, high)
  local value = tonumber(cfg(key))
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
-- ── QUERIES ────────────────────────────────────────────────────────────────
-- ==============================================================================

-- One statement, one row, one column: a JSON document holding everything the
-- fast loop needs. Timestamps are converted to epoch seconds here (the stored
-- form is ISO-8601 UTC) so no entry has to parse dates.
--
-- The `done` sub-select filters out NULL task ids deliberately: `x NOT IN (…)`
-- evaluates to NULL — never true — the moment the list contains a NULL, which
-- would silently empty the whole subagent section.
local SQL = [==[
SELECT json_object(
  'migration', (SELECT max(migration_id) FROM effect_sql_migrations),
  'threads', (SELECT json_group_array(json_object(
      'id', thread_id, 'title', title, 'project', project, 'root', workspace_root,
      'branch', branch, 'status', status, 'provider', provider_name,
      'model', model, 'approvals', approvals, 'inputs', inputs, 'updatedAt', updatedAt))
    FROM (
      SELECT t.thread_id AS thread_id, t.title AS title, p.title AS project,
             p.workspace_root AS workspace_root, t.branch AS branch,
             s.status AS status, s.provider_name AS provider_name,
             json_extract(t.model_selection_json, '$.model') AS model,
             t.pending_approval_count AS approvals,
             t.pending_user_input_count AS inputs,
             CAST(strftime('%s', replace(replace(t.updated_at, 'T', ' '), 'Z', '')) AS INTEGER) AS updatedAt
      FROM projection_threads t
      JOIN projection_projects p USING(project_id)
      LEFT JOIN projection_thread_sessions s USING(thread_id)
      WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
      ORDER BY t.updated_at DESC
      LIMIT 30)),
  'agents', (SELECT json_group_array(json_object(
      'threadId', thread_id, 'taskId', task_id, 'title', title, 'detail', detail,
      'model', model, 'role', role, 'tool', tool, 'tokens', tokens, 'at', at))
    FROM (
      WITH prog AS (
        SELECT thread_id,
               json_extract(payload_json, '$.taskId') AS task_id,
               json_extract(payload_json, '$.title') AS title,
               json_extract(payload_json, '$.detail') AS detail,
               json_extract(payload_json, '$.model') AS model,
               json_extract(payload_json, '$.role') AS role,
               json_extract(payload_json, '$.lastToolName') AS tool,
               json_extract(payload_json, '$.usage.total_tokens') AS tokens,
               CAST(strftime('%s', replace(replace(created_at, 'T', ' '), 'Z', '')) AS INTEGER) AS at,
               created_at AS created_at
        FROM projection_thread_activities
        WHERE activity_id LIKE 'task-progress:%'),
      done AS (
        SELECT DISTINCT json_extract(payload_json, '$.taskId') AS task_id
        FROM projection_thread_activities
        WHERE kind = 'task.completed' AND json_extract(payload_json, '$.taskId') IS NOT NULL)
      SELECT * FROM prog WHERE task_id NOT IN (SELECT task_id FROM done)
      ORDER BY created_at DESC
      LIMIT 30)),
  'context', (SELECT json_group_array(json_object(
      'threadId', thread_id, 'used', used, 'max', maxTokens))
    FROM (
      SELECT thread_id,
             max(created_at) AS newest,
             json_extract(payload_json, '$.usedTokens') AS used,
             json_extract(payload_json, '$.maxTokens') AS maxTokens
      FROM projection_thread_activities
      WHERE kind = 'context-window.updated'
      GROUP BY thread_id)),
  'resumes', (SELECT json_group_array(r) FROM (
      SELECT json_extract(resume_cursor_json, '$.resume') AS r
      FROM provider_session_runtime WHERE r IS NOT NULL))
) AS payload;
]==]

-- Hand-started Claude Code sessions, as one POSIX shell script. Nothing crosses
-- in: every path is derived from $HOME inside the script.
--
-- A session file outlives its process, and a pid is reused. /proc/<pid>/stat
-- field 22 is the process start time the file recorded as procStart, so matching
-- the two is the difference between "still running" and "some other program".
--
-- That match is one jq and no other process per file: jq reads the file once and
-- prints the pid and the recorded start on a first line and the row itself on a
-- second, /proc is read by the shell's own `read`, and the comparison is a string
-- test. Twenty files used to be sixty processes.
local SESSIONS_SCRIPT = [==[
CSESS="$HOME/.claude/sessions"

SESS=$(
  if [ -d "$CSESS" ]; then
    for f in $(ls -t "$CSESS"/*.json 2>/dev/null | head -20); do
      [ -f "$f" ] || continue
      jq -r '"\(.pid // "") \(.procStart // "")",
        ({ pid, sessionId, cwd, name, startedAt, kind } | tojson)' "$f" 2>/dev/null |
      {
        read -r PID PSTART || exit 0
        read -r ROW || exit 0
        case "$PID" in ''|*[!0-9]*) exit 0 ;; esac
        [ -r "/proc/$PID/stat" ] || exit 0
        read -r STAT < "/proc/$PID/stat" || exit 0
        # comm is field 2, parenthesised, and may hold spaces, so the fields are
        # counted from after its closing paren: field 22 is the 20th of the rest.
        set -- ${STAT##*) }
        [ -z "$PSTART" ] || [ "$PSTART" = "${20}" ] || exit 0
        printf '%s\n' "$ROW"
      }
    done
  fi | jq -s -c '.' 2>/dev/null)
[ -n "$SESS" ] || SESS='[]'

printf '%s\n' "$SESS"
]==]

-- Remote t3-connect threads, carved out of t3-code's IndexedDB cache. $PY is the
-- shipped remote_threads.py path, prepended by remoteCommand(); every other path
-- is derived from $HOME inside the script.
--
-- The app holds a POSIX lock on the store's LOCK file, so the directory is copied
-- to a scratch dir and the copy is read — a plain file read takes no lock. The
-- copy is always removed, on the happy path and on any early exit, by the trap.
--
-- A missing cache directory is not an error: t3-code has simply never run here, so
-- the script emits an empty environment list and the remote sections stay absent.
local REMOTE_SCRIPT = [==[
SRC="$HOME/.config/t3code/IndexedDB/t3code_app_0.indexeddb.leveldb"
if [ ! -d "$SRC" ]; then
  printf '{"schemaVersion":1,"environments":[]}\n'
  exit 0
fi

LOCAL=$(cat "$HOME/.t3/userdata/environment-id" 2>/dev/null)

D=$(mktemp -d) || { printf '{"schemaVersion":1,"environments":[]}\n'; exit 0; }
trap 'rm -rf "$D"' EXIT
if ! cp -a "$SRC/." "$D/" 2>/dev/null; then
  printf '{"schemaVersion":1,"environments":[]}\n'
  exit 0
fi

OUT=$(python3 "$PY" "$D" "$LOCAL" 2>/dev/null)
[ -n "$OUT" ] || OUT='{"schemaVersion":1,"environments":[]}'
printf '%s\n' "$OUT"
]==]

-- ai-usagebar owns provider discovery, credentials and response caching. Its
-- display model is reduced here so only fields the panel draws cross into state.
local AIUB_SCRIPT = [==[
command -v ai-usagebar >/dev/null 2>&1 || { printf '{"available":false}\n'; exit 0; }

AIUB_FILTER='
def epoch:
  if type == "string" and . != "" then
    ((sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) as $s
     | (if ($s | test("Z$")) then $s else $s + "Z" end)
     | (try fromdateiso8601 catch null))
  else null end;
{ available: true, ok: true,
  providers: [ (.entries // [])[]
    | select(.status == "ready")
    | { id: .id,
        name: (.display_name // .id),
        # A vendor with no plan name reports its masked API key there instead
        # ("OpenRouter — sk-or-...abc"). A key fragment does not belong on a
        # panel, so a masked plan loses its key half, and a plan that then only
        # repeats the vendor name is dropped.
        plan: ((.display_name // .id) as $n
          | (.plan // "")
          | (if contains("...") then (split(" — ")[0] // "") else . end)
          | (if . == $n then "" else . end)),
        # elapsed is how far through its window a metric is, and it only exists
        # inside the human-readable detail string, so it is parsed back out.
        # Windows without one (credit balances) simply carry null.
        windows: [ (.metrics // [])[]
          | select((.percent | type) == "number")
          | { label: .label, pct: .percent,
              # value is the number the vendor would print: usually "52%", but a
              # balance vendor reports the money remaining ("$17.67") while pct
              # carries the share used. The panel shows value and bars pct.
              value: (.value // ""),
              resetsAt: ((.reset_at | epoch) // 0),
              severity: (.severity // ""),
              elapsed: ((((.detail // "")
                | capture("(?<e>[0-9]+)% elapsed") | .e | tonumber)? // null)) } ],
        blocks: [ (.sections // [])[]
          | select(.type == "block")
          | { label: .label, lines: .body } ] } ] }'

D=$(mktemp -d) || { printf '{"available":true,"ok":false}\n'; exit 0; }
trap 'rm -rf "$D"' EXIT
if ! ai-usagebar usage --json > "$D/usage" 2>/dev/null; then
  printf '{"available":true,"ok":false}\n'
  exit 0
fi
OUT=$(jq -c "$AIUB_FILTER" "$D/usage" 2>/dev/null)
if [ -z "$OUT" ]; then
  printf '{"available":true,"ok":false}\n'
  exit 0
fi
printf '%s\n' "$OUT"
]==]

-- ==============================================================================
-- ── RUNTIME STATE ──────────────────────────────────────────────────────────
-- ==============================================================================

-- The argv-table form of runAsync needs plugin API 24 and this host caps at 23,
-- so the fast query is a shell command line. Both halves are compile-time
-- constants and both are quoted regardless.
local queryCommand = "sqlite3 -noheader -batch " .. shellQuote(DB_URI) .. " " .. shellQuote(SQL)

-- The carve is a shipped script rather than an inline heredoc: brace-matching a
-- multi-file store is clearer in Python and easier to read on its own. pluginDir
-- can be nil on a host that does not expose it, and then the remote loop simply
-- never runs.
local REMOTE_SCRIPT_PATH = (function()
  local dir = noctalia.pluginDir()
  if type(dir) ~= "string" or dir == "" then return nil end
  return dir .. "/remote_threads.py"
end)()

local tick = 0
local fastBusy = false
local dbStamp = "" -- size+mtime of the database files as of the last query attempt
local fastRanAt = 0 -- epoch seconds of that attempt, for the FAST_FORCE_S net
local sessionsBusy = false
local remoteBusy = false
local sessionsEvery = 20 -- ticks between session scans, recomputed from the poll interval
local remoteEvery = 13 -- ticks between remote cache reads, recomputed from remote_poll_s
local resumeSessions = {} -- Claude session ids t3 already owns
local resumeKey = "" -- a stable digest of the above, to notice when it changes
local rawStandalone = {} -- last scan's session list, before the t3-owned filter

-- Defined with the session loop, but the fast loop is what learns which Claude
-- sessions t3 owns, so it needs to be able to re-apply the filter.
local applyStandaloneFilter

local limitsBusy = false
local limitsCheckedAt = 0 -- epoch seconds of the last attempt; 0 means "never asked"

-- What the fast loop last saw in flight, and the edge it raises when some of it
-- is gone. The flag is read and cleared by the next limit tick rather than acted
-- on where it is set, because the fast loop learns this inside an async callback.
local runningThreads = {}
local liveTasks = {}
local workEnded = false

local limitsState = {
  available = false,
  stale = false,
  at = 0,
  providers = {},
}

local sessionsState = {
  standalone = {},
  updatedAt = 0,
}

-- Remote environments and their unsettled threads, as last carved. Empty until
-- the first read, and emptied again the moment show_remote goes off.
local remoteState = {
  environments = {},
  updatedAt = 0,
}

-- ==============================================================================
-- ── FAST LOOP ──────────────────────────────────────────────────────────────
-- ==============================================================================

-- Everything a consumer draws, as one string. The panel already gates its render
-- on a fingerprint of its own; this is the same idea one step earlier, so an
-- unchanged fleet never even wakes the widget's watcher.
--
-- updatedAt is deliberately not in it. It moves on every tick by construction and
-- nothing downstream reads it, so including it would defeat the comparison; left
-- out, what it ends up meaning is "when the content last changed".
local function snapshotKey(snapshot)
  local parts = { tostring(snapshot.t3Running), snapshot.errorBanner, snapshot.schemaNote }
  for _, thread in ipairs(snapshot.threads) do
    table.insert(parts, table.concat({
      thread.id, thread.title, thread.project, thread.root, thread.branch,
      thread.status, thread.provider, thread.model,
      tostring(thread.approvals), tostring(thread.inputs), tostring(thread.updatedAt),
    }, "\2"))
  end
  for _, agent in ipairs(snapshot.agents) do
    table.insert(parts, table.concat({
      agent.threadId, agent.taskId, agent.title, agent.detail, agent.model,
      agent.role, agent.tool, tostring(agent.tokens), agent.project, tostring(agent.at),
    }, "\2"))
  end
  -- Context arrives as a map, so its keys are sorted: the same two tables have to
  -- produce the same string whatever order pairs() happened to walk them in.
  local ids = {}
  for id in pairs(snapshot.contextByThread) do table.insert(ids, id) end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local context = snapshot.contextByThread[id]
    table.insert(parts, table.concat({ id, tostring(context.used), tostring(context.max) }, "\2"))
  end
  return table.concat(parts, "\3")
end

local lastSnapshotKey = nil

local function publishSnapshot(snapshot)
  local key = snapshotKey(snapshot)
  if key == lastSnapshotKey then return end
  lastSnapshotKey = key
  noctalia.state.set("snapshot", snapshot)
end

local function downSnapshot(banner)
  publishSnapshot({
    t3Running = false,
    threads = {},
    agents = {},
    contextByThread = {},
    errorBanner = banner or "",
    schemaNote = "",
    updatedAt = nowS(),
  })
end

local function normalizeThreads(rows)
  local threads = {}
  if type(rows) ~= "table" then return threads end
  for _, row in ipairs(rows) do
    if type(row) == "table" and type(row.id) == "string" then
      table.insert(threads, {
        id = row.id,
        title = type(row.title) == "string" and row.title or "",
        project = type(row.project) == "string" and row.project or "",
        root = type(row.root) == "string" and row.root or "",
        branch = type(row.branch) == "string" and row.branch or "",
        status = type(row.status) == "string" and row.status or "idle",
        provider = type(row.provider) == "string" and row.provider or "",
        model = type(row.model) == "string" and row.model or "",
        approvals = tonumber(row.approvals) or 0,
        inputs = tonumber(row.inputs) or 0,
        updatedAt = tonumber(row.updatedAt) or 0,
      })
    end
  end
  return threads
end

-- Keeps subagents whose progress row is recent. The parent thread's own status
-- is deliberately NOT part of this test: a thread sits at "ready" while its
-- subagents work — that status describes the provider session, not the fleet —
-- so gating on it hides exactly the rows this plugin exists to show.
local function normalizeAgents(rows, threads, now)
  local byId = {}
  for _, thread in ipairs(threads) do
    byId[thread.id] = thread
  end

  local agents = {}
  if type(rows) ~= "table" then return agents end
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local thread = byId[row.threadId]
      local at = tonumber(row.at) or 0
      if at > 0 and (now - at) <= AGENT_STALE_S then
        table.insert(agents, {
          threadId = row.threadId,
          taskId = type(row.taskId) == "string" and row.taskId or "",
          title = type(row.title) == "string" and row.title or "",
          detail = type(row.detail) == "string" and row.detail or "",
          model = type(row.model) == "string" and row.model or "",
          role = type(row.role) == "string" and row.role or "",
          tool = type(row.tool) == "string" and row.tool or "",
          tokens = tonumber(row.tokens) or 0,
          project = thread ~= nil and thread.project or "",
          at = at,
        })
      end
    end
  end
  return agents
end

local function normalizeContext(rows)
  local byThread = {}
  if type(rows) ~= "table" then return byThread end
  for _, row in ipairs(rows) do
    local used = tonumber(row.used)
    local max = tonumber(row.max)
    if type(row.threadId) == "string" and used ~= nil and max ~= nil and max > 0 then
      byThread[row.threadId] = { used = used, max = max }
    end
  end
  return byThread
end

-- The one thing that can move a subscription window is work that ran, so the
-- limit loop is driven from here: a thread that is no longer running, or a
-- subagent that is no longer live, means tokens were spent and the providers
-- have something new to say. Work *starting* is deliberately not a trigger —
-- asking mid-turn costs a call and answers with the number from before it.
--
-- The server going away is not an ending either. Everything it was running
-- disappears from the query at once, and the plugin has no way to tell a
-- finished turn from a killed one, so that transition clears the sets quietly.
local function trackActivity(running, tasks, quiet)
  if not quiet then
    for id in pairs(runningThreads) do
      if not running[id] then workEnded = true end
    end
    for id in pairs(liveTasks) do
      if not tasks[id] then workEnded = true end
    end
  end
  runningThreads = running
  liveTasks = tasks
end

-- Size and mtime of the database and its WAL. Two stats are cheap where a sqlite3
-- spawn is not, and the pair answers the only question the fast loop has between
-- ticks: has anything been written at all.
--
-- nil means "no idea", and the caller then queries as it always did: a host with
-- no fileInfo at all, or (the case worth guarding) one where neither file could be
-- stat'ed, which must not read as a database that is holding still.
local function dbFingerprint()
  if type(noctalia.fileInfo) ~= "function" then return nil end
  local parts = {}
  local seen = false
  for _, path in ipairs(DB_STAMP_FILES) do
    local info = noctalia.fileInfo(path)
    if type(info) == "table" then
      seen = true
      table.insert(parts, tostring(info.size) .. ":" .. tostring(info.mtime))
    else
      table.insert(parts, "-")
    end
  end
  if not seen then return nil end
  return table.concat(parts, "\1")
end

local function runFastTick()
  if fastBusy then return end

  if not noctalia.fileExists(RUNTIME_FILE) then
    trackActivity({}, {}, true)
    -- With the server gone, nothing it used to own is owned any more: a Claude
    -- session still on the machine is a standalone one now.
    if resumeKey ~= "" then
      resumeKey = ""
      resumeSessions = {}
      applyStandaloneFilter()
    end
    downSnapshot("")
    return
  end

  -- A database nobody has written to since the last query would answer exactly
  -- what it answered then, and t3 is idle far more of the day than it is busy, so
  -- the common tick is two stats and nothing else.
  local stamp = dbFingerprint()
  local startedAt = nowS()
  if stamp ~= nil and stamp == dbStamp and (startedAt - fastRanAt) < FAST_FORCE_S then
    return
  end
  dbStamp = stamp or ""
  fastRanAt = startedAt

  fastBusy = true
  noctalia.runAsync(queryCommand, function(result)
    fastBusy = false
    if type(result) ~= "table" then
      trackActivity({}, {}, true)
      downSnapshot(noctalia.tr("error.query_failed"))
      return
    end
    if result.exitCode ~= 0 or result.stdoutTruncated then
      local detail = noctalia.string.trim(result.stderr or "")
      noctalia.log("t3agents: sqlite query failed: " .. (detail ~= "" and detail or "no stderr"))
      trackActivity({}, {}, true)
      downSnapshot(noctalia.tr("error.query_failed"))
      return
    end

    local payload, err = noctalia.json.decode(noctalia.string.trim(result.stdout or ""))
    if type(payload) ~= "table" then
      noctalia.log("t3agents: could not decode query payload: " .. tostring(err))
      trackActivity({}, {}, true)
      downSnapshot(noctalia.tr("error.query_failed"))
      return
    end

    local now = nowS()
    local threads = normalizeThreads(payload.threads)
    local migration = tonumber(payload.migration)

    -- A Claude session t3 is driving writes the same ~/.claude/sessions file a
    -- hand-started one does. The resume cursors are the only thing that tells
    -- them apart, and they arrive here rather than with the scan, so the
    -- standalone list is re-filtered whenever the set changes.
    local ids = {}
    if type(payload.resumes) == "table" then
      for _, id in ipairs(payload.resumes) do
        if type(id) == "string" then table.insert(ids, id) end
      end
    end
    table.sort(ids)
    local key = table.concat(ids, "\1")
    if key ~= resumeKey then
      resumeKey = key
      resumeSessions = {}
      for _, id in ipairs(ids) do resumeSessions[id] = true end
      applyStandaloneFilter()
    end

    local agents = normalizeAgents(payload.agents, threads, now)

    -- Settled threads stay out of the snapshot: a thread earns a row by doing
    -- something (running/starting), needing someone (approvals/inputs, error),
    -- or having live subagents — not by merely existing in t3's history.
    local liveByThread = {}
    local liveTaskIds = {}
    for _, agent in ipairs(agents) do
      liveByThread[agent.threadId] = true
      if agent.taskId ~= "" then liveTaskIds[agent.taskId] = true end
    end
    local active = {}
    local busyThreads = {}
    for _, thread in ipairs(threads) do
      if thread.status == "running" or thread.status == "starting" then
        busyThreads[thread.id] = true
      end
      if thread.status == "running" or thread.status == "starting"
        or thread.status == "error" or thread.approvals > 0
        or thread.inputs > 0 or liveByThread[thread.id] then
        table.insert(active, thread)
      end
    end
    trackActivity(busyThreads, liveTaskIds, false)

    publishSnapshot({
      t3Running = true,
      threads = active,
      agents = agents,
      contextByThread = normalizeContext(payload.context),
      errorBanner = "",
      schemaNote = (migration ~= nil and migration ~= KNOWN_MIGRATION)
        and noctalia.tr("error.schema_drift", { level = migration, known = KNOWN_MIGRATION })
        or "",
      updatedAt = now,
    })
  end, FAST_TIMEOUT_MS)
end

-- ==============================================================================
-- ── SESSION LOOP ───────────────────────────────────────────────────────────
-- ==============================================================================

-- Drops Claude session files that are really t3 threads wearing another hat: t3
-- resumes a thread against a Claude session id, and that session writes the same
-- ~/.claude/sessions/<pid>.json a hand-started `claude` would.
local function normalizeStandalone(rows)
  local sessions = {}
  if type(rows) ~= "table" then return sessions end
  for _, row in ipairs(rows) do
    if type(row) == "table" and tonumber(row.pid) ~= nil then
      local sessionId = type(row.sessionId) == "string" and row.sessionId or ""
      if not resumeSessions[sessionId] then
        table.insert(sessions, {
          pid = math.floor(tonumber(row.pid)),
          sessionId = sessionId,
          cwd = type(row.cwd) == "string" and row.cwd or "",
          name = type(row.name) == "string" and row.name or "",
          kind = type(row.kind) == "string" and row.kind or "",
          startedAt = math.floor((tonumber(row.startedAt) or 0) / 1000),
        })
      end
    end
  end
  return sessions
end

applyStandaloneFilter = function()
  sessionsState.standalone = normalizeStandalone(rawStandalone)
  noctalia.state.set("sessions", sessionsState)
end

local function runSessionsTick()
  if sessionsBusy then return end
  sessionsBusy = true

  noctalia.runAsync(SESSIONS_SCRIPT, function(result)
    sessionsBusy = false
    if type(result) ~= "table" or result.exitCode ~= 0 or result.stdoutTruncated then
      noctalia.log("t3agents: session scan failed"
        .. (type(result) == "table" and (" (exit " .. tostring(result.exitCode) .. ")") or ""))
      return
    end

    local payload = noctalia.json.decode(noctalia.string.trim(result.stdout or ""))
    if type(payload) ~= "table" then
      noctalia.log("t3agents: could not decode session payload")
      return
    end

    rawStandalone = payload
    sessionsState = {
      standalone = normalizeStandalone(rawStandalone),
      updatedAt = nowS(),
    }
    noctalia.state.set("sessions", sessionsState)
  end, SESSIONS_TIMEOUT_MS)
end

-- ==============================================================================
-- ── REMOTE LOOP ────────────────────────────────────────────────────────────
-- ==============================================================================

local function publishRemote()
  noctalia.state.set("remote", remoteState)
end

local function remoteCommand()
  return "PY=" .. shellQuote(REMOTE_SCRIPT_PATH) .. "\n" .. REMOTE_SCRIPT
end

-- The friendly label for an environment is encrypted elsewhere and never in this
-- store, so it comes from the remote_names map the user fills in. An unmapped one
-- falls back to the first eight characters of its id, which is enough to tell two
-- machines apart out of the box.
local function remoteName(environmentId)
  local names = cfg("remote_names")
  if type(names) == "table" then
    local mapped = names[environmentId]
    if type(mapped) == "string" and mapped ~= "" then return mapped end
  end
  return environmentId:sub(1, 8)
end

-- The same "settled threads hidden" test the local loop applies, over the remote
-- signals: a thread earns a row by running, erroring, or needing someone — not by
-- sitting stopped in the cache. lastError becomes the "error" status because that
-- is the salient state the panel already knows how to colour, and each pending
-- boolean counts as one against the existing approvals/inputs styling.
--
-- Unlike the local loop, this deliberately does NOT gate on the raw cached status.
-- The remote cache only advances while t3-code runs AND the remote is connected,
-- so when that link drops mid-turn the record freezes at status == "running" (with
-- activeTurnId and latestTurn still set) and never records the completion. row.working
-- from remote_threads.py already reconciles that stale claim against latestTurn.state,
-- the settled markers, and cache freshness, so it is the only running signal we trust.
local function normalizeRemoteThread(row)
  if type(row) ~= "table" or type(row.id) ~= "string" or row.id == "" then return nil end
  local status = type(row.status) == "string" and row.status or "idle"
  local hasError = row.error == true
  local pendingApprovals = row.pendingApprovals == true
  local pendingInput = row.pendingInput == true
  local pendingPlan = row.pendingPlan == true
  local working = row.working == true

  local settled = not (working or hasError
    or pendingApprovals or pendingInput or pendingPlan)
  if settled then return nil end

  return {
    id = row.id,
    title = type(row.title) == "string" and row.title or "",
    project = type(row.project) == "string" and row.project or "",
    branch = type(row.branch) == "string" and row.branch or "",
    status = hasError and "error" or status,
    model = type(row.model) == "string" and row.model or "",
    approvals = pendingApprovals and 1 or 0,
    inputs = (pendingInput or pendingPlan) and 1 or 0,
    updatedAt = math.floor(tonumber(row.updatedAt) or 0),
  }
end

local function normalizeRemote(payload)
  local environments = {}
  if type(payload) ~= "table" or payload.schemaVersion ~= 1 then return environments end
  if type(payload.environments) ~= "table" then return environments end

  for _, env in ipairs(payload.environments) do
    if type(env) == "table" and type(env.environmentId) == "string" and env.environmentId ~= "" then
      local threads = {}
      if type(env.threads) == "table" then
        for _, row in ipairs(env.threads) do
          local thread = normalizeRemoteThread(row)
          if thread ~= nil then table.insert(threads, thread) end
        end
      end
      -- An environment with nothing unsettled contributes no subheader and no
      -- rows, exactly as a settled local thread contributes none.
      if #threads > 0 then
        table.insert(environments, {
          environmentId = env.environmentId,
          name = remoteName(env.environmentId),
          threads = threads,
          newestUpdatedAt = math.floor(tonumber(env.newestUpdatedAt) or 0),
        })
      end
    end
  end
  return environments
end

local function runRemoteTick()
  if remoteBusy then return end

  -- Off, or a host without pluginDir, means no remote path at all: publish an
  -- empty list once so the panel drops whatever it was showing, then stop.
  if cfg("show_remote") == false or REMOTE_SCRIPT_PATH == nil then
    if #remoteState.environments > 0 then
      remoteState = { environments = {}, updatedAt = nowS() }
      publishRemote()
    end
    return
  end

  remoteBusy = true
  noctalia.runAsync(remoteCommand(), function(result)
    remoteBusy = false
    -- A failed read keeps the last answer rather than blanking the section: the
    -- cache on disk did not change because our copy of it failed.
    if type(result) ~= "table" or result.exitCode ~= 0 or result.stdoutTruncated then
      noctalia.log("t3agents: remote cache read failed"
        .. (type(result) == "table" and (" (exit " .. tostring(result.exitCode) .. ")") or ""))
      return
    end

    local payload = noctalia.json.decode(noctalia.string.trim(result.stdout or ""))
    if type(payload) ~= "table" then
      noctalia.log("t3agents: could not decode remote payload")
      return
    end

    remoteState = {
      environments = normalizeRemote(payload),
      updatedAt = nowS(),
    }
    publishRemote()
  end, REMOTE_TIMEOUT_MS)
end

-- ==============================================================================
-- ── LIMIT LOOP ─────────────────────────────────────────────────────────────
-- ==============================================================================

local function publishLimits()
  noctalia.state.set("limits", limitsState)
end

local function limitWindow(row)
  if type(row) ~= "table" then return nil end
  local pct = tonumber(row.pct)
  if pct == nil then return nil end
  if pct < 0 then pct = 0 end
  local elapsed = tonumber(row.elapsed)
  if elapsed ~= nil then elapsed = math.clamp(elapsed, 0, 100) end
  return {
    label = type(row.label) == "string" and row.label or "",
    pct = pct,
    value = type(row.value) == "string" and row.value or "",
    resetsAt = math.floor(tonumber(row.resetsAt) or 0),
    severity = type(row.severity) == "string" and row.severity or "",
    elapsed = elapsed,
  }
end

local function limitWindows(rows)
  local windows = {}
  if type(rows) ~= "table" then return windows end
  for _, row in ipairs(rows) do
    local window = limitWindow(row)
    if window ~= nil then table.insert(windows, window) end
  end
  return windows
end

local function limitBlocks(rows)
  local blocks = {}
  if type(rows) ~= "table" then return blocks end
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local lines = {}
      if type(row.lines) == "table" then
        for _, line in ipairs(row.lines) do
          if type(line) == "string" then table.insert(lines, line) end
        end
      end
      table.insert(blocks, {
        label = type(row.label) == "string" and row.label or "",
        lines = lines,
      })
    end
  end
  return blocks
end

local function limitProviders(rows)
  local providers = {}
  if type(rows) ~= "table" then return providers end
  for _, row in ipairs(rows) do
    if type(row) == "table" and type(row.id) == "string" and row.id ~= "" then
      local windows = limitWindows(row.windows)
      local blocks = limitBlocks(row.blocks)
      if #windows > 0 or #blocks > 0 then
        table.insert(providers, {
          id = row.id,
          name = type(row.name) == "string" and row.name or row.id,
          plan = type(row.plan) == "string" and row.plan or "",
          windows = windows,
          blocks = blocks,
        })
      end
    end
  end
  return providers
end

-- A provider that answers badly keeps whatever it last said. A number an hour
-- old is worth more than a blank row, as long as the panel admits its age.
local function markStale(entry)
  entry.available = true
  entry.stale = true
  publishLimits()
end

local function limitPayload(result)
  if type(result) ~= "table" or result.exitCode ~= 0 or result.stdoutTruncated then return nil end
  local payload = noctalia.json.decode(noctalia.string.trim(result.stdout or ""))
  if type(payload) ~= "table" then return nil end
  return payload
end

local function runLimitsTick()
  if limitsBusy then return end
  limitsBusy = true
  limitsCheckedAt = nowS()

  noctalia.runAsync(AIUB_SCRIPT, function(result)
    limitsBusy = false
    local payload = limitPayload(result)
    if payload == nil then
      markStale(limitsState)
      return
    end
    if payload.available ~= true then
      limitsState = { available = false, stale = false, at = 0, providers = {} }
      publishLimits()
      return
    end
    if payload.ok ~= true then
      markStale(limitsState)
      return
    end

    limitsState = {
      available = true,
      stale = false,
      at = nowS(),
      providers = limitProviders(payload.providers),
    }
    publishLimits()
  end, AIUB_TIMEOUT_MS)
end

-- A window whose reset time has come around says nothing useful any more: the
-- percentage it carries belongs to a period that is over, and the bar should have
-- dropped. That is worth one call even on a machine where nothing is running.
local function rolledOver(entry, now)
  if type(entry) ~= "table" or entry.available ~= true then return false end
  if type(entry.providers) == "table" then
    for _, provider in ipairs(entry.providers) do
      if type(provider.windows) == "table" then
        for _, window in ipairs(provider.windows) do
          local resetsAt = type(window) == "table" and (tonumber(window.resetsAt) or 0) or 0
          if resetsAt > 0 and now >= resetsAt then return true end
        end
      end
    end
  end
  return false
end

-- Never asked means ask now — that is the one poll at startup, and the one after
-- the section is switched on. Everything after it waits out the gap, whether the
-- reason to ask is finished work or a window that has rolled over.
local function limitDue(checkedAt, entry, now, gap, ended)
  if checkedAt == 0 then return true end
  if (now - checkedAt) < gap then return false end
  return ended or rolledOver(entry, now)
end

local function runLimitTicks()
  if cfg("show_limits") == false then
    workEnded = false
    return
  end
  local now = nowS()
  local gap = intConfig("limits_gap_s", 300, 60, 3600)
  -- Consumed rather than remembered: a completion the gap swallows is not a poll
  -- owed later, because whatever it spent is in the next answer anyway.
  local ended = workEnded
  workEnded = false

  if limitDue(limitsCheckedAt, limitsState, now, gap, ended) then runLimitsTick() end
end

-- ==============================================================================
-- ── LIFECYCLE ──────────────────────────────────────────────────────────────
-- ==============================================================================

local function applyIntervals()
  local pollMs = intConfig("poll_interval_ms", 1500, 500, 5000)
  noctalia.setUpdateInterval(pollMs)
  sessionsEvery = math.max(1, math.floor((SESSIONS_REFRESH_S * 1000) / pollMs))
  local remotePollS = intConfig("remote_poll_s", 20, 10, 300)
  remoteEvery = math.max(1, math.floor((remotePollS * 1000) / pollMs))
end

function update()
  tick += 1
  runFastTick()
  if (tick % sessionsEvery) == 0 then
    runSessionsTick()
  end
  if (tick % remoteEvery) == 0 then
    runRemoteTick()
  end
  runLimitTicks()
end

function onConfigChanged()
  applyIntervals()
  -- A changed remote_names map or show_remote toggle should show at once rather
  -- than at the next cadence tick; the in-flight guard makes this free if a read
  -- is already out.
  runRemoteTick()
  -- Saving a setting is not a reason to spend a call, so the limit loop keeps its
  -- gap through this. A first read is the exception when the section is enabled.
  if limitsState.at == 0 then limitsCheckedAt = 0 end
end

function onEnable()
  applyIntervals()
end

-- ==============================================================================
-- ── BOOT ───────────────────────────────────────────────────────────────────
-- ==============================================================================

applyIntervals()
noctalia.state.set("sessions", sessionsState)
publishRemote()
publishLimits()
downSnapshot("")
runFastTick()
runSessionsTick()
runRemoteTick()
-- The limit loop waits for the first update() tick.
