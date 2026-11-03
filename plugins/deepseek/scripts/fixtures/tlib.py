#!/usr/bin/env python3
"""Helpers for test-deepseek-review.sh.

Every check subcommand prints one line per problem it found and exits 1 if there was any, 0
otherwise (printing nothing on success unless stated). The harness turns a non-zero exit into a
case failure carrying the printed lines.

Subcommands
  scenario OUT KIND [key=value ...]     write a stub scenario.json
  codes FAIL|ERROR                      stdin = stderr; print the sorted unique codes
  find-records KIND|any DIR...          print stub record paths (KIND = record|version)
  rec RECORD FIELD                      print a record field as JSON
  final-text RECORD OUTFILE [sigterm]   write the final event's text + "\\n" to OUTFILE
  env-check RECORD OUT key=value ...    the child env allowlist (keylen=N|absent)
  argv-exact RECORD OUT N [SESSION_ID]  record argv[2:] equals the contract argv
  argv-vs-pinv RECORD PINV OUT          record argv[2:] equals --print-invocation argv[5:]
  pinv-check PINV key=value ...         --print-invocation JSON structure and content
  patch-sha OUT PINV                    patch files in OUT hash as --print-invocation says
  status-check STATUS key=json ...      status-N.json key values (key 'keys' = all keys present)
  status-reasons STATUS                 print "<verdict> <sorted reasons>"
  modes DIR MIN                         every dir 0700, every file 0600, at least MIN entries
  tree-hash DIR                         one sha256 over every path, mode and content
  fence-check FENCE REPO OUT DSH NODE HOME [N]   (N = attempt, default 1)
  ref-fence REPO OUT DSH NODE [N]       a contract fence for attempt N (META use)
  patch-reads RECORD PATH...            record patch_reads has exactly PATHs, each OK
  grep-absent NEEDLE PATH...            NEEDLE in no file under any PATH
  dump-check DUMP REVIEW_PATCH          real dsh --dump-config output
  requests-check LOG                    real dsh requests captured by mock-messages.py
  fabricate OUT RUNJSONL ERR RC NONCE REPO
  usage-sum RUNJSONL                    print the summed step_end usage as JSON
  nul-argv FILE                         print a NUL-delimited argv capture as a JSON list
  fab-stream OUT NONCE VARIANT [k=v]    a dsh-shaped NDJSON stream for --check (see cmd_fab_stream)
"""
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys

PINNED = "0.2.1-rc.5"
ENV_ALLOWED = {"PATH", "HOME", "DSH_HOME", "TMPDIR", "DSH_TELEMETRY_DISABLED",
               "DSH_PERMISSION_MODE", "DEEPSEEK_API_KEY", "LANG",
               # Set inside the node process by CoreFoundation when absent (observed on
               # Darwin 23.5 with node 25.2.1, also with env -i). Its VALUE proves it did not
               # come from the caller: see env-check cf_sentinel=.
               "__CF_USER_TEXT_ENCODING"}
CHILD_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def fail(problems):
    for p in problems:
        print(p)
    sys.exit(1 if problems else 0)


def kv(args):
    out = {}
    for a in args:
        k, _, v = a.partition("=")
        out.setdefault(k, []).append(v)
    return out


def real(p):
    return os.path.realpath(p)


def load_json(path):
    with open(path, "rb") as f:
        return json.loads(f.read().decode("utf-8"))


# --------------------------------------------------------------------------------------------
# scenarios

FINAL_OK = "Stub review: the change looks fine.\nVERDICT-{NONCE}: NO FINDINGS"
USAGE = {"inputTokens": 11, "outputTokens": 42, "cacheReadTokens": 3, "totalTokens": 56}


def tool_pair(i, tool, target, status):
    cid = f"toolu_{i}"
    inp = ({"file_path": target} if tool in ("read", "edit")
           else {"pattern": "SENTINEL", "path": target})
    if status == "completed":
        res = f"<path>{target}</path>\n<type>file</type>\n<content>\n1: STUB CONTENT\n</content>"
    else:
        res = f"Error: EPERM: operation not permitted, open '{target}'"
    return [{"type": "tool_call", "callId": cid, "tool": tool, "input": inp},
            {"type": "tool_result", "callId": cid, "status": status, "result": res}]


def stream(sid, tools, final, turn_reason=None):
    ev = [{"type": "session", "sessionId": sid, "cwd": "{CWD}"},
          {"type": "status", "phase": "turn_start", "turn": 1},
          {"type": "status", "phase": "step_start", "turn": 1, "step": 1},
          {"type": "thinking", "text": "stub thinking"}]
    for i, (tool, target, status) in enumerate(tools, 1):
        ev += tool_pair(i, tool, target, status)
    ev += [{"type": "status", "phase": "step_end", "turn": 1, "step": 1, "usage": dict(USAGE)},
           {"type": "status", "phase": "step_start", "turn": 1, "step": 2},
           {"type": "text", "text": final},
           {"type": "status", "phase": "step_end", "turn": 1, "step": 2, "usage": dict(USAGE)},
           {"type": "status", "phase": "turn_end", "turn": 1,
            "reason": turn_reason or {"kind": "completed"}},
           {"type": "final", "text": final}]
    return ev


def idx(ev, pred):
    for i, e in enumerate(ev):
        if isinstance(e, dict) and pred(e):
            return i
    raise SystemExit("scenario builder: event not found")


EARLY_FINAL = {"type": "final", "text": "Early answer.\nVERDICT-{NONCE}: FINDINGS"}


def swap_pairs(ev):
    """Put each tool_result before the tool_call that carries its callId."""
    i = 0
    while i < len(ev) - 1:
        a, b = ev[i], ev[i + 1]
        if (isinstance(a, dict) and isinstance(b, dict) and a.get("type") == "tool_call"
                and b.get("type") == "tool_result" and a.get("callId") == b.get("callId")):
            ev[i], ev[i + 1] = b, a
            i += 2
        else:
            i += 1


