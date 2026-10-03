#!/usr/bin/env python3
"""Convert a private Herdr research log into a masked replay fixture (JSON Lines).

Usage:
  mask-herdr-log.py sub2 RAW OUT     convert a subscriber/poller log (sub2-events.log format)
  mask-herdr-log.py poll RAW OUT     convert a poll log (poll.log format)
  mask-herdr-log.py --check OUT      verify OUT holds only allowed ops, keys and characters

This tool contains no captured data. It keeps only pane ids, workspace ids, agent status,
state_change_seq and focus; every title, cwd, label, text and wall-clock time is dropped. `at` is
seconds since the first line of RAW (runs of a multi-run log are placed at their wall-clock offset,
always after the previous run).

Output ops, one JSON object per line (keys in this order):
  {"at":0,"op":"state","panes":[{"pane_id":..,"workspace_id":..,"status":..,"seq":..,"focused":..}],"focused_pane_id":..}
  {"at":81.22,"op":"status","pane_id":..,"status":..}
  {"at":..,"op":"created","pane_id":..,"workspace_id":..}
  {"at":..,"op":"closed","pane_id":..}
  {"op":"reconnect"}
Conversion (sub2): [init] starts a run with an empty pane model; consecutive [poll] lines less than
1 s apart form one `state` op carrying the whole model (the poller's view: `now` tuples, `gone`
removals, `focus` tuples); pane.agent_status_changed events become `status` ops; pane_created and
pane_closed events become `created`/`closed` ops; every other event, ack and non-JSON line is dropped;
a "---- run N" separator line becomes `reconnect`. Conversion (poll): each time line plus its
"pane=status@seq" line becomes one `state` op with focused false and focused_pane_id null.
Known-pane rule (both formats): a `created` op never names a pane the replay already knows. The known
set is the panes of the last `state` op plus later `created` minus later `closed` (`status` and
`reconnect` leave it alone); a `created` op for a known pane is dropped, and --check rejects one.
Replay drivers rely on this: every `created` pane starts `idle`.
"""
import json
import re
import sys

ALLOWED_KEYS = {"at", "op", "panes", "pane_id", "workspace_id", "status", "seq", "focused", "focused_pane_id"}
ALLOWED_OPS = {"state", "status", "created", "closed", "reconnect"}
ALLOWED_STATUS = {"idle", "working", "blocked", "done", "unknown"}
ALLOWED_CHARS = re.compile(r'^[A-Za-z0-9:._" ,{}\[\]-]*$')
PANE_ID = re.compile(r"^w[0-9A-Za-z]+:p[0-9A-Za-z]+$")
WORKSPACE_ID = re.compile(r"^w[0-9A-Za-z]+$")
SUB2_LINE = re.compile(r"^(\d\d):(\d\d):(\d\d) \+\s*([0-9.]+) \[([^\]]+)\] (.*)$")
RUN_SEPARATOR = re.compile(r"^-{2,}\s*run\b")
POLL_TIME = re.compile(r"^(\d\d):(\d\d):(\d\d)$")
POLL_TOKEN = re.compile(r"^(w[0-9A-Za-z]+:p[0-9A-Za-z]+)=([a-z]+)@(\d+)$")


def seconds(h, m, s):
    return int(h) * 3600 + int(m) * 60 + int(s)


def number(value):
    value = round(value, 2)
    return int(value) if value == int(value) else value


def workspace_of(pane_id):
    return pane_id.split(":", 1)[0]


def dump(op):
    return json.dumps(op, separators=(",", ":"), ensure_ascii=True)


def state_op(at, model, focused_pane_id):
    panes = [{"pane_id": pane_id, "workspace_id": workspace_of(pane_id), "status": entry["status"],
              "seq": entry["seq"], "focused": entry["focused"]} for pane_id, entry in model.items()]
    return {"at": number(at), "op": "state", "panes": panes, "focused_pane_id": focused_pane_id}


def created_for_known_panes(ops):
    """Indexes of `created` ops whose pane the replay already knows (see the known-pane rule)."""
    known = set()
    found = []
    for index, op in enumerate(ops):
        kind = op.get("op")
        if kind == "state":
            known = {pane.get("pane_id") for pane in op.get("panes", []) if isinstance(pane, dict)}
        elif kind == "created":
            if op.get("pane_id") in known:
                found.append(index)
            known.add(op.get("pane_id"))
        elif kind == "closed":
            known.discard(op.get("pane_id"))
    return found


def drop_created_for_known_panes(ops):
    dropped = set(created_for_known_panes(ops))
    return [op for index, op in enumerate(ops) if index not in dropped]


