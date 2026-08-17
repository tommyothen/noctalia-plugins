# T3 Agents

What every AI agent on this machine is doing, and how much plan is left to do it
with, in the bar.

A glyph tells you the state of the fleet at a glance: quiet when nothing is
running, accented while work is in flight, red when t3-code is blocked waiting on
you. Click it for the dashboard: how much of each subscription window you have
spent, the live threads with their context-window occupancy, and the subagents
each one has out. Claude Code sessions you started by hand get a section of their
own when any are running.

## What it reads

Almost everything comes off disk. The plugin never talks to the t3 server, never
writes anything, and never takes a lock. The exception is the subscription limit
check described below, which asks `ai-usagebar` for every enabled provider.

| Source | What it gives |
| --- | --- |
| `~/.t3/userdata/server-runtime.json` | Whether t3-code is up at all. The file exists only while the server runs. |
| `~/.t3/userdata/state.sqlite` | Threads, their projects, branches, models and pending approvals; the running subagent fleet; per-thread context-window occupancy. Opened read-only through a `mode=ro` URI. |
| `~/.claude/sessions/<pid>.json` | Claude Code sessions started by hand, outside t3. Re-scanned every 30 s; each one is matched against `/proc/<pid>/stat` field 22, because a session file outlives its process and pids get reused. |
| `~/.config/ai-usagebar/config.toml` | Provider selection and credentials for subscription limits. It belongs to `ai-usagebar`; the plugin never reads it. |
| `~/.config/t3code/IndexedDB/t3code_app_0.indexeddb.leveldb` | t3-code's cache of every t3-connect environment's thread state, as plaintext JSON. Copied to a scratch dir and read there, because the app holds a lock on the live store. Only the plaintext thread snapshot is read; the copy is always removed. |
| `~/.t3/userdata/environment-id` | This machine's own environment id, so the cache's other environments count as remote. |

## Subscription limits

How much of your plan is left is a number that lives with the provider, so the
plugin shells out to `ai-usagebar usage --json`. One call returns every ready
provider in the CLI's configured order. The panel draws their named windows and
any summary blocks the provider reports. A newly enabled vendor appears without
a plugin update.

Claude and Codex use the existing logins from their own CLIs. Other vendors such
as OpenRouter, Cursor and Grok can be enabled with keys in
`~/.config/ai-usagebar/config.toml`.

### Security

- `ai-usagebar` owns every credential. The plugin does not open a provider's
  credentials file or receive a token.
- Only provider names, plans, percentages, reset times, severities and display
  blocks are published to `noctalia.state`.
- `ai-usagebar` keeps a 60-second on-disk response cache. The plugin does not
  write to provider configuration or credential directories.

### When they are asked

The limit loop has no cadence. Polling a window that only moves when you spend
something is wasted on an idle machine.

So the trigger is work ending. The fast loop already knows which threads are
running and which subagents are live; when a thread stops running or a subagent
goes away, all providers are fetched in one call. **Limit Check Gap** (default
300 s) is the floor between two asks. A completion inside the gap is
ignored rather than queued, because whatever it spent turns up in the next
answer anyway.

Three things happen outside that: one poll when the service starts, one when a
window's own reset time passes (the bar should drop, and nothing local knows
that), and one when the section is switched on having never reported. An idle
machine makes no calls at all.

If `ai-usagebar` is unavailable, the section is hidden. If a fetch fails, the
last good numbers stay visible, dimmed, with their age. A provider whose status
is `error` is omitted while other ready providers still render. **Subscription
Limits** turns the whole fetch off, network calls included.

## Remote threads

t3-connect links more than one machine to the same session, and t3-code caches
each connected environment's thread state as plaintext JSON in its Electron
IndexedDB. The plugin reads that cache so the panel's Threads list shows what is
running on the other machines, not only this one.

The app keeps a lock on the live store, so the read copies the directory to a
scratch dir and parses the copy. A shipped `remote_threads.py` does the parse: it
carves each environment's newest snapshot out of the store and returns the
threads for every environment that is not this machine's own. The copy is removed
whether the parse succeeds or fails.

This is thread-level data only. No subagent, task or activity detail is cached for
remote, so remote threads appear in the Threads list but never in Active agents.
A remote thread that is settled (stopped or ready, with nothing pending and no
background work) is hidden, exactly as a settled local thread is.

Remote threads sit under a subheader per environment. The friendly name of an
environment is encrypted elsewhere and is not in the cache this reads, so it
cannot be discovered. **Remote Names** maps each environment id to a name; an id
with no entry shows its first eight characters instead, so the feature works with
the map left empty. When the newest thread in an environment has not been touched
for a while, its subheader carries a "last seen" age, because the cache only moves
while the t3-code app is running.