def cmd_fab_stream(argv):
    """fab-stream OUTFILE NONCE VARIANT [read=PATH]... [cwd=DIR] [target=PATH]: a dsh-shaped
    NDJSON stream for --check on fabricated outs. VARIANT ok is a valid stream (reads, if given,
    completed); the others add one odd shape: input_str, cwd_int, nul_path, list_callid,
    two_finals, result_before_call; with read=: result_bad_callid, dup_call, dup_result,
    plain_read, dir_envelope, envelope_tail, error_envelope; sid (with sid=VALUE), sid_int."""
    path, nonce, variant = argv[0], argv[1], argv[2]
    o = kv(argv[3:])
    reads = o.get("read", [])
    target = o.get("target", ["/x/t.txt"])[0]
    final = f"Fabricated review.\nVERDICT-{nonce}: NO FINDINGS"
    ev = stream("session-fab-1", [("read", r, "completed") for r in reads], final)
    ev[0]["cwd"] = o.get("cwd", ["/x"])[0]
    t = idx(ev, lambda e: e.get("type") == "thinking") + 1

    def done(cid):
        # dsh's read envelope, so each odd shape is judged by its own guard, not by the envelope.
        return {"type": "tool_result", "callId": cid, "status": "completed",
                "result": f"<path>{target}</path>\n<type>file</type>\n<content>\n1: X\n</content>"}

    if variant == "ok":
        pass
    elif variant == "input_str":
        ev[t:t] = [{"type": "tool_call", "callId": "toolu_S", "tool": "read", "input": "x"}, done("toolu_S")]
    elif variant == "cwd_int":
        ev[0]["cwd"] = 123
        ev[t:t] = [{"type": "tool_call", "callId": "toolu_C", "tool": "read",
                    "input": {"file_path": "sentinel.txt"}}, done("toolu_C")]
    elif variant == "nul_path":
        ev[t:t] = [{"type": "tool_call", "callId": "toolu_N", "tool": "read",
                    "input": {"file_path": target + chr(0) + "x"}}, done("toolu_N")]
    elif variant == "list_callid":
        ev[t:t] = [{"type": "tool_call", "callId": [1], "tool": "read", "input": {"file_path": target}},
                   done([1])]
    elif variant == "two_finals":
        e = dict(EARLY_FINAL)
        e["text"] = e["text"].replace("{NONCE}", nonce)
        ev.insert(idx(ev, is_turn_end), e)
    elif variant == "result_before_call":
        swap_pairs(ev)
    # Round 3 #3-#6 (these need read=PATH: they change the first read's pair or the session).
    elif variant in ("result_bad_callid", "dup_call", "dup_result", "plain_read", "dir_envelope",
                     "envelope_tail", "error_envelope"):
        ci = idx(ev, lambda e: e.get("type") == "tool_call")
        ri = idx(ev, lambda e: e.get("type") == "tool_result")
        if variant == "result_bad_callid":
            ev[ri]["callId"] = None
        elif variant == "dup_call":
            ev.insert(ci + 1, dict(ev[ci]))
        elif variant == "dup_result":
            ev.insert(ri + 1, dict(ev[ri]))
        elif variant == "plain_read":
            ev[ri]["result"] = "1: STUB CONTENT"
        elif variant == "error_envelope":
            ev[ri]["status"] = "error"
        elif variant == "dir_envelope":
            ev[ri]["result"] = ev[ri]["result"].replace("<type>file</type>", "<type>directory</type>")
        else:
            ev[ri]["result"] += "\n(more)"
    elif variant == "sid":
        ev[0]["sessionId"] = o["sid"][0]
    elif variant == "sid_int":
        ev[0]["sessionId"] = 7
    else:
        raise SystemExit(f"fab-stream: unknown variant {variant}")
    with open(path, "w") as f:
        for e in ev:
            f.write(json.dumps(e) + "\n")


def is_turn_end(e):
    return e.get("type") == "status" and e.get("phase") == "turn_end"


