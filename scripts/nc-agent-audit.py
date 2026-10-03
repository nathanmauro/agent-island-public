#!/usr/bin/env python3
"""Read-only Notification Center audit (agent-island spec 12.4).

Copies the usernoted database (db, db-wal, db-shm) to a temp dir, opens the copy read-only and
reports records from agent apps whose delivered (or requested) date is at or after --since.
Moved in from the agent-island research bundle (2026-09-25); adds com.nathan.agent-island and
explicit exit codes.

usage: nc-agent-audit.py [--since 'YYYY-MM-DD HH:MM'] [--log FILE]
exit:  0 no agent records, 1 agent records found, 2 no usernoted database,
       3 database unreadable (Full Disk Access), 64 usage error
--log appends new records to a JSONL file, unioned by uuid (the database keeps only
undismissed records, so the trial loop runs this every 10 minutes).
"""
import argparse
import datetime
import json
import os
import plistlib
import shutil
import sqlite3
import sys
import tempfile

AGENT_APPS = {
    "com.openai.codex",
    "com.mitchellh.ghostty",
    "com.anthropic.claudefordesktop",
    "com.nathan.agentsignalsnotifier",
    "com.nathan.agent-island",
    "fr.julienxx.oss.terminal-notifier",
    "com.apple.scripteditor2",
}
# terminal-notifier and Script Editor carry non-agent jobs too: count them only when the text looks agent-ish.
TEXT_FILTERED_APPS = ("fr.julienxx.oss.terminal-notifier", "com.apple.scripteditor2")
AGENT_WORDS = ("claude", "codex", "herdr", "agent", "finished", "needs")
EPOCH = 978307200  # 2001-01-01T00:00:00Z, the usernoted date reference, in Unix time
SOURCE = os.path.expanduser("~/Library/Group Containers/group.com.apple.usernoted/db2")
# datetime.fromtimestamp raises OSError/OverflowError/ValueError well before real dates get
# anywhere close to this (fix round 1, Finding 1): a corrupt or absurd delivered_date must not
# crash the whole audit. 2_000_000_000 is a Unix timestamp in 2033, far past any real notification.
MAX_TIMESTAMP = 2_000_000_000


class UsageParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print("nc-agent-audit: %s" % message, file=sys.stderr)
        sys.exit(64)


def read_records(since):
    """Copies the usernoted database and returns its matching rows. Raises FileNotFoundError
    when there is no database, and OSError (including a TCC/Full-Disk-Access denial) or
    sqlite3.Error on any other read failure. mkdtemp lives here, inside the caller's try, so a
    failure between mkdtemp and the copy still exits 3 instead of an uncaught traceback."""
    os.stat(os.path.join(SOURCE, "db"))  # FileNotFoundError if missing; else the real OSError, if any
    tmp = tempfile.mkdtemp()
    try:
        for name in ("db", "db-wal", "db-shm"):
            path = os.path.join(SOURCE, name)
            if os.path.exists(path):
                shutil.copy2(path, os.path.join(tmp, name))
        con = sqlite3.connect("file:%s/db?mode=ro" % tmp, uri=True)
        try:
            return con.execute(
                "select hex(r.uuid), a.identifier, coalesce(r.delivered_date, r.request_date), r.data "
                "from record r join app a using(app_id) "
                "where coalesce(r.delivered_date, r.request_date, 0) >= ?",
                (since,),
            ).fetchall()
        finally:
            con.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def format_delivered(delivered):
    """usernoted date -> (ISO 8601 text, was_clamped). Clamps to fromtimestamp's representable
    range instead of raising on a corrupt or absurd delivered_date (Finding 1's reproduction): a
    bad date must change the printed date, never whether the record is counted, because dropping
    it would silently hide a real agent-island hit — the exact failure this fix closes."""
    value = (delivered or 0) + EPOCH
    clamped = max(0.0, min(float(value), float(MAX_TIMESTAMP)))
    try:
        return datetime.datetime.fromtimestamp(clamped).isoformat(timespec="seconds"), clamped != value
    except (OSError, OverflowError, ValueError):
        return "1970-01-01T00:00:00", True


def run(args, since):
    try:
        rows = read_records(since)
    except FileNotFoundError:
        print("nc-agent-audit: no usernoted database")
        return 2
    except (OSError, sqlite3.Error) as err:
        print("nc-agent-audit: cannot read usernoted database (%s); grant Full Disk Access to this terminal"
              % type(err).__name__)
        return 3

    hits = []
    clamped_count = 0
    for uuid, app, delivered, data in rows:
        app_id = (app or "").lower()
        if app_id not in AGENT_APPS:
            continue
        try:
            req = plistlib.loads(data).get("req", {})
        except Exception:
            req = {}
        title = str(req.get("titl", ""))
        body = str(req.get("body", ""))
        if app_id in TEXT_FILTERED_APPS and not any(w in (title + body).lower() for w in AGENT_WORDS):
            continue
        delivered_text, was_clamped = format_delivered(delivered)
        if was_clamped:
            clamped_count += 1
        hits.append({"uuid": uuid, "app": app_id, "delivered": delivered_text, "title": title[:60]})

    if args.log:
        seen = set()
        if os.path.exists(args.log):
            with open(args.log) as handle:
                seen = {json.loads(line)["uuid"] for line in handle if line.strip()}
        with open(args.log, "a") as handle:
            for hit in hits:
                if hit["uuid"] not in seen:
                    handle.write(json.dumps(hit) + "\n")

    for hit in hits:
        print("%s  %-34s %s" % (hit["delivered"], hit["app"], hit["title"]))
    if clamped_count:
        print("nc-agent-audit: clamped %d record(s) with an out-of-range date (still counted)" % clamped_count,
              file=sys.stderr)
    print("agent records since %s: %d" % (args.since or "beginning", len(hits)))
    return 1 if hits else 0


def main():
    parser = UsageParser(description="Read-only Notification Center audit for agent apps.")
    parser.add_argument("--since", help="local time, 'YYYY-MM-DD HH:MM'")
    parser.add_argument("--log", help="append new records to this JSONL file (union by uuid)")
    args = parser.parse_args()
    since = 0
    if args.since:
        try:
            since = datetime.datetime.strptime(args.since, "%Y-%m-%d %H:%M").timestamp() - EPOCH
        except ValueError:
            parser.error("--since must look like 'YYYY-MM-DD HH:MM', got %r" % args.since)

    # Fix round 1, Finding 1: any unexpected failure must fail loudly (exit 3, one line) rather
    # than let an uncaught exception exit 1 with only a traceback — the same exit code as "agent
    # records found", which used to read as a silent PASS to the E2E driver.
    try:
        return run(args, since)
    except Exception as err:
        print("nc-agent-audit: unexpected failure (%s: %s)" % (type(err).__name__, err))
        return 3


if __name__ == "__main__":
    sys.exit(main())