## How it is put together

Four entries, and only one of them touches anything:

- `service.luau` is the headless collector. A fast loop (default 1.5 s) re-reads
  the live picture; a 30 s loop re-scans hand-started Claude sessions; a remote
  loop (default 20 s) reads the t3-code thread cache for other machines; the
  limit loop asks `ai-usagebar` for every provider when work finishes.
  Results are published to `noctalia.state` under `snapshot`, `sessions`,
  `remote` and `limits`.
- `remote_threads.py` is the carve the remote loop runs. It is kept out of Luau
  because a script callback has a CPU budget and this is a multi-file text parse.
  stdlib only.
- `widget.luau` is the bar presence: glyph, running-agent count, tooltip.
- `panel.luau` is the dashboard.

The widget and the panel are pure subscribers. Neither opens a file.

The five queries the fast loop wants come back from a single `sqlite3` call as
one JSON document, because five process spawns a second is a cost with no payoff.
That call only happens when the projection database or its WAL has actually been
written since the last one (plus once every 30 s regardless), so an idle machine
spends two `stat` calls a tick and nothing else.
The session scan is a shell script for a different reason: what it needs is a pid
check per file, and `/proc` is the only thing that knows.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Live Refresh | 1500 ms | How often the thread and subagent view is re-read. One `sqlite3` call, a few milliseconds, and only when the database has moved. |
| Subscription Limits | on | The percentage-of-plan section and its `ai-usagebar` fetch. |
| Limit Check Gap | 300 s | Least time between two limit checks. The checks themselves happen when work finishes. |
| Remote Threads | on | Show threads from other t3-connect machines in the Threads list. Off means the cache is never copied or read. |
| Remote Names | empty | Maps each environment id to a display name (`"<environmentId>" = "My Server"`). An unmapped id shows its first eight characters. |
| Remote Refresh | 20 s | How often the t3-code thread cache is copied and read. |
| Icon | `robot` | The bar glyph. |

The 30 s session scan is deliberately not a setting: a session starts or stops on
a human timescale.

## Requirements

`sqlite3`, `jq`, `python3` and `ai-usagebar`. The plugin degrades rather than
fails if they are missing: sections stay empty and a banner explains why.
`python3` is stdlib-only, for the remote thread carve. Claude and Codex limits
use their CLIs' existing logins through `ai-usagebar`.

## Behaviour when things are missing

- With t3-code not running, the thread and agent sections are replaced by a single
  line saying so. Subscription limits and standalone sessions keep working; they
  do not depend on the server. The server going away is not treated as work
  ending, so it does not trigger a limit check of its own.
- A provider that is not ready has its subscription row omitted. No ready
  providers means no limit section at all.
- If a limit check fails, the last good numbers stay on screen, dimmed, labelled
  with when they were read.
- If a query fails, the panel shows a banner in `error` colour instead of the
  plugin dying.
- If the t3 schema has moved on, a dim note names the migration level the queries
  were written against, so an empty section has an explanation.
- An absent t3-code IndexedDB cache means no remote threads and no error. The
  local sections are unaffected.
- If t3-code is not running but the local server was, the big "not running" block
  only takes over when there is nothing at all to show. With any remote threads
  present, the Threads section stands and the down state shrinks to a single line
  above them, because the remote cache outlives the local server.

## Known limits

- A subagent is considered gone when its last progress row is 30 minutes old. A
  `task.completed` that never lands would otherwise pin a ghost to the panel
  forever; the cost is that a genuinely silent 30-minute subagent disappears
  early.
- Standalone Claude sessions that t3 is driving are filtered out by matching
  their session id against t3's resume cursors. A session t3 owns but has not yet
  recorded a cursor for will show up in both places.
- The limit numbers are as old as the last check, which on a quiet machine can be
  a while. The panel dates a provider's card only when the read failed; a number
  that merely sat there for an hour looks like any other.
- Provider severities map `mid` to amber and `high` to red. An unrecognised value
  falls through to the percentage thresholds: amber from 70%, red from 90%.
- Remote thread names cannot be shown until you map them. The name lives encrypted
  elsewhere, not in the cache this reads, so an unmapped environment is a
  short id until **Remote Names** gives it one.
- Remote threads carry no context-window occupancy and no pending count. There is
  no per-thread context in the cache, and pending state is booleans rather than
  numbers, so a remote thread waiting on you reads as "1 waiting", not "3".
- A remote thread can go unreadable once t3-code has been closed long enough for
  LevelDB to compact its newest snapshot out of the live `.log` and into a
  compressed `.ldb`. The plugin reads only the plaintext `.log`, so a long-closed
  app eventually shows no remote threads rather than a very stale set.