def cmd_scenario(argv):
    out, kind, rest = argv[0], argv[1], argv[2:]
    o = kv(rest)
    tools = []
    for a in rest:
        k, _, v = a.partition("=")
        if k == "read":
            tools.append(("read", v, "completed"))
        elif k == "denied":
            tools.append(("read", v, "error"))
        elif k == "grep":
            tools.append(("grep", v, "completed"))
        elif k == "edit":  # a non-read tool whose input carries a file_path
            tools.append(("edit", v, "completed"))
    sid = o.get("sid", ["session-stub-0001"])[0]
    sc = {"version": o.get("version", [PINNED])[0], "stderr": "", "exit": 0,
          "probes": {"read": o.get("probe_read", []), "write": o.get("probe_write", [])}}
    final = FINAL_OK
    ev = None

    if kind in ("ok", "exit1", "killed", "compose_activate", "compose_notfound", "dotenv",
                "notjson", "notobject", "session_not_first", "no_session", "no_final",
                "final_not_last", "error_event", "no_turn_end"):
        ev = stream(sid, tools, final)
    if kind == "exit1":
        sc["exit"] = 1
    elif kind == "killed":
        sc["self_signal"] = "SIGKILL"
    elif kind == "compose_activate":
        sc["stderr"] = "dsh: warning: 1 entry did not activate\n"
    elif kind == "compose_notfound":
        sc["stderr"] = 'dsh: [/x/run-1.patch.yml] patch: entry "no-such-row" not found\n'
    elif kind == "dotenv":
        sc["stderr"] = ("dsh: failed to load .env: Error: EPERM: operation not permitted, "
                        "open '{CWD}/.env'\n")
    elif kind == "notjson":
        ev.insert(2, "this line is not json")
    elif kind == "notobject":
        ev.insert(2, "[1, 2, 3]")
    elif kind == "session_not_first":
        ev[0], ev[1] = ev[1], ev[0]
    elif kind == "no_session":
        ev.pop(0)
    elif kind == "no_final":
        ev.pop()
    elif kind == "final_not_last":
        ev.append({"type": "thinking", "text": "late event after final"})
    elif kind == "error_event":
        ev.insert(idx(ev, is_turn_end), {"type": "error", "message": "stub error event"})
    elif kind == "no_turn_end":
        ev.pop(idx(ev, is_turn_end))
    elif kind == "empty":
        ev = []
    elif kind == "blank_lines":
        ev = ["", "   ", ""]
    elif kind == "turn_max_tokens":
        ev = stream(sid, tools, final, {"kind": "max-tokens"})
    elif kind == "last_turn_not_completed":
        ev = stream(sid, tools, final)
        t = idx(ev, is_turn_end)
        ev[t + 1:t + 1] = [
            {"type": "status", "phase": "turn_start", "turn": 2},
            {"type": "status", "phase": "turn_end", "turn": 2,
             "reason": {"kind": "error", "error": {"message": "stub turn 2 failed",
                                                    "code": "PROVIDER_ERROR"}}}]
    elif kind == "refusal":
        ev = [{"type": "session", "sessionId": sid, "cwd": "{CWD}"},
              {"type": "status", "phase": "turn_start", "turn": 1},
              {"type": "status", "phase": "step_start", "turn": 1, "step": 1},
              {"type": "status", "phase": "step_end", "turn": 1, "step": 1},
              {"type": "status", "phase": "turn_end", "turn": 1, "reason": {
                  "kind": "error", "error": {
                      "message": "DeepSeek Messages stream: unsupported stop reason refusal",
                      "code": "MALFORMED_RESPONSE"}}},
              {"type": "final", "text": ""}]
        sc["exit"] = 1
        sc["stderr"] = ("dsh: MALFORMED_RESPONSE: DeepSeek Messages stream: unsupported stop "
                        "reason refusal\n")
    elif kind in ("final_blank", "verdict_missing", "verdict_wrong_nonce", "verdict_trailing",
                  "verdict_bad_word", "verdict_dup_other", "verdict_dup_same",
                  "verdict_trailing_blank", "findings", "denied_all", "verdict_suffix"):
        final = {
            "final_blank": "   \n  ",
            "verdict_missing": "Stub review: the change looks fine.",
            "verdict_wrong_nonce": "Stub review.\nVERDICT-0123456789abcdef: NO FINDINGS",
            "verdict_trailing": "Stub review.\nVERDICT-{NONCE}: NO FINDINGS\nThanks!",
            "verdict_bad_word": "Stub review.\nVERDICT-{NONCE}: MAYBE",
            "verdict_suffix": "Stub review.\nVERDICT-{NONCE}: NO FINDINGS (pending a re-read)",
            "verdict_dup_other": ("Stub review.\nVERDICT-fedcba9876543210: FINDINGS\n"
                                  "VERDICT-{NONCE}: NO FINDINGS"),
            "verdict_dup_same": ("Stub review.\nVERDICT-{NONCE}: FINDINGS\n"
                                 "VERDICT-{NONCE}: NO FINDINGS"),
            "verdict_trailing_blank": "Stub review.\n- one finding\nVERDICT-{NONCE}: FINDINGS\n\n",
            "findings": "Stub review.\n- src/a.txt:1 is wrong\nVERDICT-{NONCE}: FINDINGS",
            "denied_all": "I could not access the files.\nVERDICT-{NONCE}: NO FINDINGS",
        }[kind]
        ev = stream(sid, tools, final)
    elif kind == "unmatched_callid":
        # The only completed tool_result answers a callId no read tool_call carries.
        ev = stream(sid, [], final)
        t = idx(ev, lambda e: e.get("type") == "thinking")
        target = o["read"][0]
        ev[t + 1:t + 1] = [
            {"type": "tool_call", "callId": "toolu_A", "tool": "read",
             "input": {"file_path": target}},
            {"type": "tool_result", "callId": "toolu_A", "status": "error",
             "result": f"Error: EPERM: operation not permitted, open '{target}'"},
            {"type": "tool_result", "callId": "toolu_B", "status": "completed",
             "result": f"<path>{target}</path>\n<type>file</type>\n<content>\n1: X\n</content>"}]
    elif kind == "trap":
        ev = []
        sc["on_sigterm"] = {"lines": stream(sid, tools, final), "exit": 0, "stderr": ""}
    elif kind in ("hang", "hang_ignore", "hang_noread"):
        ev = stream(sid, tools, final)[:2]
        sc["hang"] = True
        if kind == "hang_noread":
            sc["no_stdin"] = True
        if kind == "hang_ignore":
            sc["ignore_sigterm"] = True
            sc["grandchild_ignore_sigterm"] = True
    elif kind == "two_finals":
        # An earlier final event (its own valid VERDICT line) before the real last one.
        ev = stream(sid, tools, final)
        ev.insert(idx(ev, is_turn_end), dict(EARLY_FINAL))
    elif kind == "result_before_call":
        # Every tool_result comes BEFORE the tool_call carrying its callId.
        ev = stream(sid, tools, final)
        swap_pairs(ev)
    elif kind == "leak_key":
        # dsh echoes the key it got into an error event and a composition warning on stderr.
        ev = stream(sid, tools, final)
        ev.insert(idx(ev, is_turn_end), {"type": "error", "message": "provider rejected key {KEY}"})
        sc["stderr"] = 'dsh: [/x/run-1.patch.yml] patch: entry "{KEY}" not found\n'
    elif kind == "leak_key_final":
        final = "Key seen: {KEY}\nVERDICT-{NONCE}: NO FINDINGS"
        ev = stream(sid, tools, final)
    elif kind == "version_hang":
        ev = stream(sid, tools, final)
        sc["version_hang"] = True
    elif ev is None:
        raise SystemExit(f"scenario builder: unknown kind {kind}")
    # Round 3 #2: dsh's own copies of the key (session store, startup log, a temp file), a symlink
    # out of <out>, the key echoed on stdout (a thinking event) and stderr, and a startup scan.
    if o.get("plant_key") == ["1"]:
        sc["plant"] = [["{HOME}/sessions/x.jsonl", {"type": "error", "message": "session event holds {KEY}"}],
                       ["{HOME}/logs/startup-x.log", "startup failed: auth header {KEY}"],
                       ["{TMPDIR}/dsh-x/cache.txt", "cache {KEY}"]]
    if "link_out" in o:
        sc["links"] = [["{HOME}/link-out", o["link_out"][0]]]
    # A file holding the key that dsh left mode 0000, and a symlink to a dir outside <out>.
    if o.get("lock_key") == ["1"]:
        sc.setdefault("plant", []).append(["{HOME}/locked/k.log", "locked {KEY}"])
        sc["lock"] = ["{HOME}/locked/k.log"]
    if "link_dir" in o:
        sc.setdefault("links", []).append(["{HOME}/link-dir", o["link_dir"][0]])
    if o.get("echo_key") == ["1"]:
        ev.insert(1, {"type": "thinking", "text": "using key {KEY}"})
        sc["stderr"] = sc.get("stderr", "") + "dsh: debug: using key {KEY}\n"
    if o.get("key_scan") == ["1"]:
        sc["key_scan"] = True
    if "marker" in o:
        sc["grandchild_marker"] = o["marker"][0]
    if "vmarker" in o:
        sc["version_marker"] = o["vmarker"][0]
    sc["lines"] = ev
    with open(out, "w") as f:
        json.dump(sc, f, indent=1)


# --------------------------------------------------------------------------------------------
# simple readers

def cmd_codes(argv):
    want = argv[0]
    codes = set()
    for line in sys.stdin.read().splitlines():
        m = re.match(r"^deepseek-review: (FAIL|ERROR) ([A-Z][A-Z0-9_]*):", line)
        if m and m.group(1) == want:
            codes.add(m.group(2))
    print(" ".join(sorted(codes)))


def cmd_find_records(argv):
    kind, dirs = argv[0], argv[1:]
    hits = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for root, _dirs, files in os.walk(d):
            for f in files:
                m = re.match(r"^stub-(record|version)-\d+\.json$", f)
                if m and (kind == "any" or m.group(1) == kind):
                    hits.append(os.path.join(root, f))
    for h in sorted(hits):
        print(h)


def get_path(obj, dotted):
    for part in dotted.split("."):
        if isinstance(obj, list):
            obj = obj[int(part)]
        else:
            obj = obj[part]
    return obj


def cmd_rec(argv):
    print(json.dumps(get_path(load_json(argv[0]), argv[1])))


