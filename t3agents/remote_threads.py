#!/usr/bin/env python3
"""Carve remote t3-connect thread state out of t3-code's IndexedDB cache.

t3-code caches every connected environment's thread state as plaintext JSON in
its Electron IndexedDB LevelDB. The service copies that store to a scratch dir
(the live one is under a POSIX lock the app holds) and hands the copy here; this
script reads it and returns a small JSON summary of the *remote* environments'
threads. There is no subagent or activity detail cached for remote, so this is
thread-level data only.

Usage: remote_threads.py <copied-leveldb-dir> <local-environment-id>

The heavy lifting lives here rather than in the Luau service because a Luau
script callback has a CPU budget and this is a multi-file text carve. stdlib
only: no leveldb library (which would want the lock), no snappy.

How the carve works. Each snapshot is stored as a plain JSON string that starts
`{"schemaVersion":1,"environmentId":"<uuid>"`. LevelDB inserts a ~7-byte block
header every ~32 KB, which can split a large record, so we brace-match from the
opening brace (tracking JSON string/escape state) rather than line-grepping, and
we json.loads the slice. A record torn by a block header fails to parse and is
skipped, so per environment we keep the object with the highest
snapshot.snapshotSequence that parsed cleanly. The newest intact snapshot per
environment lives in the live `.log` while the app runs; the `.ldb` blocks are
snappy-compressed older sequences, so the plaintext marker never appears in them
and reading only `.log` files is enough.

Output (small, for the Luau service to tag and render):
  {"schemaVersion":1,"environments":[
    {"environmentId","newestUpdatedAt",
     "threads":[{"id","title","project","branch","status","error","working",
                 "pendingApprovals","pendingInput","pendingPlan","model",
                 "updatedAt","backgroundLiveness"}]}]}

Anything that is not schemaVersion 1 is failed soft (dropped), never crashed on.
"""

import glob
import json
import os
import sys
import time
from datetime import datetime

# How long a remote thread's frozen "running" claim is still believed. The cache
# only advances while t3-code is running AND the remote is connected; when that
# link drops mid-turn the whole record — session.status, session.activeTurnId,
# latestTurn.state — freezes at "running" and never records the completion. So a
# live-turn claim is only trusted while the record is still fresh. Once the cache
# has stopped advancing for longer than this, the turn has almost certainly
# finished and we treat the thread as settled. A genuinely running, connected
# thread refreshes its record far more often than this window.
REMOTE_RUNNING_STALE_S = 600

MARKER = b'{"schemaVersion":1,"environmentId":"'

# JSON structural bytes, matched against the raw store so a block header spliced
# mid-record simply breaks the parse instead of the scan.
QUOTE = 0x22
BACKSLASH = 0x5C
OPEN = 0x7B
CLOSE = 0x7D


def carve(data):
    """Yield every top-level JSON object beginning at MARKER in `data`."""
    i = 0
    while True:
        start = data.find(MARKER, i)
        if start < 0:
            return
        depth = 0
        in_string = False
        escaped = False
        end = -1
        j = start
        while j < len(data):
            c = data[j]
            if in_string:
                if escaped:
                    escaped = False
                elif c == BACKSLASH:
                    escaped = True
                elif c == QUOTE:
                    in_string = False
            elif c == QUOTE:
                in_string = True
            elif c == OPEN:
                depth += 1
            elif c == CLOSE:
                depth -= 1
                if depth == 0:
                    end = j
                    break
            j += 1
        if end > 0:
            try:
                yield json.loads(data[start : end + 1])
            except Exception:
                pass  # torn by a block header — the next-lower sequence stands in
        i = start + 1


def epoch(iso):
    """ISO-8601 UTC string -> integer epoch seconds, or 0 when unparseable."""
    if not isinstance(iso, str) or iso == "":
        return 0
    try:
        return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp())
    except Exception:
        return 0


def as_bool(value):
    return value is True