def convert_sub2(lines):
    ops = []
    first_wall = None
    run_offset = 0.0
    last_at = -1.0
    model = {}
    focused = None
    group_start = None       # `at` of the open poll group, or None

    def flush():
        nonlocal group_start
        if group_start is not None:
            ops.append(state_op(group_start, model, focused))
            group_start = None

    for raw_line in lines:
        line = raw_line.rstrip("\n")
        if RUN_SEPARATOR.match(line):
            flush()
            ops.append({"op": "reconnect"})
            continue
        match = SUB2_LINE.match(line)
        if not match:
            continue
        h, m, s, rel, tag, payload = match.groups()
        wall = seconds(h, m, s)
        if first_wall is None:
            first_wall = wall
        if tag == "init":
            flush()
            elapsed = (wall - first_wall) % 86400
            run_offset = max(float(elapsed), last_at + 1.0) if ops else 0.0
            model = {}
            focused = None
        at = run_offset + float(rel)
        last_at = max(last_at, at)
        if tag == "poll":
            try:
                data = json.loads(payload)
            except ValueError:
                continue
            if not isinstance(data, dict):
                continue
            if group_start is not None and at - group_start >= 1.0:
                flush()
            if group_start is None:
                group_start = at
            if "focus" in data:
                focus = data["focus"]
                pane = focus[2] if isinstance(focus, list) and len(focus) == 3 else None
                focused = pane if isinstance(pane, str) and PANE_ID.match(pane) else None
            elif "gone" in data:
                model.pop(data.get("pane"), None)
            elif isinstance(data.get("now"), list) and len(data["now"]) >= 4:
                pane_id = data.get("pane")
                agent, status, seq, is_focused = data["now"][:4]
                if isinstance(pane_id, str) and PANE_ID.match(pane_id) and status in ALLOWED_STATUS:
                    model[pane_id] = {"status": status, "seq": int(seq or 0), "focused": bool(is_focused)}
            continue
        if tag in ("init", "done"):
            flush()
            continue
        # A subscriber tag ([subA], [subB:<pane>]): events only.
        flush()
        try:
            data = json.loads(payload)
        except ValueError:
            continue
        if not isinstance(data, dict) or "event" not in data:
            continue
        name = str(data["event"]).replace(".", "_")
        body = data.get("data") or {}
        if name == "pane_agent_status_changed":
            pane_id, status = body.get("pane_id"), body.get("agent_status")
            if isinstance(pane_id, str) and PANE_ID.match(pane_id) and status in ALLOWED_STATUS:
                ops.append({"at": number(at), "op": "status", "pane_id": pane_id, "status": status})
        elif name == "pane_created":
            pane = body.get("pane") or {}
            pane_id = pane.get("pane_id")
            if isinstance(pane_id, str) and PANE_ID.match(pane_id):
                ops.append({"at": number(at), "op": "created", "pane_id": pane_id, "workspace_id": workspace_of(pane_id)})
        elif name == "pane_closed":
            pane_id = body.get("pane_id")
            if isinstance(pane_id, str) and PANE_ID.match(pane_id):
                ops.append({"at": number(at), "op": "closed", "pane_id": pane_id})
    flush()
    return ops


def convert_poll(lines):
    ops = []
    first = None
    pending_at = None
    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            continue
        time_match = POLL_TIME.match(line)
        if time_match:
            wall = seconds(*time_match.groups())
            if first is None:
                first = wall
            pending_at = float((wall - first) % 86400)
            continue
        if pending_at is None:
            continue
        model = {}
        for token in line.split():
            token_match = POLL_TOKEN.match(token)
            if token_match and token_match.group(2) in ALLOWED_STATUS:
                model[token_match.group(1)] = {"status": token_match.group(2), "seq": int(token_match.group(3)),
                                               "focused": False}
        ops.append(state_op(pending_at, model, None))
        pending_at = None
    return ops


def check(path):
    problems = []
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    if not lines:
        problems.append("empty file")
    parsed = []   # (line number, op) for every line that parsed as a known op
    for number_, line in enumerate(lines, start=1):
        if not ALLOWED_CHARS.match(line):
            problems.append("line %d: character outside the allowed set" % number_)
            continue
        try:
            op = json.loads(line)
        except ValueError:
            problems.append("line %d: not JSON" % number_)
            continue
        if not isinstance(op, dict) or op.get("op") not in ALLOWED_OPS:
            problems.append("line %d: unknown op" % number_)
            continue
        parsed.append((number_, op))
        objects = [op] + [pane for pane in op.get("panes", []) if isinstance(pane, dict)]
        for obj in objects:
            extra = set(obj) - ALLOWED_KEYS
            if extra:
                problems.append("line %d: key(s) not allowed: %s" % (number_, ", ".join(sorted(extra))))
            for key in ("pane_id", "focused_pane_id"):
                if obj.get(key) is not None and not PANE_ID.match(str(obj[key])):
                    problems.append("line %d: malformed %s" % (number_, key))
            if "workspace_id" in obj and not WORKSPACE_ID.match(str(obj["workspace_id"])):
                problems.append("line %d: malformed workspace_id" % number_)
            if "status" in obj and obj["status"] not in ALLOWED_STATUS:
                problems.append("line %d: unknown status" % number_)
    for index in created_for_known_panes([op for _, op in parsed]):
        problems.append("line %d: created op names a pane the replay already knows" % parsed[index][0])
    return problems


def main(argv):
    if len(argv) == 3 and argv[1] == "--check":
        problems = check(argv[2])
        if problems:
            for problem in problems[:20]:
                print("mask-herdr-log: FAIL: " + problem, file=sys.stderr)
            return 1
        with open(argv[2], "r", encoding="utf-8") as handle:
            count = sum(1 for line in handle if line.strip())
        print("mask-herdr-log: OK (%d ops)" % count)
        return 0
    if len(argv) == 4 and argv[1] in ("sub2", "poll"):
        with open(argv[2], "r", encoding="utf-8") as handle:
            lines = handle.readlines()
        ops = convert_sub2(lines) if argv[1] == "sub2" else convert_poll(lines)
        ops = drop_created_for_known_panes(ops)
        with open(argv[3], "w", encoding="utf-8") as handle:
            for op in ops:
                handle.write(dump(op) + "\n")
        problems = check(argv[3])
        if problems:
            for problem in problems[:20]:
                print("mask-herdr-log: FAIL: " + problem, file=sys.stderr)
            return 1
        print("mask-herdr-log: wrote %d ops to %s" % (len(ops), argv[3]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