def final_of(text):
    final = None
    for line in text.splitlines():
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("type") == "final":
            final = o.get("text")
    return final


def cmd_final_text(argv):
    rec = load_json(argv[0])
    text = rec.get("emitted_sigterm") if len(argv) > 2 and argv[2] == "sigterm" else rec.get("emitted")
    final = final_of(text or "")
    if final is None:
        fail(["record has no final event in what the stub emitted"])
    with open(argv[1], "wb") as f:
        f.write((final + "\n").encode())


def cmd_usage_sum(argv):
    tot = {}
    with open(argv[0]) as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if isinstance(o, dict) and o.get("phase") == "step_end" and isinstance(o.get("usage"), dict):
                for k, v in o["usage"].items():
                    tot[k] = tot.get(k, 0) + v
    print(json.dumps(tot, sort_keys=True))


def cmd_nul_argv(argv):
    with open(argv[0], "rb") as f:
        parts = f.read().split(b"\0")
    if parts and parts[-1] == b"":
        parts.pop()
    print(json.dumps([p.decode("utf-8", "surrogateescape") for p in parts]))


# --------------------------------------------------------------------------------------------
# launch wiring

def contract_args(out, n, sid=None):
    a = ["--profile", "headless", "--patch", f"{out}/review.patch.yml",
         "--patch", f"{out}/run-{n}.patch.yml", "--json"]
    if sid:
        a += ["--session-id", sid]
    return a + ["-"]


def cmd_env_check(argv):
    rec, out = load_json(argv[0]), real(argv[1])
    o = kv(argv[2:])
    env = rec.get("env", {})
    p = []
    extra = sorted(set(env) - ENV_ALLOWED)
    if extra:
        p.append(f"child env has names outside the allowlist: {extra}")
    want = {"PATH": CHILD_PATH, "HOME": f"{out}/home", "DSH_HOME": f"{out}/home",
            "TMPDIR": f"{out}/tmp", "DSH_TELEMETRY_DISABLED": "1",
            "DSH_PERMISSION_MODE": "read-only"}
    for k, v in want.items():
        if env.get(k) != v:
            p.append(f"child env {k}={env.get(k)!r}, expected {v!r}")
    keylen = o.get("keylen", [None])[0]
    if keylen == "absent":
        if "DEEPSEEK_API_KEY" in env:
            p.append(f"child env has DEEPSEEK_API_KEY {env['DEEPSEEK_API_KEY']!r}, expected it absent")
    elif keylen is not None:
        if env.get("DEEPSEEK_API_KEY") != {"present": True, "length": int(keylen)}:
            p.append(f"child DEEPSEEK_API_KEY {env.get('DEEPSEEK_API_KEY')!r}, expected length {keylen}")
    lang = o.get("lang", [None])[0]
    if lang == "none":
        if "LANG" in env:
            p.append(f"child env has LANG={env['LANG']!r} though the caller set none")
    elif lang is not None and env.get("LANG") != lang:
        p.append(f"child LANG={env.get('LANG')!r}, expected {lang!r}")
    cf = o.get("cf_sentinel", [None])[0]
    if cf is not None and env.get("__CF_USER_TEXT_ENCODING") == cf:
        p.append("child __CF_USER_TEXT_ENCODING carries the caller's sentinel value")
    for needle in o.get("forbid", []):
        for k, v in env.items():
            if needle in k or needle in json.dumps(v):
                p.append(f"child env leaks {needle!r} via {k}")
    fail(p)


def cmd_argv_exact(argv):
    rec, out, n = load_json(argv[0]), real(argv[1]), argv[2]
    sid = argv[3] if len(argv) > 3 else None
    got, want = rec.get("argv", [])[2:], contract_args(out, n, sid)
    fail([] if got == want else [f"stub argv[2:]\n      got:  {got}\n      want: {want}"])


def cmd_argv_vs_pinv(argv):
    rec, pinv, out = load_json(argv[0]), load_json(argv[1]), real(argv[2])
    got = rec.get("argv", [])[2:]
    want = [a.replace("{OUT}", out) for a in pinv.get("argv", [])[5:]]
    fail([] if got == want and got else [f"stub argv[2:] != print-invocation argv[5:]\n"
                                         f"      stub: {got}\n      pinv: {want}"])


def rows(text):
    """Minimal reader for dsh row YAML: [{'id':..., 'disabled':..., 'config':{flat scalars}}]."""
    out, cur, in_cfg = [], None, False
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = re.match(r"^- id: (.+)$", line)
        if m:
            cur = {"id": m.group(1).strip().strip("'\""), "config": {}}
            out.append(cur)
            in_cfg = False
            continue
        if cur is None:
            continue
        m = re.match(r"^  (\w[\w-]*):\s*(.*)$", line)
        if m:
            in_cfg = m.group(1) == "config" and m.group(2) == ""
            if m.group(1) == "disabled":
                cur["disabled"] = m.group(2).strip()
            continue
        m = re.match(r"^    (\w[\w-]*):\s*(.*)$", line)
        if m and in_cfg:
            cur["config"][m.group(1)] = scalar(m.group(2))
    return out