def thread_summary(thread, projects, now):
    session = thread.get("session")
    if not isinstance(session, dict):
        session = {}
    model_selection = thread.get("modelSelection")
    if not isinstance(model_selection, dict):
        model_selection = {}
    latest_turn = thread.get("latestTurn")
    if not isinstance(latest_turn, dict):
        latest_turn = {}

    status = session.get("status")
    status = status if isinstance(status, str) and status != "" else "idle"
    has_error = session.get("lastError") is not None
    active_turn = session.get("activeTurnId") is not None

    latest_state = latest_turn.get("state")
    latest_state = latest_turn.get("state") if isinstance(latest_state, str) else ""
    # settledAt or an explicit settledOverride of "settled" is the cache's own
    # "this thread is done" write, present on any thread that finished cleanly.
    settled_flag = (
        thread.get("settledAt") is not None
        or thread.get("settledOverride") == "settled"
    )

    project_id = thread.get("projectId")
    title = projects.get(project_id, "") if isinstance(project_id, str) else ""

    background = thread.get("backgroundLiveness")
    background = background if isinstance(background, str) else ""

    model = model_selection.get("model")
    model = model if isinstance(model, str) else ""

    branch = thread.get("branch")
    branch = branch if isinstance(branch, str) else ""

    thread_title = thread.get("title")
    thread_title = thread_title if isinstance(thread_title, str) else ""

    updated = epoch(thread.get("updatedAt"))

    # Whether the (possibly frozen) record CLAIMS a turn is in flight. session.status
    # alone can't be trusted: for a remote environment the cache freezes at "running"
    # once the connection drops, so activeTurnId and latestTurn.state freeze with it.
    # A completed turn or an explicit settled write overrides any stale claim.
    claims_live = (
        not settled_flag
        and latest_state != "completed"
        and (active_turn or status in ("running", "starting") or background == "working")
    )
    # The claim is only believed while the record is still fresh; past the stale
    # window a frozen "running" means the turn finished and the cache never caught it.
    fresh = updated != 0 and (now - updated) <= REMOTE_RUNNING_STALE_S
    working = claims_live and fresh

    return {
        "id": thread.get("id") if isinstance(thread.get("id"), str) else "",
        "title": thread_title,
        "project": title,
        "branch": branch,
        "status": status,
        "error": has_error,
        # A robust "turn in flight" flag, not a trust of the raw cached status:
        # see claims_live/fresh above. The Luau service owns the settled filter.
        "working": working,
        # There is no numeric pending count remotely, only these booleans.
        "pendingApprovals": as_bool(thread.get("hasPendingApprovals")),
        "pendingInput": as_bool(thread.get("hasPendingUserInput")),
        "pendingPlan": as_bool(thread.get("hasActionableProposedPlan")),
        "model": model,
        "updatedAt": updated,
        "backgroundLiveness": background,
    }


def main():
    if len(sys.argv) < 3:
        print('{"schemaVersion":1,"environments":[]}')
        return 0
    src, local = sys.argv[1], sys.argv[2]
    now = int(time.time())

    # environmentId -> (snapshotSequence, snapshot object) with the max sequence.
    best = {}
    for path in sorted(glob.glob(os.path.join(src, "*.log"))):
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError:
            continue
        for obj in carve(data):
            if not isinstance(obj, dict) or obj.get("schemaVersion") != 1:
                continue
            env = obj.get("environmentId")
            if not isinstance(env, str) or env == "" or env == local:
                continue  # only remote environments
            snapshot = obj.get("snapshot")
            if not isinstance(snapshot, dict):
                continue
            seq = snapshot.get("snapshotSequence")
            seq = seq if isinstance(seq, (int, float)) else -1
            if env not in best or seq > best[env][0]:
                best[env] = (seq, obj)

    environments = []
    for env, (_, obj) in best.items():
        snapshot = obj.get("snapshot", {})
        projects = {}
        for project in snapshot.get("projects", []) or []:
            if isinstance(project, dict) and isinstance(project.get("id"), str):
                title = project.get("title")
                projects[project["id"]] = title if isinstance(title, str) else ""

        threads = []
        newest = 0
        for thread in snapshot.get("threads", []) or []:
            if not isinstance(thread, dict):
                continue
            summary = thread_summary(thread, projects, now)
            if summary["id"] == "":
                continue
            threads.append(summary)
            if summary["updatedAt"] > newest:
                newest = summary["updatedAt"]

        environments.append(
            {
                "environmentId": env,
                "newestUpdatedAt": newest,
                "threads": threads,
            }
        )

    print(json.dumps({"schemaVersion": 1, "environments": environments}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