def scalar(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v[1:-1]
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v


def run_patch_problems(text, model, effort, max_tokens):
    p = []
    r = {x["id"]: x for x in rows(text)}
    adm = r.get("agent-default-model", {}).get("config")
    if adm != {"provider": "deepseek-official", "model": model}:
        p.append(f"run patch agent-default-model config {adm!r}")
    llm = r.get("llm-deepseek", {}).get("config")
    want = {"baseURL": "https://api.deepseek.com/anthropic", "apiKeyEnv": "DEEPSEEK_API_KEY",
            "reasoningEffort": effort, "maxTokens": int(max_tokens)}
    if llm != want:
        p.append(f"run patch llm-deepseek config {llm!r}, expected {want!r}")
    if set(r) != {"agent-default-model", "llm-deepseek"}:
        p.append(f"run patch rows {sorted(r)}, expected exactly agent-default-model and llm-deepseek")
    return p


def cmd_pinv_check(argv):
    try:
        pinv = load_json(argv[0])
    except (OSError, ValueError) as e:
        fail([f"--print-invocation output is not JSON: {type(e).__name__}"])
    o = {k: v[0] for k, v in kv(argv[1:]).items()}
    p = []
    if not isinstance(pinv, dict):
        fail(["--print-invocation output is not a JSON object"])
    want_keys = {"argv", "cwd", "env_names", "patches"}
    if set(pinv) != want_keys:
        p.append(f"top-level keys {sorted(pinv)}, expected {sorted(want_keys)}")
    want_argv = (["/usr/bin/sandbox-exec", "-f", "{OUT}/fence-1.sb", o["node"],
                  f"{o['dsh']}/node_modules/@deepseek-ai/dsh/lib/bin.js"]
                 + contract_args("{OUT}", 1))
    if pinv.get("argv") != want_argv:
        p.append(f"argv\n      got:  {pinv.get('argv')}\n      want: {want_argv}")
    if pinv.get("cwd") != o["cwd"]:
        p.append(f"cwd {pinv.get('cwd')!r}, expected {o['cwd']!r}")
    names = ["DEEPSEEK_API_KEY", "DSH_HOME", "DSH_PERMISSION_MODE", "DSH_TELEMETRY_DISABLED",
             "HOME", "PATH", "TMPDIR"] + (["LANG"] if o.get("lang") == "yes" else [])
    if pinv.get("env_names") != sorted(names):
        p.append(f"env_names {pinv.get('env_names')}, expected {sorted(names)}")
    patches = pinv.get("patches") if isinstance(pinv.get("patches"), dict) else {}
    if set(patches) != {"review.patch.yml", "run-1.patch.yml"}:
        p.append(f"patches keys {sorted(patches)}")
    for name, ent in patches.items():
        c = ent.get("content", "") if isinstance(ent, dict) else ""
        if not isinstance(ent, dict) or ent.get("sha256") != hashlib.sha256(c.encode()).hexdigest():
            p.append(f"patches[{name}].sha256 does not hash its content")
    with open(o["review"], "rb") as f:
        if patches.get("review.patch.yml", {}).get("content", "").encode() != f.read():
            p.append("review.patch.yml content differs from plugins/deepseek/dsh/review.patch.yml")
    run1 = patches.get("run-1.patch.yml", {}).get("content", "")
    p += run_patch_problems(run1, o["model"], o["effort"], o["max"])
    fail(p)


def cmd_patch_sha(argv):
    out, pinv = argv[0], load_json(argv[1])
    p = []
    for name in ("review.patch.yml", "run-1.patch.yml"):
        try:
            with open(os.path.join(out, name), "rb") as f:
                h = hashlib.sha256(f.read()).hexdigest()
        except OSError:
            p.append(f"{name} missing in out dir")
            continue
        if h != pinv.get("patches", {}).get(name, {}).get("sha256"):
            p.append(f"{name} sha256 {h} != print-invocation's")
    fail(p)


# --------------------------------------------------------------------------------------------
# status, modes, hashes

STATUS_KEYS = {"attempt", "dsh_version", "model", "model_source", "effort", "max_tokens", "nonce",
               "repo", "repo_mode", "expect_read", "session_id", "argv", "patch_sha256",
               "started_at", "ended_at", "wall_seconds", "exit_code", "signal", "cancelled",
               "cancel_reason", "verdict", "reasons", "usage"}


def cmd_status_check(argv):
    try:
        st = load_json(argv[0])
    except (OSError, ValueError) as e:
        fail([f"{os.path.basename(argv[0])} unreadable: {type(e).__name__}"])
    p = []
    for a in argv[1:]:
        k, _, v = a.partition("=")
        if k == "keys":
            missing = sorted(STATUS_KEYS - set(st))
            if missing:
                p.append(f"status lacks keys {missing}")
            continue
        want = json.loads(v)
        if st.get(k, "<absent>") != want:
            p.append(f"status {k}={st.get(k, '<absent>')!r}, expected {want!r}")
    fail(p)


def cmd_status_reasons(argv):
    try:
        st = load_json(argv[0])
    except (OSError, ValueError):
        print("<no-status>")
        return
    print(f"{st.get('verdict')} {' '.join(sorted(st.get('reasons') or []))}".strip())


def cmd_modes(argv):
    top, minimum = argv[0], int(argv[1])
    p, n = [], 0
    if not os.path.isdir(top):
        fail([f"{top} is not a directory"])
    for root, dirs, files in os.walk(top):
        for name in [None] + dirs + files:
            path = root if name is None else os.path.join(root, name)
            if name is None and root != top:
                continue
            st = os.lstat(path)
            n += 1
            mode = stat.S_IMODE(st.st_mode)
            if stat.S_ISDIR(st.st_mode) and mode != 0o700:
                p.append(f"dir {os.path.relpath(path, top)} mode {mode:o}")
            elif stat.S_ISREG(st.st_mode) and mode != 0o600:
                p.append(f"file {os.path.relpath(path, top)} mode {mode:o}")
            elif stat.S_ISLNK(st.st_mode):
                p.append(f"symlink {os.path.relpath(path, top)}")
    if n < minimum:
        p.append(f"only {n} entries under {top}, expected at least {minimum}")
    fail(p)


def cmd_tree_hash(argv):
    h = hashlib.sha256()
    top = argv[0]
    for root, dirs, files in os.walk(top):
        dirs.sort()
        for name in sorted(dirs + files):
            path = os.path.join(root, name)
            st = os.lstat(path)
            h.update(f"{os.path.relpath(path, top)}\0{st.st_mode:o}\0".encode())
            if stat.S_ISREG(st.st_mode):
                with open(path, "rb") as f:
                    h.update(hashlib.sha256(f.read()).digest())
    print(h.hexdigest())


def cmd_grep_absent(argv):
    needle, paths = argv[0].encode(), argv[1:]
    hits, n = [], 0
    for top in paths:
        walk = [(os.path.dirname(top), [], [os.path.basename(top)])] if os.path.isfile(top) else os.walk(top)
        for root, _d, files in walk:
            for f in files:
                path = os.path.join(root, f)
                try:
                    with open(path, "rb") as fh:
                        data = fh.read()
                except OSError:
                    continue
                n += 1
                if needle in data:
                    hits.append(path)
    fail([f"{argv[0]!r} found in {h}" for h in hits])


# --------------------------------------------------------------------------------------------
# fence

def sexprs(text):
    toks = re.findall(r';[^\n]*|#"(?:[^"\\]|\\.)*"|"(?:[^"\\]|\\.)*"|[()]|[^\s()";]+', text)
    stack, top = [], []
    cur = top
    for t in toks:
        if t.startswith(";"):
            continue
        if t == "(":
            new = []
            cur.append(new)
            stack.append(cur)
            cur = new
        elif t == ")":
            if not stack:
                raise ValueError("unbalanced )")
            cur = stack.pop()
        elif t.startswith('#"'):
            cur.append(("re", t[2:-1]))
        elif t.startswith('"'):
            cur.append(("str", re.sub(r'\\(.)', r'\1', t[1:-1])))
        else:
            cur.append(t)
    if stack:
        raise ValueError("unbalanced (")
    return top


def flatten_filters(filters):
    out = []
    for f in filters:
        if isinstance(f, list) and f and f[0] in ("require-any",):
            out += flatten_filters(f[1:])
        else:
            out.append(f)
    return out


def node_lib_dirs(node):
    dirs = set()
    try:
        lines = subprocess.run(["otool", "-L", node], capture_output=True, text=True,
                               check=True).stdout.splitlines()[1:]
    except (OSError, subprocess.CalledProcessError):
        lines = []
    for line in lines:
        path = line.strip().split(" (")[0]
        if path.startswith(("/usr/lib/", "/System/", "@")):
            continue
        dirs.add(os.path.dirname(path))
        dirs.add(os.path.dirname(real(path)))
    for d in list(dirs):
        m = re.match(r"^(.*)/Cellar/openssl@3/", real(d) + "/")
        if m:
            etc = m.group(1) + "/etc/openssl@3"
            dirs.add(etc)
            cert = os.path.join(etc, "cert.pem")
            if os.path.exists(cert):
                dirs.add(os.path.dirname(real(cert)))
    return dirs


BROAD = {"/", "/usr", "/usr/local", "/opt", "/opt/homebrew", "/Users", "/private", "/var",
         "/private/var", "/tmp", "/private/tmp", "/etc", "/private/etc"}
SECRET_DIRS = (".ssh", ".gnupg", ".aws", ".config", ".dsh", ".claude", ".codex", ".gemini",
               ".kimi-code", "Library")
# Names under the repo the .env deny must cover (any depth), and names it must leave readable.
ENV_DENY = [".env", ".env.local", "src/.env", ".envrc", ".env-prod", ".env_local", ".environment",
            "sub/.envrc", "prod.env", "sub/x.env", ".env.example"]
ENV_ALLOW = ["environment.md", "envoy.yaml", "src/env.ts", "x.env.example", "sentinel.txt", "src/a.txt",
             "envrc", "sub/dotenv.txt"]


def pw_home():
    import pwd
    return real(pwd.getpwuid(os.getuid()).pw_dir)


def inside(c, p):
    return c == p or c.startswith(p.rstrip("/") + "/")


def unsafe_kind(d, homes):
    """None, 'child' (a direct child of a home) or a reason the dir may never be granted whole:
    broad, a home or an ancestor of one, or overlapping a home's secret dir."""
    if d in BROAD:
        return "a broad system dir"
    child = None
    for h in homes:
        if inside(h, d):
            return f"the home {h} or an ancestor of it"
        for s in SECRET_DIRS:
            for sd in {os.path.join(h, s), real(os.path.join(h, s))}:
                if inside(d, sd) or inside(sd, d):
                    return f"overlapping the secret dir {sd}"
        if os.path.dirname(d) == h:
            child = "child"
    return child


def cmd_fence_check(argv):
    fence, repo, out, dsh, node, home = argv[0], *(real(a) for a in argv[1:6])
    n = argv[6] if len(argv) > 6 else "1"
    homes = {home, pw_home()}
    # dsh reads its two --patch overlays at the top of <out>: exactly these two literals, for
    # this attempt only; anything else at the top of <out> (prompt, stream, status, fence,
    # another attempt's run patch) stays unreadable.
    overlay_lit = {f"{out}/review.patch.yml", f"{out}/run-{n}.patch.yml"}
    overlay_seen = set()
    try:
        with open(fence) as f:
            tree = sexprs(f.read())
    except (OSError, ValueError) as e:
        fail([f"fence unreadable: {e}"])
    # Node: its prefix when that is safe; otherwise its bin dir and <prefix>/lib, each only when
    # not broad, not a home or above one and not over a secret dir (a direct child of a home is
    # tolerated for these two only: ~/bin/node needs ~/bin and ~/lib to start).
    bindir = os.path.dirname(node)
    prefix = os.path.dirname(bindir)
    plib = os.path.join(prefix, "lib")
    node_dirs = set()
    if unsafe_kind(prefix, homes) is None:
        node_dirs |= {prefix, bindir}
    else:
        if unsafe_kind(bindir, homes) in (None, "child"):
            node_dirs.add(bindir)
        if os.path.isdir(plib) and unsafe_kind(plib, homes) in (None, "child"):
            node_dirs.add(plib)
    child_ok = {bindir, plib, repo}
    lib_dirs = {d for d in node_lib_dirs(node) if unsafe_kind(d, homes) is None}
    read_sub = ({repo, f"{out}/home", f"{out}/tmp", f"{out}/work", dsh, "/System/Library",
                 "/usr/lib", "/usr/share", "/private/var/db/dyld",
                 "/System/Volumes/Preboot/Cryptexes"} | node_dirs | lib_dirs) - BROAD
    read_lit = {"/", "/private/etc/ssl/cert.pem", "/private/etc/resolv.conf", "/private/etc/hosts",
                "/private/etc/localtime", "/dev/null", "/dev/urandom", "/dev/random", "/dev/tty",
                "/dev/dtracehelper"}
    write_sub = {f"{out}/home", f"{out}/tmp"}
    write_lit = {"/dev/null", "/dev/tty", "/dev/dtracehelper"}
    p = []
    deny_read_at = deny_write_at = None
    env_rx = []        # (rule index, compiled regex) of every (deny file-read* (regex ...))
    repo_allow_at = None
    rules = [r for r in tree if isinstance(r, list) and r and r[0] in ("allow", "deny")]
    if not rules:
        fail(["fence has no allow/deny rules"])
    for i, r in enumerate(rules):
        ops = [x for x in r[1:] if isinstance(x, str)]
        filters = flatten_filters([x for x in r[1:] if not isinstance(x, str)])
        reads = [o for o in ops if o in ("file-read*", "file-read-data")]
        writes = [o for o in ops if o.startswith("file-write")]
        if r[0] == "deny":
            if "file-read*" in ops and not filters and deny_read_at is None:
                deny_read_at = i
            if "file-write*" in ops and not filters and deny_write_at is None:
                deny_write_at = i
            if "file-read*" in ops:
                for f in filters:
                    if isinstance(f, list) and len(f) == 2 and f[0] == "regex" and isinstance(f[1], tuple):
                        try:
                            env_rx.append((i, re.compile(f[1][1])))
                        except re.error as e:
                            p.append(f"deny regex does not compile ({e}): {f[1][1]}")
            continue
        if reads:
            if not filters:
                p.append(f"unfiltered read allow: {r}")
            if deny_read_at is None:
                p.append(f"read allow before any (deny file-read*): {r}")
            for f in filters:
                ok = (isinstance(f, list) and len(f) == 2 and isinstance(f[1], tuple)
                      and f[1][0] == "str"
                      and ((f[0] == "subpath" and f[1][1] in read_sub)
                           or (f[0] == "literal" and f[1][1] in read_lit | overlay_lit)))
                if not ok:
                    p.append(f"read allow not on the allowlist: {f}")
                elif f[0] == "literal" and f[1][1] in overlay_lit:
                    overlay_seen.add(f[1][1])
                if (isinstance(f, list) and len(f) == 2 and f[0] == "subpath"
                        and isinstance(f[1], tuple)):
                    d = f[1][1]
                    k = unsafe_kind(d, homes)
                    if k == "child" and d not in child_ok:
                        p.append(f"read allow of {d}: a direct child of a home")
                    elif k not in (None, "child"):
                        p.append(f"read allow of {d}: {k}")
                    if d == repo and repo_allow_at is None:
                        repo_allow_at = i
        if writes:
            if not filters:
                p.append(f"unfiltered write allow: {r}")
            for f in filters:
                ok = (isinstance(f, list) and len(f) == 2 and isinstance(f[1], tuple)
                      and f[1][0] == "str"
                      and ((f[0] == "subpath" and f[1][1] in write_sub)
                           or (f[0] == "literal" and f[1][1] in write_lit)))
                if not ok:
                    p.append(f"write allow not on the allowlist: {f}")
    if deny_read_at is None:
        p.append("no unfiltered (deny file-read*)")
    if deny_write_at is None:
        p.append("no unfiltered (deny file-write*)")
    # The repo's .env files: every ENV_DENY name matched by a deny regex placed after the repo's
    # allow (the later rule wins), and no ENV_ALLOW name matched (no over-blocking).
    live = [rx for i, rx in env_rx if repo_allow_at is None or i > repo_allow_at]
    if not env_rx:
        p.append("no (deny file-read* (regex ...)) covering the repo's .env files")
    else:
        if len(live) < len(env_rx):
            p.append("a deny regex comes before the repo's read allow, which overrides it")
        miss = [n for n in ENV_DENY if not any(rx.match(f"{repo}/{n}") for rx in live)]
        if miss:
            p.append(f"the .env deny leaves readable: {miss}")
        over = [n for n in ENV_ALLOW if any(rx.match(f"{repo}/{n}") for _i, rx in env_rx)]
        if over:
            p.append(f"the .env deny over-blocks: {over}")
    for lit in sorted(overlay_lit - overlay_seen):
        p.append(f"no (allow file-read* (literal \"{lit}\")): dsh cannot read its --patch overlay")
    fail(p)


# --------------------------------------------------------------------------------------------
# real dsh

def cmd_dump_check(argv):
    with open(argv[0]) as f:
        dump = rows(f.read())
    with open(argv[1]) as f:
        review = rows(f.read())
    by_id = {}
    for r in dump:
        by_id.setdefault(r["id"], r)
    p = []
    if len(dump) < 20:
        p.append(f"dump has only {len(dump)} rows: not a --dump-config output")
    for r in review:
        if r.get("disabled") == "true":
            got = by_id.get(r["id"], {}).get("disabled")
            if got != "true":
                p.append(f"row {r['id']}: disabled={got!r} in the composed config")
    llm = by_id.get("llm-deepseek", {}).get("config", {})
    for k, v in {"maxTokens": 393216, "reasoningEffort": "max",
                 "baseURL": "https://api.deepseek.com/anthropic"}.items():
        if llm.get(k) != v:
            p.append(f"llm-deepseek {k}={llm.get(k)!r}, expected {v!r}")
    adm = by_id.get("agent-default-model", {}).get("config", {})
    if adm.get("model") != "deepseek-flash":
        p.append(f"agent-default-model model={adm.get('model')!r}")
    fail(p)


def cmd_requests_check(argv):
    reqs = []
    with open(argv[0]) as f:
        for line in f:
            o = json.loads(line)
            if o.get("method") == "POST":
                reqs.append(o)
    if not reqs:
        fail(["the mock received no POST"])
    p = []
    b = reqs[0].get("body", {})
    if b.get("model") != "deepseek-flash":
        p.append(f"model {b.get('model')!r}")
    if b.get("max_tokens") != 393216:
        p.append(f"max_tokens {b.get('max_tokens')!r}")
    if (b.get("output_config") or {}).get("effort") != "max":
        p.append(f"output_config {b.get('output_config')!r}")
    dsh_keys = [k for k in b if k.startswith("dsh_")]
    if dsh_keys:
        p.append(f"top-level dsh_ keys {dsh_keys}")
    tools = sorted(t.get("name") for t in b.get("tools", []))
    if tools != ["glob", "grep", "read", "todo_write"]:
        p.append(f"tools {tools}")
    if not any(r.get("sentinel_seen") for r in reqs):
        p.append("no request carried the repo sentinel in a tool_result")
    if not reqs[0].get("nonce"):
        p.append("the mock found no VERDICT nonce in the prompt")
    fail(p)


def cmd_fabricate(argv):
    out, runjsonl, err, rc, nonce, repo = argv
    os.umask(0o077)
    os.makedirs(out, mode=0o700)
    for d in ("home", "tmp", "work"):
        os.mkdir(os.path.join(out, d), 0o700)

    def put(name, data):
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)

    with open(runjsonl, "rb") as f:
        put("run-1.jsonl", f.read())
    with open(err, "rb") as f:
        put("err-1.txt", f.read())
    put("prompt-1.txt", b"fabricated\n")
    status = {"attempt": 1, "dsh_version": PINNED, "model": "deepseek-flash",
              "model_source": "default", "effort": "max", "max_tokens": 393216, "nonce": nonce,
              "repo": real(repo) if repo != "-" else None, "repo_mode": repo != "-",
              "expect_read": [], "session_id": None, "argv": [], "patch_sha256": {},
              "started_at": "2026-11-01T00:00:00Z", "ended_at": "2026-11-01T00:00:01Z",
              "wall_seconds": 1.0, "exit_code": int(rc), "signal": None, "cancelled": False,
              "cancel_reason": None, "verdict": "PASS" if rc == "0" else "FAIL", "reasons": [],
              "usage": {}}
    put("status-1.json", json.dumps(status, indent=1).encode())


def cmd_nonce(_argv):
    print(secrets.token_hex(8))


def ref_fence_lines(repo, out, dsh, node, n="1"):
    """A fence that satisfies the contract (META use only: proves the dynamic probe
    expectations are achievable and gives fence-check a known-good input to mutate)."""
    def q(p):
        return '"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"'
    nd = os.path.dirname(os.path.dirname(node))
    subs = ["/System/Library", "/usr/lib", "/usr/share", "/private/var/db/dyld",
            "/System/Volumes/Preboot/Cryptexes", os.path.dirname(node), nd,
            *sorted(node_lib_dirs(node)), dsh, repo, f"{out}/home", f"{out}/tmp", f"{out}/work"]
    lits = ["/", "/private/etc/ssl/cert.pem", "/private/etc/resolv.conf", "/private/etc/hosts",
            "/private/etc/localtime", "/dev/null", "/dev/urandom", "/dev/random", "/dev/tty",
            "/dev/dtracehelper"]
    lines = ["(version 1)", "(allow default)", "(deny file-read*)", "(allow file-read-metadata)"]
    lines += [f"(allow file-read* (subpath {q(p)}))" for p in subs]
    lines += [f"(allow file-read* (literal {q(p)}))" for p in lits]
    lines += [f"(allow file-read* (literal {q(p)}))"
              for p in (f"{out}/review.patch.yml", f"{out}/run-{n}.patch.yml")]
    esc = re.sub(r'([.^$*+?()\[\]{}|\\"])', r'\\\1', repo)
    lines.append('(deny file-read* (regex #"^' + esc + r'/(.*/)?(\.env[^/]*|[^/]*\.env)$"))')
    lines += ["(deny file-write*)", f"(allow file-write* (subpath {q(out + '/home')}))",
              f"(allow file-write* (subpath {q(out + '/tmp')}))",
              '(allow file-write* (literal "/dev/null"))', '(allow file-write* (literal "/dev/tty"))',
              '(allow file-write* (literal "/dev/dtracehelper"))']
    return lines


def cmd_ref_fence(argv):
    n = argv[4] if len(argv) > 4 else "1"
    print("\n".join(ref_fence_lines(*(real(a) for a in argv[:4]), n)))


def cmd_patch_reads(argv):
    rec, want = load_json(argv[0]), argv[1:]
    got = rec.get("patch_reads")
    if not isinstance(got, dict):
        fail([f"record has no patch_reads map (got {got!r})"])
    p = []
    if sorted(got) != sorted(want):
        p.append(f"stub read --patch files {sorted(got)}, expected {sorted(want)}")
    for f in want:
        if got.get(f) != "OK":
            p.append(f"stub read of --patch {f} -> {got.get(f, '<not read>')}, expected OK")
    fail(p)


BLOCK = ("\n---\nEnd your answer with exactly one final line, and nothing after it:\n"
         "VERDICT-{n}: FINDINGS\nor\nVERDICT-{n}: NO FINDINGS")


def cmd_attempt_check(argv):
    """attempt-check RECORD PROMPT OUT N [sigterm]: what the stub got on stdin, and the attempt
    files the wrapper kept, match each other byte for byte."""
    rec, out, n = load_json(argv[0]), argv[2], argv[3]
    with open(argv[1], "rb") as f:
        prompt = f.read().decode()
    p = []
    nonce = rec.get("nonce", "")
    if not re.fullmatch(r"[0-9a-f]{16}", nonce):
        p.append(f"nonce {nonce!r} is not 16 lowercase hex chars")
    stdin = rec.get("stdin", "")
    want = prompt + BLOCK.format(n=nonce)
    if stdin.rstrip("\n") != want:
        p.append(f"stdin sent to dsh\n      got:  {stdin!r}\n      want: {want!r} (+ trailing newlines)")

    def read(name):
        try:
            with open(os.path.join(out, name), "rb") as f:
                return f.read()
        except OSError:
            p.append(f"{name} missing")
            return None

    pr = read(f"prompt-{n}.txt")
    if pr is not None and pr != stdin.encode():
        p.append(f"prompt-{n}.txt differs from the stdin dsh received")
    emitted = (rec.get("emitted") or "") + ((rec.get("emitted_sigterm") or "")
                                            if len(argv) > 4 and argv[4] == "sigterm" else "")
    rj = read(f"run-{n}.jsonl")
    if rj is not None and rj != emitted.encode():
        p.append(f"run-{n}.jsonl differs from what dsh printed on stdout")
    er = read(f"err-{n}.txt")
    if er is not None and er != (rec.get("emitted_stderr") or "").encode():
        p.append(f"err-{n}.txt {er[:120]!r} differs from what dsh printed on stderr")
    try:
        st = load_json(os.path.join(out, f"status-{n}.json"))
        if st.get("nonce") != nonce:
            p.append(f"status-{n}.json nonce {st.get('nonce')!r} != the nonce sent ({nonce!r})")
    except (OSError, ValueError):
        p.append(f"status-{n}.json unreadable")
    fail(p)


def cmd_status_set(argv):
    path = argv[0]
    st = load_json(path)
    for a in argv[1:]:
        k, _, v = a.partition("=")
        st[k] = json.loads(v)
    with open(path, "w") as f:
        json.dump(st, f, indent=1)


def cmd_key_absent(argv):
    """key-absent KEY DIR: no regular file under DIR (recursively, never through a symlink) holds
    KEY as written or JSON-escaped. Lists every hit relative to DIR; DIR holding no regular file
    is a failure too (nothing was checked)."""
    key, top = argv[0], argv[1]
    forms = {key.encode(), json.dumps(key)[1:-1].encode()}
    hits, n, problems = [], 0, []
    for root, dirs, files in os.walk(top, followlinks=False):
        for f in files:
            p = os.path.join(root, f)
            st = os.lstat(p)
            if not stat.S_ISREG(st.st_mode):
                continue
            n += 1
            try:
                with open(p, "rb") as fh:
                    data = fh.read()
            except OSError as e:
                problems.append(f"cannot read {os.path.relpath(p, top)} ({e.strerror}): its bytes were never checked")
                continue
            if any(x in data for x in forms):
                hits.append(os.path.relpath(p, top))
    if n == 0:
        problems.append(f"no regular file under {top}")
    if hits:
        problems.append(f"the key is still in {len(hits)} of {n} files under <out>: {', '.join(sorted(hits))}")
    fail(problems)


CMDS = {"scenario": cmd_scenario, "codes": cmd_codes, "find-records": cmd_find_records,
        "key-absent": cmd_key_absent,
        "rec": cmd_rec, "final-text": cmd_final_text, "env-check": cmd_env_check,
        "argv-exact": cmd_argv_exact, "argv-vs-pinv": cmd_argv_vs_pinv,
        "pinv-check": cmd_pinv_check, "patch-sha": cmd_patch_sha,
        "status-check": cmd_status_check, "status-reasons": cmd_status_reasons,
        "modes": cmd_modes, "tree-hash": cmd_tree_hash, "fence-check": cmd_fence_check,
        "grep-absent": cmd_grep_absent, "dump-check": cmd_dump_check,
        "requests-check": cmd_requests_check, "fabricate": cmd_fabricate,
        "usage-sum": cmd_usage_sum, "nul-argv": cmd_nul_argv, "nonce": cmd_nonce,
        "ref-fence": cmd_ref_fence, "patch-reads": cmd_patch_reads, "attempt-check": cmd_attempt_check,
        "status-set": cmd_status_set, "fab-stream": cmd_fab_stream}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        print(__doc__)
        sys.exit(2)
    try:
        CMDS[sys.argv[1]](sys.argv[2:])
    except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError) as e:
        # An input the wrapper never wrote (no file, not JSON, wrong shape) is a check failure
        # with a one-line reason, not a harness crash.
        print(f"{sys.argv[1]}: unusable input ({type(e).__name__}: {str(e)[:160]})")
        sys.exit(1)
