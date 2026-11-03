#!/usr/bin/env python3
"""Mutation harness for bin/deepseek-review: every guard must be pinned by its own case of
test-deepseek-review.sh. Run through ../mutate-deepseek-review.sh.

For each mutant: copy plugins/deepseek (bin, dsh, scripts) to a fresh temp dir, apply the
mutant's exact-substring replacements to the COPY's bin/deepseek-review (each target must occur
exactly once, else the mutant FAILS), py_compile the copy with /usr/bin/python3 (a mutant that
does not compile FAILS), and run the COPY's harness with DSR_ONLY selecting the blocks that hold
the mutant's expected cases. Verdicts:

  CAUGHT          a FAIL verdict line names one of the mutant's expected cases (and, when the
                  mutant gives one, that case's failure text holds its `detail`)
  ELSEWHERE       red, but only on other cases (counts as a failure of the harness)
  SURVIVED        the selected run was green (failure)
  EQUIVALENT-OK   a mutant declared equivalent (with the reason) stayed green, as argued
  BROKEN          target missing / ambiguous, compile error, truncated or inconsistent output

The tree's wrapper is never written; its sha256 is checked at the start and at the end. Before
any mutant runs, the clean copy runs once per distinct selection (the baseline): it must be
fully green and print `ok    <case>` for every expected case, so a selection that hides a case
(or a case that is red anyway) is caught before it can make a mutant look killed.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

BS = chr(92)  # a backslash, built in code so no tool decodes it on the way to disk
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
PLUGIN = os.path.dirname(SCRIPTS)
WRAPPER = os.path.join(PLUGIN, "bin", "deepseek-review")
LOG_CAP = 20_000_000
RUN_TIMEOUT = 1200

MUTANTS = []


def mut(mid, guard, repl, expect, *, detail=None, serial=False, real=False, equivalent=None):
    """repl: [(old, new), ...]; expect: verdict-line names (text after `FAIL  `)."""
    if isinstance(repl, tuple):
        repl = [repl]
    MUTANTS.append({"id": mid, "guard": guard, "repl": repl, "expect": list(expect),
                    "detail": detail, "serial": serial, "real": real, "equivalent": equivalent})


# ---------------------------------------------------------------------------------------------
# validation (one per FAIL code)

V_EXIT1 = "validate: dsh exit 1 with an otherwise valid completed stream"
V_KILLED = "validate: dsh killed by SIGKILL after a valid completed stream"
mut("V01", "DSH_EXIT_NONZERO: the exit-code branch",
    ('    elif not (is_int(status.get("exit_code")) and status.get("exit_code") == 0):\n', '    elif False:\n'),
    [V_EXIT1])
mut("V02", "DSH_EXIT_NONZERO: the signal branch",
    ('    if status.get("signal") is not None:\n        fails.append(("DSH_EXIT_NONZERO"',
     '    if False:\n        fails.append(("DSH_EXIT_NONZERO"'), [V_KILLED],
    detail="killed by signal 9")
mut("V03", "status: signal recorded from a negative returncode",
    ('    status["signal"] = -rc if rc is not None and rc < 0 else None', '    status["signal"] = None'),
    [V_KILLED])
mut("V04", "status: exit_code null when killed by a signal",
    ('    status["exit_code"] = rc if rc is not None and rc >= 0 else None', '    status["exit_code"] = rc'),
    [V_KILLED])
LT_TRAP_TMO = "lifetime: trapped SIGTERM + perfect stream after --timeout 3s is still CANCELLED"
mut("V05", "CANCELLED in validate", ('    if status.get("cancelled"):', '    if False:'),
    [LT_TRAP_TMO], serial=True)
mut("V06", "CANCELLED in --check (read from status-N.json, not only from its reasons)",
    ('        status, prior_reads(out, n))', '        dict(status, cancelled=False), prior_reads(out, n))'),
    ["H10: --check on a status recording cancelled (verdict PASS, reasons empty) is FAIL CANCELLED"])
mut("V07", "COMPOSE_WARNING: 'did not activate' regex",
    ('entr(?:y|ies) did not activate"),', 'entr(?:y|ies) did not activate-NEVER"),'),
    ["validate: composition warning: did not activate"])
mut("V08", "COMPOSE_WARNING: 'patch: entry not found' regex",
    ('" not found"))', '" not found-NEVER"))'),
    ["validate: composition warning: patch entry not found"])
mut("V09", "STREAM_EMPTY: zero-byte stdout",
    ('    if not stream:\n        fails.append(("STREAM_EMPTY"', '    if False:\n        fails.append(("STREAM_EMPTY"'),
    ["validate: zero-byte stdout"], detail="dsh wrote nothing on stdout")
mut("V10", "STREAM_EMPTY: no events (blank lines only)",
    ('    if not events:\n        fails.append(("STREAM_EMPTY"', '    if False:\n        fails.append(("STREAM_EMPTY"'),
    ["validate: stdout holding only blank lines is STREAM_EMPTY"])
mut("V11", "STREAM_NOT_JSON: a non-JSON line",
    ('        except ValueError:\n            ev = None\n', '        except ValueError:\n            continue\n'),
    ["validate: a non-JSON line"])
mut("V12", "STREAM_NOT_JSON: a JSON value that is not an object",
    ('        if not isinstance(ev, dict):\n            fails.append(("STREAM_NOT_JSON"',
     '        if ev is None:\n            fails.append(("STREAM_NOT_JSON"'),
    ["validate: a JSON line that is not an object"])
mut("V13", "SESSION_NOT_FIRST", ('    if events[0].get("type") != "session":', '    if False:'),
    ["validate: session event not first", "validate: no session event"])
mut("V14", "FINAL_NOT_LAST", ('    if events[-1].get("type") != "final":', '    if False:'),
    ["validate: an event after final", "validate: no final event"])
mut("V15", "ERROR_EVENT", ('    if any(e.get("type") == "error" for e in events):', '    if False:'),
    ["validate: an error event"])
mut("V16", "NO_TURN_END",
    ('    if not turn_ends:\n        fails.append(("NO_TURN_END", "no turn_end event: the turn outcome is unknown"))\n    else:\n',
     '    if False:\n        pass\n    elif turn_ends:\n'),
    ["validate: no turn_end at all (fail closed)"])
mut("V17", "TURN_NOT_COMPLETED: judged on the LAST turn_end",
    ('        reason = turn_ends[-1].get("reason")', '        reason = turn_ends[0].get("reason")'),
    ["validate: an earlier completed turn does not hide a failed LAST turn"])
mut("V18", "TURN_NOT_COMPLETED: kind must be completed", ('        if kind != "completed":', '        if False:'),
    ["validate: turn_end max-tokens with a valid VERDICT"])
mut("V19", "FINAL_EMPTY",
    ('        if not final_text.strip():\n            fails.append(("FINAL_EMPTY"', '        if False:\n            fails.append(("FINAL_EMPTY"'),
    ["validate: blank final text"])
mut("V20", "VERDICT_MISSING: this attempt's nonce in the regex",
    ('r"^VERDICT-" + (nonce or "-") + r": ', 'r"^VERDICT-" + "[0-9a-f]{16}" + r": '),
    ["validate: VERDICT with another attempt's nonce"])
mut("V21", "VERDICT_MISSING: the LAST line must be the VERDICT",
    ('            if not want.match(lines[-1]):', '            if not any(want.match(ln) for ln in lines):'),
    ["validate: text after the VERDICT line"])
mut("V22", "VERDICT_MISSING: the regex is anchored at the end",
    ('(FINDINGS|NO FINDINGS)$")', '(FINDINGS|NO FINDINGS)")'),
    ["validate: text after the verdict word on the VERDICT line"])
mut("V23", "VERDICT_DUPLICATE",
    ('            elif any(VERDICT_LIKE.search(ln) for ln in lines[:-1]):', '            elif False:'),
    ["validate: a second VERDICT line (other nonce)", "validate: a second VERDICT line (same nonce)"])
mut("V24", "REPO_NOT_READ: the read must be inside the repo",
    ('        if not any(inside(p, repo) and p != repo for p in seen):', '        if not seen:'),
    ["validate --repo: the only successful read is outside the repo"])
mut("V25", "inside(): a path boundary, not a string prefix",
    ('    return child == parent or child.startswith(parent.rstrip("/") + "/")',
     '    return child == parent or child.startswith(parent.rstrip("/"))'),
    ["validate --repo: a sibling dir sharing the repo's name prefix"])
mut("V26", "REPO_NOT_READ: tool_result paired with its tool_call by callId",
    ('        call = calls.get(e.get("callId"))', '        call = calls.get(e.get("callId")) or next(iter(calls.values()), None)'),
    ["validate --repo: a completed tool_result whose callId matches no read call"])
mut("V27", "REPO_NOT_READ: only the read tool counts",
    ('        if status_s != "completed" or not call or call.get("tool") != "read":',
     '        if status_s != "completed" or not call:'),
    ["validate --repo: a completed non-read tool whose input has a file_path is not a read"])
mut("V28", "REPO_NOT_READ: only completed results count",
    ('        if status_s != "completed" or not call or call.get("tool") != "read":',
     '        if not call or call.get("tool") != "read":'),
    ["R3: --check on a stream with error_envelope is FAIL REPO_NOT_READ"])
mut("V29", "REPO_NOT_READ: the realpath of the read path",
    ('        read_ok.append(canon(os.path.realpath(fp)))', '        read_ok.append(os.path.abspath(fp))'),
    ["validate --repo: a read through a repo symlink that resolves outside"])
mut("V30", "REPO_NOT_READ: a relative path is joined with the session cwd",
    ('            fp = os.path.join(session_cwd, fp)', '            pass'),
    ["validate --repo: a relative read resolves against the session cwd"])
mut("V31", "REPO_NOT_READ: the session cwd comes from the session event",
    ('    session_cwd = first.get("cwd") if first.get("type") == "session" else None',
     '    session_cwd = os.getcwd()'),
    ["validate --repo: a relative read resolves against the session cwd"])
mut("V32", "REPO_NOT_READ: the repo-mode gate", ('    if not problem and status["repo_mode"]:', '    if False:'),
    ["validate --repo: every read denied, final says it could not access the files"])
mut("V33", "EXPECTED_READ_MISSING", ('            if want_p not in seen:', '            if False:'),
    ["validate --repo: an --expect-read file never read while other reads succeeded"])

# ---------------------------------------------------------------------------------------------
# setup, scope and usage

mut("S01", "PROMPT_MISSING", ('    if not path or not os.path.isfile(path):', '    if not path:'),
    ["setup: PROMPT_MISSING", "setup: PROMPT_MISSING (the PROMPT_FILE is a directory)",
     "setup: PROMPT_MISSING (the PROMPT_FILE is a FIFO): refused at once, never opened"])
mut("S02", "PROMPT_EMPTY (whitespace only)", ('    if not text.strip():', '    if not text:'),
    ["setup: PROMPT_EMPTY (whitespace only)"])
mut("S03", "MODEL_INVALID", ('    if not MODEL_RE.match(model):', '    if False:'),
    ["setup: MODEL_INVALID (--model 'DeepSeek-V4', 11 chars)", "setup: MODEL_INVALID (--model 'deepseek/v4', 11 chars)",
     "setup: MODEL_INVALID (--model 'deepseek_v4', 11 chars)", "setup: MODEL_INVALID (--model 'aaaaaaaaaaaa', 65 chars)"])
mut("S04", "EFFORT_INVALID", ('    if effort not in EFFORTS:', '    if False:'),
    ["setup: EFFORT_INVALID (--effort 'xhigh')", "setup: EFFORT_INVALID (--effort 'HIGH')",
     "setup: EFFORT_INVALID (--effort '')", "setup: EFFORT_INVALID (--effort 'medium')"])
mut("S05", "MAX_TOKENS_INVALID: lower bound 1", ('(1 <= int(v) <= MAX_TOKENS_CAP)', '(0 <= int(v) <= MAX_TOKENS_CAP)'),
    ["setup: MAX_TOKENS_INVALID (--max-tokens 0)"])
mut("S06", "MAX_TOKENS_INVALID: upper bound", ('(1 <= int(v) <= MAX_TOKENS_CAP)', '(1 <= int(v))'),
    ["setup: MAX_TOKENS_INVALID (--max-tokens 393217)"])
mut("S07", "KEY_MISSING: empty value", ('    if not key:\n        raise SetupError("KEY_MISSING",', '    if key is None:\n        raise SetupError("KEY_MISSING",'),
    ["setup: KEY_MISSING (empty)"])
mut("S08", "KEY_MISSING: unset", ('    if not key:\n        raise SetupError("KEY_MISSING",', '    if False:\n        raise SetupError("KEY_MISSING",'),
    ["setup: KEY_MISSING (unset)"])
mut("S09", "KEY_INVALID", ('    if problem:\n        raise SetupError("KEY_INVALID",', '    if False:\n        raise SetupError("KEY_INVALID",'),
    ["setup: KEY_INVALID (newline)", "setup: KEY_INVALID (space)", "setup: KEY_INVALID (DEL and tab)"])
mut("S10", "KEY_INVALID: a space is outside KEY_CHARS", ('0123456789._-")', '0123456789._- ")'),
    ["setup: KEY_INVALID (space)"])
mut("S11", "KEY_INVALID: the printed positions", ('str(i) for i in bad', 'str(i + 1) for i in bad'),
    ["setup: KEY_INVALID (newline)", "setup: KEY_INVALID (space)", "setup: KEY_INVALID (DEL and tab)"],
    detail="bad positions [")
mut("S12", "REPO_NOT_DIR", ('    if not os.path.isdir(repo):\n        raise SetupError("REPO_NOT_DIR", f"--repo',
                            '    if False:\n        raise SetupError("REPO_NOT_DIR", f"--repo'),
    ["setup: REPO_NOT_DIR (a file)", "setup: REPO_NOT_DIR (missing)"])
mut("S13", "REPO_IS_ROOT", ('    if repo == "/":', '    if False:'), ["setup: REPO_IS_ROOT"])
mut("S14", "REPO_HOME_OR_ABOVE: above HOME", ('    if inside_ci(home, repo):', '    if fold(home) == fold(repo):'),
    ["setup: REPO_HOME_OR_ABOVE (HOME's parent, given via the non-realpath /var form)"])
mut("S15", "REPO_HOME_OR_ABOVE: HOME itself", ('    if inside_ci(home, repo):', '    if False:'),
    ["setup: REPO_HOME_OR_ABOVE (HOME)"])
mut("S16", "--repo is realpath'd before the scope checks", ('    repo = real(arg)', '    repo = os.path.abspath(arg)'),
    ["setup: REPO_HOME_OR_ABOVE (HOME's parent, given via the non-realpath /var form)",
     "setup: REPO_SECRET_OVERLAP (symlink path whose realpath is inside ~/.ssh)"])
mut("S17", "REPO_SECRET_OVERLAP: the realpath'd secret dir",
    ('        for sd in {os.path.join(home, d), real(os.path.join(home, d))}:', '        for sd in {os.path.join(home, d)}:'),
    ["setup: REPO_SECRET_OVERLAP (repo contains the realpath of ~/.aws)"])
mut("S18", "REPO_SECRET_OVERLAP: the literal secret dir (beside its realpath)",
    ('        for sd in {os.path.join(home, d), real(os.path.join(home, d))}:', '        for sd in {real(os.path.join(home, d))}:'),
    [], equivalent=("home is already a realpath, so HOME/<d> differs from its realpath only when <d> is a "
                    "symlink, and then no realpath'd repo can lie under (or above, short of HOME) the "
                    "literal path: the literal entry adds no reachable verdict"))
mut("S19", "REPO_SECRET_OVERLAP: overlap in both directions", ('            if overlaps_ci(repo, sd):', '            if inside_ci(repo, sd):'),
    ["setup: REPO_SECRET_OVERLAP (repo contains the realpath of ~/.aws)"])
for i, (d, old, new) in enumerate([
        (".ssh", 'SECRET_DIRS = (".ssh", ', 'SECRET_DIRS = ('),
        (".gnupg", '".gnupg", ".aws"', '".aws"'),
        (".aws", '".aws", ".config"', '".config"'),
        (".config", '".config", ".dsh"', '".dsh"'),
        (".dsh", '".dsh", ".claude"', '".claude"'),
        (".claude", '".claude", ".codex"', '".codex"'),
        (".codex", '".codex", ".gemini"', '".gemini"'),
        (".gemini", '".gemini",\n', '\n'),
        (".kimi-code", '".kimi-code", "Library")', '"Library")'),
        ("Library", '".kimi-code", "Library")', '".kimi-code")')], 1):
    mut(f"S20{chr(96 + i)}", f"REPO_SECRET_OVERLAP: {d} in SECRET_DIRS", (old, new),
        [f"setup: REPO_SECRET_OVERLAP (inside ~/{d})"])
mut("S21", "REPO_NOT_GIT", ('    if top.returncode != 0 or not top.stdout.strip():', '    if False:'),
    ["setup: REPO_NOT_GIT"])
GIT_ENV = '    return {"PATH": CHILD_PATH, "HOME": account_home()}'
H2_GIT_DEV = "H2: the repo check's git ignores the caller's DEVELOPER_DIR (minimal env, no key)"
mut("S22", "git env: none of the caller's env (GIT_*, DEVELOPER_DIR, the key)",
    (GIT_ENV, '    return dict(os.environ)'),
    ["setup: REPO_NOT_GIT (caller's GIT_DIR points at a real repo)",
     "scope: the caller's GIT_DIR/GIT_WORK_TREE do not redirect the repo check", H2_GIT_DEV])
mut("S22b", "git env: the caller's GIT_* never reach git",
    (GIT_ENV, '    return {"PATH": CHILD_PATH, "HOME": account_home(), '
              '**{k: v for k, v in os.environ.items() if k.startswith("GIT_")}}'),
    ["setup: REPO_NOT_GIT (caller's GIT_DIR points at a real repo)",
     "scope: the caller's GIT_DIR/GIT_WORK_TREE do not redirect the repo check"])
mut("S22c", "git env: the caller's DEVELOPER_DIR (and the key) never reach git",
    (GIT_ENV, '    return {"PATH": CHILD_PATH, "HOME": account_home(), '
              '**{k: v for k, v in os.environ.items() if k in ("DEVELOPER_DIR", "DEEPSEEK_API_KEY")}}'),
    ["H2: git_env() keeps the caller's DEVELOPER_DIR and key from git (wrapper run past its shebang)"],
    detail="git_env() passed the caller's DEVELOPER_DIR")
mut("S23", "REPO_DOTFILES", ('    if fold(real(top.stdout.strip())) in {fold(h) for h in hs}:', '    if False:'),
    ["setup: REPO_DOTFILES (work-tree root == HOME)"])
mut("S24", "REPO_BAD_CHARS: control characters",
    ('''    if has_ctrl(arg) or has_ctrl(repo) or '"' in repo:''', '''    if '"' in repo:'''),
    ["setup: REPO_BAD_CHARS (newline)", "setup: REPO_BAD_CHARS (tab)", "setup: REPO_BAD_CHARS (DEL)"])
mut("S25", "REPO_BAD_CHARS: a double quote",
    ('''    if has_ctrl(arg) or has_ctrl(repo) or '"' in repo:''', '''    if has_ctrl(arg) or has_ctrl(repo):'''),
    ["setup: REPO_BAD_CHARS (double quote)"])
mut("S26", "REPO_BAD_CHARS: DEL is a control character",
    ('    return any(ord(c) < 32 or ord(c) == 127 for c in s)', '    return any(ord(c) < 32 for c in s)'),
    ["setup: REPO_BAD_CHARS (DEL)"])
mut("S27", "EXPECT_READ_NEEDS_REPO", ('    if repo is None:\n        raise SetupError("EXPECT_READ_NEEDS_REPO"',
                                      '    if False:\n        raise SetupError("EXPECT_READ_NEEDS_REPO"'),
    ["setup: EXPECT_READ_NEEDS_REPO"])
mut("S28", "EXPECT_READ_OUTSIDE_REPO", ('        if not os.path.isfile(rp) or not inside(rp, repo) or rp == repo:',
                                        '        if not os.path.isfile(rp):'),
    ["setup: EXPECT_READ_OUTSIDE_REPO"])
mut("S29", "EXPECT_READ_OUTSIDE_REPO: realpath of the path", ('        rp = real(p)', '        rp = os.path.abspath(p)'),
    ["setup: EXPECT_READ_OUTSIDE_REPO (repo symlink resolving outside)"])
mut("S30", "OUT_EXISTS (--out)", ('    if os.path.lexists(a):', '    if False:'), ["setup: OUT_EXISTS"])
mut("S31", "OUT_EXISTS (an attempt's files already there)",
    ('        if os.path.lexists(os.path.join(out, name)):', '        if False:'),
    ["attempts: --continue after a failed attempt 2 (stray fence-2.sb, run-2.patch.yml) runs as attempt 3"],
    equivalent=("unreachable short of a race: mode_run's n=1 runs in a fresh out dir holding only home/, "
                "tmp/, work/ and review.patch.yml, and mode_continue's n is one past the highest number "
                "attempts_in() finds, whose ATTEMPT_FILE regex matches exactly the six names this loop "
                "tests; so no <name>-n file exists when the check runs"))
mut("S32", "OUT_OVERLAP: the repo", ('    if repo and overlaps_ci(out, repo):', '    if False:'),
    ["setup: OUT_OVERLAP (inside the repo)", "setup: OUT_OVERLAP (inside the repo through a symlinked parent)"])
mut("S33", "OUT_OVERLAP: HOME", ('    if any(inside_ci(h, out) for h in homes()):', '    if False:'),
    ["setup: OUT_OVERLAP (HOME inside the out dir)"])
mut("S34", "OUT_OVERLAP: the dsh dir", ('    if overlaps_ci(out, real(dsh_dir)):', '    if False:'),
    ["setup: OUT_OVERLAP (inside the dsh dir)"])
mut("S35", "OUT_OVERLAP: --out's parent is realpath'd",
    ('    out = os.path.join(real(parent), name)', '    out = a'),
    ["setup: OUT_OVERLAP (inside the repo through a symlinked parent)"])
mut("S36", "OUT_PERMS: mode 0700", (' or stat.S_IMODE(st.st_mode) != 0o700:', ':'),
    ["setup: OUT_PERMS (--continue on a 0755 out dir)", "setup: OUT_PERMS (--check on a 0755 out dir)"])
mut("S37", "OUT_PERMS for --continue", ('    out = check_out_dir_perms(a.cont)', '    out = real(a.cont)'),
    ["setup: OUT_PERMS (--continue on a 0755 out dir)"])
mut("S38", "OUT_PERMS for --check", ('    out = check_out_dir_perms(a.check)', '    out = real(a.check)'),
    ["setup: OUT_PERMS (--check on a 0755 out dir)"])
mut("S39", "PATH: relative entries skipped", ('        if not d or not os.path.isabs(d):', '        if not d:'),
    ["PATH: empty and '.' entries are skipped; a cwd node is never run",
     "setup: NODE_NOT_FOUND (only relative PATH entries hold node)"])
mut("S40", "PATH: empty entries skipped", ('        if not d or not os.path.isabs(d):', '        if d and not os.path.isabs(d):'),
    ["PATH: empty and '.' entries are skipped; a cwd node is never run"])
mut("S41", "NODE_NOT_FOUND: --node not an executable file",
    ('        if not (os.path.isfile(cand) and os.access(cand, os.X_OK)):', '        if False:'),
    ["setup: NODE_NOT_FOUND (--node missing)"])
mut("S42", "NODE_NOT_FOUND: no node on PATH", ('        if not cand:\n            raise SetupError("NODE_NOT_FOUND"',
                                               '        if False:\n            raise SetupError("NODE_NOT_FOUND"'),
    ["setup: NODE_NOT_FOUND (only relative PATH entries hold node)"])
mut("S43", "NODE_IN_SCOPE", ('        if s and inside_ci(node, s):', '        if False:'),
    ["setup: NODE_IN_SCOPE (--node inside the repo)", "setup: NODE_IN_SCOPE (PATH resolves to a node inside the repo)",
     "setup: NODE_IN_SCOPE (--continue with a node inside the out dir)"])
mut("S44", "DSH_MISSING: bin.js must exist", ('    if not os.path.isdir(d) or not os.path.isfile(binjs):', '    if not os.path.isdir(d):'),
    ["setup: DSH_MISSING"])
# check_dsh's mode check (4 spaces after a newline; mode_install's is indented 8, see W-D04/05)
DSH_PERM = '\n    if st.st_uid != os.getuid() or st.st_mode & 0o022:'
mut("S45", "DSH_DIR_UNSAFE: group-writable", (DSH_PERM, DSH_PERM.replace("0o022", "0o002")),
    ["setup: DSH_DIR_UNSAFE (group-writable 0770)"])
mut("S46", "DSH_DIR_UNSAFE: world-writable", (DSH_PERM, DSH_PERM.replace("0o022", "0o020")),
    ["setup: DSH_DIR_UNSAFE (world-writable only 0702)"])
mut("S47", "DSH_DIR_UNSAFE: overlap with the repo", ('    if repo and overlaps_ci(d, repo):', '    if False:'),
    ["setup: DSH_DIR_UNSAFE (inside the repo)"])
mut("S48", "DSH_VERSION_MISMATCH: the pin", ('    if ver != PINNED_VERSION:', '    if not ver:'),
    ["setup: DSH_VERSION_MISMATCH"])
mut("S49", "CONTINUE_REPO_MISMATCH", ('        if given != rec_repo:', '        if False:'),
    ["setup: CONTINUE_REPO_MISMATCH (--continue with a different --repo)"])
mut("S50", "CONTINUE_NO_SESSION", ('    if not sid:\n        raise SetupError("CONTINUE_NO_SESSION"',
                                   '    if False:\n        raise SetupError("CONTINUE_NO_SESSION"'),
    ["setup: CONTINUE_NO_SESSION (run-1.jsonl holds no session event)"])
mut("S51", "REPO_NOT_DIR: the recorded repo is gone (--continue)",
    ('        if not os.path.isdir(rec_repo):', '        if False:'),
    ["setup: REPO_NOT_DIR (--continue when the recorded repo is gone)"], detail="the recorded repo is gone")
mut("U01", "usage: allow_abbrev=False", ('allow_abbrev=False', 'allow_abbrev=True'),
    ["usage: '--mod deepseek-v4-flash' is a usage error"])
mut("U02", "usage: unknown flags are an error",
    ('    def error(self, message):\n        raise UsageError(message)', '    def error(self, message):\n        return None'),
    ["usage: '--frobnicate' is a usage error", "usage: '--patch x' is a usage error"])
mut("U03", "usage: --timeout must be positive", ('    if not m or int(m.group(1)) <= 0:', '    if not m:'),
    ["usage: --timeout 0 is a usage error"])
mut("U04", "usage: --check takes no PROMPT_FILE",
    ('            if a.prompt is not None:\n                raise UsageError("--check takes no PROMPT_FILE")',
     '            if False:\n                raise UsageError("--check takes no PROMPT_FILE")'),
    ["usage: --check with a PROMPT_FILE is a usage error"])
mut("U05", "usage: --attempt goes with --check",
    ('        if a.attempt is not None:\n            raise UsageError', '        if False:\n            raise UsageError'),
    ["usage: --attempt without --check is a usage error"])

# ---------------------------------------------------------------------------------------------
# env allowlist

ENV_SCRUB = "env: only the allowlist reaches dsh; inherited TMPDIR=<repo> ignored; GIT_DIR ignored"
mut("E01", "env: no caller variable passes through", ('    env = {"PATH": CHILD_PATH,', '    env = {**os.environ, "PATH": CHILD_PATH,'),
    [ENV_SCRUB])
mut("E02", "env: LANG only when the caller set it",
    ('        env["DEEPSEEK_API_KEY"] = key\n    if os.environ.get("LANG"):\n        env["LANG"] = os.environ["LANG"]',
     '        env["DEEPSEEK_API_KEY"] = key\n    if True:\n        env["LANG"] = os.environ.get("LANG", "C")'),
    ["env: LANG is passed only when the caller set it"])
mut("E03", "env: TMPDIR is <out>/tmp", ('"TMPDIR": os.path.join(out, "tmp"), "DSH_TELEMETRY_DISABLED"', '"TMPDIR": out, "DSH_TELEMETRY_DISABLED"'),
    [ENV_SCRUB])
mut("E04", "env: DSH_TELEMETRY_DISABLED=1", ('"DSH_TELEMETRY_DISABLED": "1",', ''), [ENV_SCRUB])
mut("E05", "env: DSH_PERMISSION_MODE=read-only", ('           "DSH_PERMISSION_MODE": "read-only"}', '           }'), [ENV_SCRUB])
mut("E06", "env: the key reaches the child", ('        env["DEEPSEEK_API_KEY"] = key', '        pass'), [ENV_SCRUB])
mut("E07", "--print-invocation env_names: the allowlist",
    ('"DSH_TELEMETRY_DISABLED", "DSH_PERMISSION_MODE",\n             "DEEPSEEK_API_KEY"]', '"DSH_TELEMETRY_DISABLED",\n             "DEEPSEEK_API_KEY"]'),
    ["print-invocation: defaults, no key needed, creates nothing"])
mut("E08", "--print-invocation env_names: LANG only when set",
    ('    if os.environ.get("LANG"):\n        names.append("LANG")', '    if True:\n        names.append("LANG")'),
    ["print-invocation: env_names lacks LANG when the caller set none"])

# ---------------------------------------------------------------------------------------------
# permissions

PERMS = "permissions: every dir 0700 / file 0600 under out with caller umask 022"
UMASK = ('    os.umask(0o077)', '    os.umask(0o022)')
mut("P01", "os.umask(0o077)", UMASK, [PERMS], detail="file home/stub-")
mut("P02", "write_private creates 0600 (with the umask broken too)",
    [UMASK, ('    fd = os.open(path, flags, 0o600)', '    fd = os.open(path, flags, 0o644)')], [PERMS],
    detail="file fence-1.sb mode 644")
mut("P03", "run-N.jsonl created 0600 (with the umask broken too)",
    [UMASK, ('f"run-{n}.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)', 'f"run-{n}.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)')],
    [PERMS], detail="file run-1.jsonl mode 644")
mut("P04", "home/tmp/work created 0700 (with the umask broken too)",
    [UMASK, ('        os.mkdir(os.path.join(out, sub), 0o700)', '        os.mkdir(os.path.join(out, sub), 0o755)')], [PERMS],
    detail="dir work mode 755")
mut("P05", "os.chmod(out, 0o700) (with mkdir 0755 and the umask broken too)",
    [UMASK, ('            os.mkdir(out, 0o700)\n        os.chmod(out, 0o700)\n', '            os.mkdir(out, 0o755)\n')], [PERMS],
    detail="dir . mode 755")

# ---------------------------------------------------------------------------------------------
# process lifetime (serial: wall-clock bounds)

LT_TMO = "lifetime: --timeout 3s kills the whole group (grandchild)"
LT_ORPHAN = "lifetime: a grandchild left by a dsh that exited 0 is killed with the group"
mut("L01", "start_new_session=True for dsh", ('stderr=err_fd, start_new_session=True)', 'stderr=err_fd, start_new_session=False)'),
    [LT_ORPHAN, LT_TMO], serial=True)
mut("L02", "SIGTERM goes to the group (os.killpg), not proc.terminate()",
    ('        os.killpg(proc.pid, signal.SIGTERM)', '        proc.terminate()'),
    ["lifetime: SIGTERM ignored: SIGKILL after the 6 s grace"], serial=True, detail="the grandchild never got SIGTERM")
mut("L03", "post-exit group SIGKILL",
    ('            os.killpg(proc.pid, signal.SIGKILL)\n        except (ProcessLookupError, PermissionError):\n            pass\n    finally:',
     '            pass\n        except (ProcessLookupError, PermissionError):\n            pass\n    finally:'),
    [LT_ORPHAN], serial=True)
SIGS = 'SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)'
mut("L04", "SIGINT handler", (SIGS, 'SIGNALS = (signal.SIGTERM, signal.SIGHUP)'),
    ["lifetime: SIGINT kills the whole group (grandchild)",
     "H8: SIGINT during the --version check: ERROR CANCELLED (exit 2), group killed, nothing sent"], serial=True)
mut("L05", "SIGTERM handler", (SIGS, 'SIGNALS = (signal.SIGINT, signal.SIGHUP)'),
    ["lifetime: SIGTERM kills the whole group (grandchild)",
     "H8: SIGTERM during the --version check: ERROR CANCELLED (exit 2), group killed, nothing sent"], serial=True)
mut("L06", "SIGHUP handler", (SIGS, 'SIGNALS = (signal.SIGINT, signal.SIGTERM)'),
    ["lifetime: SIGHUP kills the whole group (grandchild)",
     "H8: SIGHUP during the --version check: ERROR CANCELLED (exit 2), group killed, nothing sent"], serial=True)
mut("L07", "the --timeout check", ('            if Cancel.reason is None and time.monotonic() >= deadline:', '            if False:'),
    [LT_TMO], serial=True)
mut("L08", "stdin fed from a thread",
    ('        feeder = threading.Thread(target=feed_stdin, args=(proc.stdin, stdin_text.encode("utf-8")),\n'
     '                                  daemon=True)\n        feeder.start()\n',
     '        feed_stdin(proc.stdin, stdin_text.encode("utf-8"))\n'),
    ["lifetime: a child that never reads a 1 MiB stdin cannot block --timeout 3s"], serial=True)

# ---------------------------------------------------------------------------------------------
# fence

PROBES = "launch: fence probes from inside the stub"
FSTATIC = "fence: static allowlist of fence-1.sb"
WALLOW = "launch: the fence's write allows (home, tmp, /dev/null, /dev/tty, /dev/dtracehelper)"
mut("F01", "(deny file-read*)", ('        "(deny file-read*)",\n', ''), [PROBES, FSTATIC])
mut("F02", "(deny file-write*)", ('        "(deny file-write*)",\n', ''), [PROBES, FSTATIC])
mut("F03", "the repo .env deny", ("    if repo:\n        # Names that start with .env", "    if False:\n        # Names that start with .env"),
    [PROBES, FSTATIC])
mut("F04", "the .env deny covers nested dirs", ('}/(.*/)?', '}/'), [PROBES])
ENVRX = '(' + BS * 2 + '.env[^/]*|[^/]*' + BS * 2 + '.env)(/.*)?$"'
H6_DENY = ("H6: .env-like names at any depth (.envrc .env-prod .env_local .environment sub/.envrc prod.env "
           "sub/x.env) are denied")
H6_GUARD = "H6 guard: names that only hold 'env' (environment.md envoy.yaml src/env.ts x.env.example) stay readable"
H6_FENCE = "H6: fence-1.sb's .env deny covers the new names, after the repo allow (fence-check)"
REPO_ENV = "R: .ENV, .Env.local and .env.LOCAL (other spellings of .env and .env.local on APFS) are denied"
mut("F05a", "the .env deny: names that START with .env (.envrc, .env-prod, .env.local)",
    (ENVRX, '([^/]*' + BS * 2 + '.env)(/.*)?$"'), [H6_DENY, H6_FENCE, REPO_ENV])
mut("F05b", "the .env deny: names that END in .env (prod.env, sub/x.env)",
    (ENVRX, '(' + BS * 2 + '.env[^/]*)(/.*)?$"'), [H6_DENY, H6_FENCE])
mut("F05c", "the .env deny: any suffix after .env ([^/]*), not .env alone",
    (ENVRX, '(' + BS * 2 + '.env|[^/]*' + BS * 2 + '.env)(/.*)?$"'), [H6_DENY, H6_FENCE, REPO_ENV])
mut("F05d", "the .env deny is anchored at the end of the name (x.env.example stays readable)",
    (ENVRX, '(' + BS * 2 + '.env[^/]*|[^/]*' + BS * 2 + '.env)(/.*)?"'), [H6_GUARD, H6_FENCE])
OVL = "launch: dsh reads both --patch overlays under the fence; nothing else at the top of out"
mut("F06", "overlay literal: review.patch.yml",
    ('for name in ("review.patch.yml", f"run-{n}.patch.yml")]', 'for name in (f"run-{n}.patch.yml",)]'), [OVL])
mut("F07", "overlay literal: run-N.patch.yml",
    ('for name in ("review.patch.yml", f"run-{n}.patch.yml")]', 'for name in ("review.patch.yml",)]'), [OVL])
mut("F08", "overlay literal: this attempt's run-N, not run-1",
    ('for name in ("review.patch.yml", f"run-{n}.patch.yml")]', 'for name in ("review.patch.yml", "run-1.patch.yml")]'),
    ["attempts: attempt 2 reads review.patch.yml and run-2.patch.yml, not run-1.patch.yml"])
BROADC = "fence: a node under a broad prefix is narrowed to its bin dir (fence_profile)"
H3_FP = ("H3: node at <home>/bin or <home>/.local/bin never gets the home or ~/.local whole (fence_profile, "
         "HOME and pw_dir)")
mut("F09", "node's prefix is allowed whole only when unsafe_dir() says it is safe",
    ('    if not unsafe_dir(prefix):\n        dirs.append(prefix)', '    if True:\n        dirs.append(prefix)'),
    [BROADC, H3_FP])
mut("F10", "BROAD holds /usr/local", ('BROAD = {"/", "/usr", "/usr/local", ', 'BROAD = {"/", "/usr", '), [BROADC])
mut("F11", "write allow: home", ('        f"(allow file-write* (subpath {sb_str(home_d)}))",\n', ''), [WALLOW])
mut("F12", "write allow: tmp", ('        f"(allow file-write* (subpath {sb_str(tmp_d)}))",\n', ''), [WALLOW])
mut("F13", "write allow: /dev/null", ('''        '(allow file-write* (literal "/dev/null"))',\n''', ''), [WALLOW])
mut("F14", "write allow: /dev/tty", ('''        '(allow file-write* (literal "/dev/tty"))',\n''', ''), [WALLOW])
mut("F15", "write allow: /dev/dtracehelper", ('''        '(allow file-write* (literal "/dev/dtracehelper"))',\n''', ''), [WALLOW])
mut("F16", "no --repo: <out>/work readable, never all of <out>",
    ('             repo if repo else work_d, home_d, tmp_d]', '             repo if repo else out, home_d, tmp_d]'),
    ["validate: a fully successful run passes"])
mut("F17", "--repo: the repo readable",
    ('             repo if repo else work_d, home_d, tmp_d]', '             work_d, home_d, tmp_d]'), [PROBES])

# ---------------------------------------------------------------------------------------------
# launch

ARGVC = "launch: stub argv[2:] == --print-invocation argv[5:], execPath == node realpath, patch hashes"
VERC = "launch: the --version check runs first, same env and fence"
mut("A01", "launch under sandbox-exec -f",
    ('    argv = [SANDBOX_EXEC, "-f", os.path.join(out, f"fence-{n}.sb"), node, binjs, "--profile", "headless",',
     '    argv = [node, binjs, "--profile", "headless",'), [PROBES])
mut("A02", "--version under sandbox-exec -f",
    ('    argv = [SANDBOX_EXEC, "-f", os.path.join(out, f"fence-{n}.sb"), node, binjs, "--version"]',
     '    argv = [node, binjs, "--version"]'), [VERC])
mut("A03", "--version with the child env",
    ('        done, rc, so, se = run_group(argv, cwd, venv, limit)', '        done, rc, so, se = run_group(argv, cwd, None, limit)'),
    [VERC])
mut("A04", "--patch review.patch.yml",
    ('"--patch", os.path.join(out, "review.patch.yml"), "--patch", os.path.join(out, f"run-{n}.patch.yml"),',
     '"--patch", os.path.join(out, f"run-{n}.patch.yml"),'), [ARGVC])
mut("A05", "--patch run-N.patch.yml",
    ('"--patch", os.path.join(out, "review.patch.yml"), "--patch", os.path.join(out, f"run-{n}.patch.yml"),',
     '"--patch", os.path.join(out, "review.patch.yml"),'), [ARGVC])
CONT = "attempts: --continue from another cwd writes *-2.*, keeps *-1.*, resumes the session"
mut("A06", "--session-id on --continue", ('    if session_id:\n        argv +=', '    if False:\n        argv +='), [CONT])
mut("A07", "node is the realpath of the PATH hit", ('    node = real(cand)', '    node = cand'), [PROBES, ARGVC])
mut("A08", "cwd is the repo", ('    cwd = repo if repo else os.path.join(out, "work")', '    cwd = os.path.join(out, "work")'), [ARGVC])

# ---------------------------------------------------------------------------------------------
# status and attempts

RPASS = "validate --repo: an absolute read inside the repo passes"
RDENIED = "validate --repo: every read denied, final says it could not access the files"
mut("T01", "status: repo recorded", ('"repo": repo, "repo_mode": bool(repo),', '"repo": None, "repo_mode": bool(repo),'), [RPASS, RDENIED])
mut("T02", "status: repo_mode recorded", ('"repo": repo, "repo_mode": bool(repo),', '"repo": repo, "repo_mode": False,'), [RPASS, RDENIED])
mut("T03", "status: expect_read recorded", ('        "expect_read": expect, "session_id": None,', '        "expect_read": [], "session_id": None,'),
    ["validate --repo: an --expect-read file never read while other reads succeeded"])
mut("T04", "--continue takes the repo from status-1.json",
    ('    repo = None\n    if rec_repo is not None:', '    repo = None\n    if a.repo is not None:'),
    [CONT, "attempts: --continue status-2 and --check"])
mut("T05", "a new nonce per attempt", ('    nonce = secrets.token_hex(8)', '    nonce = sha256_text(out)[:16]'),
    ["attempts: --continue status-2 and --check"])
mut("T06", "the next attempt number", ('    n = (attempts_in(out) or [0])[-1] + 1', '    n = 2'),
    ["attempts: --check defaults to the highest attempt; --check --attempt N selects"])
mut("T07", "never overwrite *-1.* (attempt 1 again, no OUT_EXISTS, no O_EXCL)",
    [('    n = (attempts_in(out) or [0])[-1] + 1', '    n = 1'),
     ('        if os.path.lexists(os.path.join(out, name)):', '        if False:'),
     ('    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL', '    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC'),
     ('f"run-{n}.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_EXCL', 'f"run-{n}.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC'),
     ('f"err-{n}.txt"), os.O_WRONLY | os.O_CREAT | os.O_EXCL', 'f"err-{n}.txt"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC')],
    [CONT], detail="*-1.* files changed")

# ---------------------------------------------------------------------------------------------
# install, default out, doctor

INST = "install: npm ci --ignore-scripts in a 0700 dsh dir with the pinned package files"
mut("I01", "npm ci --ignore-scripts", ('[npm, "ci", "--ignore-scripts", "--no-audit", "--no-fund"]', '[npm, "ci", "--no-audit", "--no-fund"]'), [INST])
mut("I02", "npm runs in the dsh dir", ('    r = subprocess.run(argv, cwd=d, env=env, stdin=subprocess.DEVNULL)', '    r = subprocess.run(argv, cwd=None, env=env, stdin=subprocess.DEVNULL)'), [INST])
mut("O01", "default out under temp_base(), not the inherited TMPDIR",
    ('tempfile.mkdtemp(prefix="deepseek-review-", dir=temp_base())', 'tempfile.mkdtemp(prefix="deepseek-review-", dir=None)'),
    ["scope: no --out puts out under DARWIN_USER_TEMP_DIR, ignoring the inherited TMPDIR"])
mut("D01", "doctor: a failing --dump-config is not 'composes cleanly'",
    ('        composed = done and rc == 0 and not drift', '        composed = done and not drift'),
    ["doctor: a failing --dump-config is an overlay PROBLEM (exit 1)"], real=True)
mut("D02", "doctor: a composition warning is not 'composes cleanly'",
    ('        composed = done and rc == 0 and not drift', '        composed = done and rc == 0'),
    ["doctor: a composition warning from --dump-config is an overlay PROBLEM (exit 1)"], real=True)
mut("D03", "doctor: a version mismatch fails the doctor", ('        ok &= ver == PINNED_VERSION', '        ok &= True'),
    ["doctor: a dsh version other than the pin is a MISMATCH (exit 1)"], real=True)


# ---------------------------------------------------------------------------------------------
# HIGH findings H1-H12 (2026-11-02) and the medium fixes before them

NUL = '"' + BS + 'x00"'  # the source text "\x00" (backslash, x, 0, 0)
# H1: the interpreter (the first line of the copy)
SHEBANG = '#!/usr/bin/env -S -u DEVELOPER_DIR /usr/bin/python3 -I\n'
mut("H01", "H1: -I (the caller's PYTHONPATH is ignored)",
    (SHEBANG, '#!/usr/bin/env -S -u DEVELOPER_DIR /usr/bin/python3\n'),
    ["H1: the caller's PYTHONPATH never loads a module into the wrapper"], detail="PYTHONPATH was imported")
mut("H02", "H1b: env -u DEVELOPER_DIR (the xcrun shim of /usr/bin/python3 ignores the caller's)",
    (SHEBANG, '#!/usr/bin/env -S /usr/bin/python3 -I\n'),
    ["H1b: the interpreter ignores the caller's DEVELOPER_DIR (beyond '#!/usr/bin/python3 -I')"],
    detail="followed the caller's DEVELOPER_DIR")
mut("H03", "H1: the interpreter is /usr/bin/python3, never python3 from PATH",
    (SHEBANG, '#!/usr/bin/env -S -u DEVELOPER_DIR python3 -I\n'),
    ["H1: a python3 first on the caller's PATH is never the wrapper's interpreter",
     "H1: PATH starting with '.' and a python3 in the cwd: the cwd's python3 never runs"])
# H2: git and otool
H2_GITS = ["H2: a git in <repo>/bin first on PATH never runs (the repo check uses /usr/bin/git)",
           "H2: a git in an absolute dir outside the repo, first on PATH, never runs"]
mut("H04", "H2: git is /usr/bin/git, never the caller's PATH",
    ('GIT = "/usr/bin/git"', 'GIT = shutil.which("git") or "/usr/bin/git"'), H2_GITS, detail="fake git ran")
H2B = "H2b: otool (node's dylib scan) ignores the caller's DEVELOPER_DIR (beyond the planned H2 fix)"
H3_DYLIB = ("H3: otool-listed dylib dirs, the OpenSSL etc dir and its cert.pem dir under a home are never "
            "allowed (node_read_dirs)")
mut("H05", "H2b: otool runs with the minimal env (PATH only)",
    ('timeout=30, env={"PATH": CHILD_PATH}).stdout', 'timeout=30).stdout'), [H2B, H3_DYLIB])
# H3/H5: unsafe_dir, clause by clause, and every caller
H3_COPY = "H3: node at <home>/bin/node (a copy, libnode in <home>/lib) runs; the fence still denies the home"
H5 = "setup: H5 DSH_DIR_UNSAFE (the dsh dir is the %s dir of HOME)"
H5_AWS = "setup: H5 DSH_DIR_UNSAFE (the dsh dir contains the realpath of HOME's ~/.aws)"
H5_LINKS = ["setup: H5 DSH_DIR_UNSAFE (bin.js is a symlink to a file in the repo)",
            "setup: H5 DSH_DIR_UNSAFE (the dsh package dir is a symlink into the repo)"]
NODE_UNSAFE = "setup: H3 NODE_DIR_UNSAFE (node directly in HOME)"
UD_HOME = '        if inside_ci(h, d) or (fold(os.path.dirname(d)) == fold(h) and not home_child_ok):'
mut("H06", "unsafe_dir: a BROAD system prefix", ('    if fold(d) in BROAD_FOLDED:\n        return True\n', ''), [BROADC])
mut("H07", "unsafe_dir: a home or a dir above one",
    (UD_HOME, '        if (fold(os.path.dirname(d)) == fold(h) and not home_child_ok):'), [H5 % "home"],
    equivalent=("SECRET_DIRS is not empty and overlaps() goes both ways: a d with inside(h, d) also holds "
                "<h>/.ssh, so the secret-dir clause below returns True for every such d"))
mut("H08", "unsafe_dir: a direct child of a home",
    (UD_HOME, '        if inside_ci(h, d):'), [H5 % "child", H3_FP])
mut("H09", "unsafe_dir: home_child_ok exempts a direct child (node's bin and lib dirs)",
    (UD_HOME, '        if inside_ci(h, d) or (fold(os.path.dirname(d)) == fold(h)):'), [H3_COPY, H3_FP])
SECRET_CL = '                if overlaps_ci(d, sd):\n                    return True'
mut("H10", "unsafe_dir: a dir overlapping a home's secret dir",
    (SECRET_CL, '                if False:\n                    return True'), [H5 % "secret", H5_AWS])
mut("H11", "unsafe_dir: secret overlap in both directions (a dir CONTAINING a secret dir's realpath)",
    (SECRET_CL, '                if inside_ci(d, sd):\n                    return True'), [H5_AWS])
mut("H12", "unsafe_dir: the realpath'd secret dir",
    ('            for sd in {os.path.join(h, s), real(os.path.join(h, s))}:\n                if overlaps_ci(d, sd):',
     '            for sd in {os.path.join(h, s)}:\n                if overlaps_ci(d, sd):'), [H5_AWS])
mut("H13", "unsafe_dir: every home (HOME and pw_dir)",
    ('    for h in homes():\n        if inside_ci(h, d)', '    for h in [home_dir()]:\n        if inside_ci(h, d)'), [H3_FP])
mut("H14", "node_read_dirs: node's bin dir with home_child_ok",
    ('        if not unsafe_dir(bindir, home_child_ok=True):\n', '        if not unsafe_dir(bindir):\n'),
    [H3_FP, H3_COPY])
mut("H15", "node_read_dirs: <prefix>/lib with home_child_ok",
    ('not unsafe_dir(libdir, home_child_ok=True)', 'not unsafe_dir(libdir)'), [H3_FP, H3_COPY])
mut("H16", "node_read_dirs: otool-listed dirs pass unsafe_dir",
    ('        if not unsafe_dir(d) and d not in dirs:', '        if d not in dirs:'), [H3_DYLIB], detail="allows")
mut("H17", "node_read_dirs: otool-listed dirs get no direct-child exemption",
    ('        if not unsafe_dir(d) and d not in dirs:', '        if not unsafe_dir(d, home_child_ok=True) and d not in dirs:'),
    [H3_DYLIB], detail="allows")
mut("H18", "node_read_dirs: the OpenSSL etc dir passes unsafe_dir",
    ('os.path.isdir(etc) and not unsafe_dir(etc) and etc not in dirs', 'os.path.isdir(etc) and etc not in dirs'),
    [H3_DYLIB], detail="allows")
mut("H19", "node_read_dirs: the cert.pem dir passes unsafe_dir",
    ('                    if not unsafe_dir(cd) and cd not in dirs:', '                    if cd not in dirs:'),
    [H3_DYLIB], detail="allows")
NDU = '    if unsafe_dir(os.path.dirname(bindir)) and unsafe_dir(bindir, home_child_ok=True):'
mut("H20", "NODE_DIR_UNSAFE", (NDU, '    if False:'), [NODE_UNSAFE])
mut("H21", "NODE_DIR_UNSAFE needs BOTH the prefix and the bin dir unsafe",
    (NDU, '    if unsafe_dir(os.path.dirname(bindir)) or unsafe_dir(bindir, home_child_ok=True):'), [H3_COPY])
mut("H22", "NODE_DIR_UNSAFE: the bin dir with home_child_ok",
    (NDU, '    if unsafe_dir(os.path.dirname(bindir)) and unsafe_dir(bindir):'), [H3_COPY])
mut("H23", "DSH_DIR_UNSAFE: unsafe_dir(dsh dir)",
    ('    if unsafe_dir(d):\n        raise SetupError("DSH_DIR_UNSAFE",\n', '    if False:\n        raise SetupError("DSH_DIR_UNSAFE",\n'),
    [H5 % "home", H5 % "child", H5 % "secret", H5_AWS])
mut("H24", "DSH_DIR_UNSAFE: bin.js resolves inside the dsh dir",
    ('    if not inside(real(binjs), d):', '    if False:'),
    H5_LINKS + ["H5: a bin.js symlinked to a file in the repo is refused by the bin.js check itself",
                "H5: a dsh package dir symlinked into the repo is refused by the bin.js check itself"])
# H4: HOME is not the only home
H4 = ["H4: with HOME=<fake>, --repo <pw_dir>/.ssh is REPO_SECRET_OVERLAP",
      "H4: with HOME=<fake>, --repo <pw_dir> is REPO_HOME_OR_ABOVE"]
FAKE_HOME_REPO = ["setup: REPO_HOME_OR_ABOVE (HOME)", "setup: REPO_SECRET_OVERLAP (inside ~/.ssh)",
                  "setup: REPO_DOTFILES (work-tree root == HOME)"]
mut("H25", "check_repo: pw_dir is a home too",
    ('def check_repo(arg: str) -> str:\n    hs = homes()', 'def check_repo(arg: str) -> str:\n    hs = [home_dir()]'), H4)
mut("H26", "check_repo: $HOME is a home too",
    ('def check_repo(arg: str) -> str:\n    hs = homes()', 'def check_repo(arg: str) -> str:\n    hs = [account_home()]'),
    FAKE_HOME_REPO)
mut("H27", "homes(): realpath($HOME) when HOME is set",
    ('    hs = [home_dir()] if os.environ.get("HOME") else []', '    hs = []'), FAKE_HOME_REPO + [H5 % "home"])
mut("H28", "homes(): the account's home is always added",
    ('    if acct not in hs:\n        hs.append(acct)', '    if False:\n        hs.append(acct)'), H4 + [H3_FP])
mut("H29", "account_home(): from the password database, not HOME",
    ('        pw = pwd.getpwuid(os.getuid()).pw_dir', '        pw = ""'), H4)
mut("H30", "REPO_DOTFILES: a work tree rooted at $HOME (not only at pw_dir)",
    ('    if fold(real(top.stdout.strip())) in {fold(h) for h in hs}:',
     '    if fold(real(top.stdout.strip())) == fold(account_home()):'),
    ["setup: REPO_DOTFILES (work-tree root == HOME)"])
# H7: --continue re-checks the recorded repo and the out dir
H7_SSH = "H7: --continue after the recorded repo became a symlink to ~/.ssh is refused before anything runs"
H7_MOVED = "H7: --continue after the recorded repo's realpath moved is CONTINUE_REPO_MISMATCH"
mut("H31", "--continue: STATUS_INVALID for a malformed status-1.json",
    ('    problem = status_problem(first)\n    if problem:', '    problem = status_problem(first)\n    if False:'),
    ["H11: --continue on a status-1.json with repo_mode null is STATUS_INVALID, before anything runs"])
mut("H32", "--continue: every scope check on the recorded repo",
    ('        repo = check_repo(rec_repo)\n', '        repo = rec_repo\n'), [H7_SSH, H7_MOVED])
mut("H33", "--continue: CONTINUE_REPO_MISMATCH when the recorded repo's realpath moved",
    ('        if repo != rec_repo:', '        if False:'), [H7_MOVED])
mut("H34", "--continue: OUT_OVERLAP (out dir vs repo, homes, dsh dir)",
    ('    check_out_overlap(out, repo, dsh_dir)\n    node = resolve_node(a.node, [repo, out])',
     '    node = resolve_node(a.node, [repo, out])'),
    ["H7: --continue --dsh-dir <inside the out dir> is OUT_OVERLAP"])
# H8: the version check
H8_HANG = ("H8: a hanging --version is bounded by --timeout 3s: DSH_VERSION_MISMATCH naming the timeout, "
           "group killed")
H8_SIG = ["H8: SIG%s during the --version check: ERROR CANCELLED (exit 2), group killed, nothing sent" % s
          for s in ("TERM", "INT", "HUP")]
H8_DOC = "H8: SIGTERM during the doctor's --version check: ERROR CANCELLED (exit 2), group killed"
H8_GC = "H8: a grandchild the --version check leaves behind is killed with its group (the review still runs)"
mut("H35", "run_attempt traps the signals before the version check",
    ('    old = trap_signals()\n    try:\n        return _run_attempt(**kw)', '    old = {}\n    try:\n        return _run_attempt(**kw)'),
    H8_SIG + ["lifetime: SIGINT kills the whole group (grandchild)"], serial=True)
mut("H36", "version check: the child env minus the API key",
    ('    venv = {k: v for k, v in env.items() if k != "DEEPSEEK_API_KEY"}', '    venv = dict(env)'),
    [VERC], detail="DEEPSEEK_API_KEY")
mut("H37", "version check: the limit is min(120 s, --timeout)",
    ('min(120, timeout))', '120)'), [H8_HANG], serial=True)
# run_group's group kill (shared by the version check and the doctor's --dump-config); the
# `if not done:` after it tells it from kill_group's and run_attempt's.
KILLPG_V = ("        os.killpg(proc.pid, signal.SIGKILL)\n    except (ProcessLookupError, PermissionError):\n"
            "        pass\n    if not done:\n")
RG_LIMIT = "R2: run_group (the doctor's --dump-config runner) stops at its limit and kills the whole group"
mut("H38", "version check: the group is killed even when the check finished",
    (KILLPG_V, KILLPG_V.replace("signal.SIGKILL)\n", "signal.SIGKILL) if not done else None\n", 1)),
    [H8_GC], serial=True, detail="survived")
mut("H39", "version check: the group is killed (no killpg at all)",
    (KILLPG_V, KILLPG_V.replace("        os.killpg(proc.pid, signal.SIGKILL)\n", "        pass\n", 1)),
    [H8_HANG, H8_GC, RG_LIMIT] + H8_SIG, serial=True)
mut("H40", "version check: a signal raises CANCELLED (nothing sent)",
    ('    if Cancel.reason is not None:\n        raise SetupError("CANCELLED"',
     '    if False:\n        raise SetupError("CANCELLED"'), H8_SIG + [H8_DOC], serial=True)
mut("H41", "version check: the wait loop stops on a signal",
    ('    while Cancel.reason is None and time.monotonic() < end:', '    while time.monotonic() < end:'),
    H8_SIG + [H8_DOC], serial=True)
mut("H42", "version check: a timeout says so",
    ('        return "", (f"dsh --version timed out after {limit:g}s (the limit is the smaller of 120 s and "\n'
     '                    f"--timeout); its process group was killed")',
     '        return "", "no answer"'), [H8_HANG], serial=True, detail="does not name the timeout")
mut("H43", "doctor: the version check runs with the signals trapped",
    ('        old = trap_signals()\n        try:\n            ver, why = version_ok(',
     '        old = {}\n        try:\n            ver, why = version_ok('), [H8_DOC], serial=True)
# H9: one final event; a result pairs only with an EARLIER call
H9_RBC = ["validate --repo: H9: a tool_result before its tool_call is not a read",
          "H9: --check on a fabricated stream whose read result precedes its call is REPO_NOT_READ"]
mut("H44", "FINAL_NOT_UNIQUE", ('    if len(finals) > 1:', '    if False:'),
    ["H9: two final events are FINAL_NOT_UNIQUE (live run; --check agrees)",
     "H9: --check on a fabricated stream with two final events is FINAL_NOT_UNIQUE"])
mut("H45", "collect_reads: a tool_call counts only from where it appears",
    ('    calls = {}\n', '    calls = {e.get("callId"): e for e in events '
                       'if e.get("type") == "tool_call" and call_id_ok(e.get("callId"))}\n'), H9_RBC)
# H10: --check needs the attempt's files and keeps the recorded reasons
H10_INC = '        except OSError:\n            fails.append(("ATTEMPT_INCOMPLETE"'
for mid, pre, case in [
        ("H46", "status-", "H10: --check with run-1.jsonl but no status-1.json (a SIGKILLed wrapper) is ATTEMPT_INCOMPLETE, exit 1"),
        ("H47", "run-", "H10: --check with run-1.jsonl deleted is ATTEMPT_INCOMPLETE naming it"),
        ("H48", "err-", "H10: --check with err-1.txt deleted is ATTEMPT_INCOMPLETE naming it, and keeps the recorded COMPOSE_WARNING")]:
    mut(mid, f"ATTEMPT_INCOMPLETE for a missing {pre}N file",
        (H10_INC, H10_INC.replace("            fails.append(", f'            if name.startswith("{pre}"):\n'
                                  f'                continue\n            fails.append(')), [case])
H10R = "H10: --check on a status recording %s is FAIL %s"
NOCODES = H10R % ("verdict FAIL with reasons that are no codes (lower case, a number, a space)", "RECORDED_FAIL")
mut("H49", "--check: STATUS_INVALID for a status that is not a JSON object",
    ('        if not isinstance(status, dict):\n            fails.append(("STATUS_INVALID"',
     '        if False:\n            fails.append(("STATUS_INVALID"'),
    ["H10: --check on a status-1.json that is a JSON list, not an object is STATUS_INVALID",
     "H10: --check on a status-1.json that is not JSON is STATUS_INVALID"])
mut("H50", "--check: a recorded FAIL's reasons are kept",
    ('    if status.get("verdict") == "FAIL":', '    if False:'),
    ["H10: --check with err-1.txt emptied still reports the recorded COMPOSE_WARNING",
     H10R % ("verdict FAIL with two recorded codes", "TURN_NOT_COMPLETED VERDICT_MISSING")])
mut("H51", "--check: a recorded reason must look like a code",
    ('isinstance(c, str) and re.fullmatch(r"[A-Z][A-Z_]{0,63}", c)]', 'isinstance(c, str)]'), [NOCODES])
mut("H52", "--check: a recorded reason must be a string",
    ('isinstance(c, str) and re.fullmatch(', 're.fullmatch('), [NOCODES])
mut("H53", "--check: recorded reasons must be a list",
    ('            if isinstance(rec, list) else []', '            if rec else []'),
    [H10R % ("verdict FAIL with reasons as a string, not a list", "RECORDED_FAIL")])
mut("H54", "--check: RECORDED_FAIL when a FAIL records no usable reason",
    ('        for c in rec or ["RECORDED_FAIL"]:', '        for c in rec:'),
    [H10R % ("verdict FAIL with no reasons", "RECORDED_FAIL"), NOCODES])
# H11: status_problem, clause by clause, and its users
H11 = "H11: --check on a status with %s is STATUS_INVALID"
REPO_CL = '    if rm and not (isinstance(rp, str) and os.path.isabs(rp) and ' + NUL + ' not in rp):'
EX_CL = 'all(isinstance(x, str) and ' + NUL + ' not in x for x in ex)'
mut("H55", "status_problem: repo_mode is a bool",
    ('    if not isinstance(rm, bool):\n        return', '    if False:\n        return'),
    [H11 % 'repo_mode "true" (a string)', H11 % "repo_mode 1 (a number)", H11 % "repo_mode null"])
mut("H56", "status_problem: repo_mode true needs a repo path", (REPO_CL, '    if False:'),
    [H11 % "repo_mode true and repo null", H11 % 'repo_mode true and repo ""',
     H11 % "repo_mode true and a relative repo", H11 % "repo_mode true and repo 5"])
mut("H57", "status_problem: the repo is a string",
    (REPO_CL, REPO_CL.replace("(isinstance(rp, str) and ", "(")),
    [H11 % "repo_mode true and repo 5", H11 % "repo_mode true and repo null"])
mut("H58", "status_problem: the repo is absolute",
    (REPO_CL, REPO_CL.replace(" and os.path.isabs(rp)", "")),
    [H11 % "repo_mode true and a relative repo", H11 % 'repo_mode true and repo ""'])
mut("H59", "status_problem: the repo holds no NUL",
    (REPO_CL, REPO_CL.replace(" and " + NUL + " not in rp", "")), [H11 % "repo_mode true and a repo holding NUL"])
mut("H60", "status_problem: the repo is checked only with repo_mode true",
    (REPO_CL, REPO_CL.replace("    if rm and not (", "    if not (")), ["validate: a fully successful run passes"])
mut("H61", "status_problem: expect_read is a list",
    ('    if not isinstance(ex, list) or not all(', '    if not all('), [H11 % 'expect_read "x" (a string)'])
mut("H62", "status_problem: each expect_read entry is a string",
    (EX_CL, 'all(' + NUL + ' not in x for x in ex)'), [H11 % "expect_read [1]"])
mut("H63", "status_problem: no expect_read entry holds NUL",
    (EX_CL, 'all(isinstance(x, str) for x in ex)'), [H11 % "expect_read holding a path with NUL"])
mut("H64", "validate: STATUS_INVALID for a malformed status",
    ('    if problem:\n        fails.append(("STATUS_INVALID"', '    if False:\n        fails.append(("STATUS_INVALID"'),
    [H11 % "repo_mode true and repo null", H11 % "repo_mode null", H11 % 'expect_read "x" (a string)'])
mut("H65", "validate: the repo checks are skipped for a malformed status",
    ('    if not problem and status["repo_mode"]:', '    if status["repo_mode"]:'),
    [H11 % "repo_mode true and repo null", H11 % "repo_mode true and repo 5"])
# H12: earlier PASS attempts' reads count, nothing else does
H12_FAILED = "H12 guard: reads of a FAILed attempt 1 do not count: attempt 2 that reads nothing is REPO_NOT_READ"
H12_TAMPER = "H12 guard: --check --attempt 2 stops counting attempt 1's read once status-1 says FAIL"
H12_PASS = "H12: attempt 2 that reads nothing passes on attempt 1's (PASS) read of src/a.txt; --check agrees"
mut("H66", "prior_reads: only attempts whose status says PASS",
    (' or st.get("verdict") != "PASS"', ''), [H12_FAILED, H12_TAMPER])
mut("H67", "prior_reads: never a malformed status's attempt",
    (' or status_problem(st):', ':'),
    ["H12 guard: --check --attempt 2 stops counting attempt 1's read once status-1 is malformed (expect_read a string)"],
    equivalent=("since review round 2 prior_reads re-validates every PASS attempt with validate(), whose first "
                "check is status_problem(status) (STATUS_INVALID), and nothing before it reads the status: "
                "a malformed status-k still fails validate() and the attempt is skipped by the next line. "
                "validate() reads repo and expect_read only when status_problem() found nothing, and the "
                "other fields only through .get() into f-strings, truthiness or is_int. Probe 2026-11-02 "
                "(scratchpad p8/probe.py): validate() on repo 7 / null / a list, expect_read null / [1] / 5 / "
                "a dict, repo_mode a string, signal a list, cancelled a dict, nonce a list, exit_code a "
                "string, each with an empty, a non-JSON and a valid stream (36 calls): no exception, "
                "STATUS_INVALID first every time"))
mut("H68", "prior_reads: only attempts BEFORE n", ('        if k >= n:\n            continue\n', ''),
    ["H12 guard: --check --attempt 1 never counts a later attempt's read (attempts 1 and 2 swapped)"])
mut("H69", "the live run passes prior_reads to validate",
    ('validate(stream, err_text, status, prior_reads(out, n))', 'validate(stream, err_text, status)'),
    [H12_PASS, "H12: --continue --expect-read <the file attempt 1 (PASS) read> passes"])
mut("H70", "--check passes prior_reads to validate", ('        status, prior_reads(out, n))', '        status)'),
    [H12_PASS], detail="--check disagrees")

# medium fixes (were temp mutations M1-M11 of tester report 4)
SCRUB_ERR = "R: a key dsh echoes into an error event, a composition warning and a denied path is [REDACTED] on stderr"
SCRUB_OUT = "R: a key dsh echoes into the final answer is [REDACTED] on stdout"
# since round 2 scrub_file() clears the files dsh wrote, so a live run never hands report() the key;
# --check on files a killed run left unscrubbed still does
CHK_ERR = "R2: --check with the key in its env prints [REDACTED] for a key left in run-1.jsonl and err-1.txt"
CHK_OUT = "R2: --check with the key in its env prints [REDACTED] for a key left in the answer in run-1.jsonl"
ODD = "R: --check on a stream with %s is a FAIL verdict (exit 1, its own codes), never an internal error"
RCONT = "R: --continue with %s"
mut("M01", "scrub() replaces every registered secret",
    ('        text = text.replace(value, "[REDACTED]")', '        text = text'), [SCRUB_ERR, SCRUB_OUT, CHK_ERR, CHK_OUT])
mut("M02", "main registers the key as a secret",
    ('    remember_secret(os.environ.get("DEEPSEEK_API_KEY"))', '    pass'), [SCRUB_ERR, SCRUB_OUT, CHK_ERR, CHK_OUT])
mut("M03", "report: denied lines are scrubbed",
    ('        print(scrub(f"denied: {d}"), file=sys.stderr)', '        print(f"denied: {d}", file=sys.stderr)'),
    [SCRUB_ERR, CHK_ERR], detail="denied: read /x/[REDACTED]/f")
mut("M04", "report: FAIL lines are scrubbed",
    ('            print(scrub(f"deepseek-review: FAIL {code}: {text}"), file=sys.stderr)',
     '            print(f"deepseek-review: FAIL {code}: {text}", file=sys.stderr)'), [SCRUB_ERR, CHK_ERR])
mut("M05", "report: the answer is scrubbed",
    ('    sys.stdout.write(scrub(final_text.rstrip("' + BS + 'n")) + "' + BS + 'n")',
     '    sys.stdout.write(final_text.rstrip("' + BS + 'n") + "' + BS + 'n")'), [SCRUB_OUT, CHK_OUT])
mut("M06", "doctor: key_problem() on the key",
    ('    problem = key_problem(key) if key else None', '    problem = None'),
    ["R: --doctor with a key holding a newline: 'key: invalid (length 11, bad positions [7])', exit 1, value absent"])
mut("M07", "collect_reads: call_id_ok() on callIds",
    ('    return isinstance(cid, (str, int)) and not isinstance(cid, bool) and cid != ""', '    return True'),
    [ODD % "list_callid"])
mut("M08", "collect_reads: a non-dict input counts as empty",
    ('        inp = inp if isinstance(inp, dict) else {}\n', ''), [ODD % "input_str"])
mut("M09", "collect_reads: a session cwd that is no NUL-free string is dropped",
    ('    if not isinstance(session_cwd, str) or ' + NUL + ' in session_cwd or not os.path.isabs(session_cwd):',
     '    if not os.path.isabs(session_cwd):'), [ODD % "cwd_int"])
mut("M10", "collect_reads: a file_path holding NUL is no read",
    ('        if not isinstance(fp, str) or not fp or ' + NUL + ' in fp:', '        if not isinstance(fp, str) or not fp:'),
    [ODD % "nul_path"])
mut("M11", "OUT_PARENT_MISSING", ('    if not os.path.isdir(parent):', '    if False:'),
    ["setup: R OUT_PARENT_MISSING"])
mut("M12", "--continue: a missing run-1.jsonl is CONTINUE_NO_SESSION",
    ('    except OSError:\n        sid = None', '    except ValueError:\n        sid = None'),
    [RCONT % "run-1.jsonl deleted is CONTINUE_NO_SESSION"])
mut("M13", "--continue: <out>/review.patch.yml equals the plugin's overlay",
    ('    if on_disk != current:', '    if False:'), [RCONT % "<out>/review.patch.yml edited is CONTINUE_PATCH_CHANGED"])
mut("M14", "--continue: the overlay hash status-1.json recorded equals the plugin's",
    ('    if recorded is not None and recorded != sha256_text(current):', '    if False:'),
    ["R: --continue when status-1.json recorded another review.patch.yml hash is CONTINUE_PATCH_CHANGED"])
STRAY3 = "attempts: --continue after a failed attempt 2 (stray fence-2.sb, run-2.patch.yml) runs as attempt 3"
STRAY4 = "attempts: --check ignores a setup-only attempt 4 (stray fence-4.sb, run-4.patch.yml) and judges attempt 3"
mut("M15", "--continue: the next attempt is one past ANY attempt file (a setup-only attempt too)",
    ('    n = (attempts_in(out) or [0])[-1] + 1', '    n = (attempts_in(out, started_only=True) or [0])[-1] + 1'),
    [STRAY3])
mut("M16", "--check: the default attempt is the highest STARTED one",
    ('    ns = attempts_in(out, started_only=True)\n    n = a.attempt', '    ns = attempts_in(out)\n    n = a.attempt'),
    [STRAY4])
mut("M17", "attempts_in(started_only): only status-N.json / run-N.jsonl mark a start",
    ('        if started_only and not (name.startswith("status-") or name.endswith(".jsonl")):', '        if False:'),
    [STRAY4])

# ---------------------------------------------------------------------------------------------
# case / normalization folding (tester round 7, 2026-11-02): every refusal compares fold()ed
# paths; the checks where a match ALLOWS stay case-sensitive.

CI_BROAD = "CI R11 unsafe_dir: upper-cased broad dirs"
CI_HOME = "CI R11 unsafe_dir: variants of a home, its direct child and its secret dirs"
CI_NFD = "CI R11 unsafe_dir: an NFC home given in NFD"
CI_ORDER = "CI R11 unsafe_dir: a home spelled with its combining marks reordered"
CI_USR = "CI R11 node_read_dirs: /USR/bin/node"
CI_R2 = "setup: CI R2 --dsh-dir <HOME variant>/.local"
CI_R3 = ["setup: CI R3 --dsh-dir <HOME>/.SSH/dsh", "setup: CI R3 --dsh-dir <HOME variant>/.ssh/dsh"]
CI_R5 = ["setup: CI R5 --repo <HOME variant>", "setup: CI R5 --repo <variant of HOME's parent>"]
CI_R7 = ["setup: CI R7 --out <repo variant>/o", "CI R7: nothing was written into the repo"]
FOLD = '    return unicodedata.normalize("NFD", unicodedata.normalize("NFD", p).casefold())'
mut("C01", "fold site 1: unsafe_dir's broad dirs compared folded",
    ('    if fold(d) in BROAD_FOLDED:', '    if d in BROAD:'), [CI_BROAD, CI_USR])
mut("C02", "fold site 2: unsafe_dir's home-or-above compared folded",
    (UD_HOME, '        if inside(h, d) or (fold(os.path.dirname(d)) == fold(h) and not home_child_ok):'), [CI_HOME],
    equivalent=("as H07: SECRET_DIRS is not empty and overlaps_ci() goes both ways, and fold(<h>/.ssh) is "
                "fold(h) + '/.ssh' (a '/' is a starter, so NFD and casefold split there), so every d with "
                "inside_ci(h, d) also overlaps <h>/.ssh folded and the secret-dir clause returns True"))
mut("C03", "fold site 3: unsafe_dir's direct-child-of-a-home compared folded",
    (UD_HOME, '        if inside_ci(h, d) or (os.path.dirname(d) == h and not home_child_ok):'), [CI_R2, CI_HOME])
mut("C04", "fold site 4: unsafe_dir's secret-dir overlap compared folded",
    (SECRET_CL, '                if overlaps(d, sd):\n                    return True'), CI_R3 + [CI_HOME])
mut("C05", "fold site 5: REPO_HOME_OR_ABOVE compared folded",
    ('    if inside_ci(home, repo):', '    if inside(home, repo):'),
    CI_R5 + ["setup: CI R5b --repo <dir>, HOME=<that dir in another case>/home (not created)"])
mut("C06", "fold site 6: REPO_SECRET_OVERLAP compared folded",
    ('            if overlaps_ci(repo, sd):', '            if overlaps(repo, sd):'),
    ["setup: CI R4 --repo <HOME>/.SSH/r", "setup: CI R4b --repo <HOME>/.SSH/r, r a git repo with mode 0311"])
mut("C07", "fold site 7: REPO_DOTFILES compared folded",
    ('    if fold(real(top.stdout.strip())) in {fold(h) for h in hs}:', '    if real(top.stdout.strip()) in hs:'),
    ["CI R6u check_repo: REPO_DOTFILES when git prints HOME in another case",
     "setup: CI R6b --repo <dotfiles HOME>/projects/sub, HOME a 0311 dir spelled in another case"])
mut("C08", "fold site 8: OUT_OVERLAP (repo) compared folded",
    ('    if repo and overlaps_ci(out, repo):', '    if repo and overlaps(out, repo):'),
    CI_R7 + ["setup: CI R7c --out <repo variant>/<a 0311 dir>/o", "CI R7c: nothing was written into the repo"])
mut("C09", "fold site 9: OUT_OVERLAP (HOME inside out) compared folded",
    ('    if any(inside_ci(h, out) for h in homes()):', '    if any(inside(h, out) for h in homes()):'),
    ["setup: CI R12 --out <variant of a dir holding HOME>"])
mut("C10", "fold site 10: OUT_OVERLAP (dsh dir) compared folded",
    ('    if overlaps_ci(out, real(dsh_dir)):', '    if overlaps(out, real(dsh_dir)):'),
    ["setup: CI R8 --out <dsh dir variant>/o",
     "setup: CI R8b --out <dir>, --dsh-dir <that dir in another case>/dsh, neither created"])
mut("C11", "fold site 11: NODE_IN_SCOPE compared folded",
    ('        if s and inside_ci(node, s):', '        if s and inside(node, s):'),
    ["setup: CI R9 --node <repo variant>/bin/node",
     "setup: CI R9b --node <repo variant>/bin/node, the node copy execute-only (0111)"])
mut("C12", "fold site 12: DSH_DIR_UNSAFE (overlap with the repo) compared folded",
    ('    if repo and overlaps_ci(d, repo):', '    if repo and overlaps(d, repo):'),
    ["setup: CI R10 --dsh-dir <repo variant>/dsh", "setup: CI R10b --dsh-dir <repo variant>/dsh, the dsh dir with mode 0311"])
mut("C13", "fold site 13: node_read_dirs' prefix test compared folded",
    ('and fold(prefix) not in ("/", "/usr"):', 'and prefix not in ("/", "/usr"):'), [CI_USR])
mut("C14", "fold(): casefold", (FOLD, '    return unicodedata.normalize("NFD", unicodedata.normalize("NFD", p))'),
    [CI_R2, CI_HOME] + CI_R3)
mut("C15", "fold(): the NFD steps", (FOLD, '    return p.casefold()'), [CI_NFD, CI_ORDER])
mut("C16", "fold(): NFD before casefold (U+0345 casefolds to a base letter)",
    (FOLD, '    return unicodedata.normalize("NFD", p.casefold())'), [CI_ORDER])
mut("C17", "fold(): NFD after casefold",
    (FOLD, '    return unicodedata.normalize("NFD", p).casefold()'), [CI_NFD, CI_ORDER],
    equivalent=("casefold() of an NFD string is already NFD on /usr/bin/python3's Unicode 13: casefold maps "
                "code point by code point, a scan of every code point alone and followed by one or two of "
                "11 combining marks (53.4 M strings) found no case where casefold(NFD(s)) differs from its "
                "NFD, and the only combining mark casefold changes (U+0345, ccc 240) becomes a starter "
                "(U+03B9), which cannot put marks out of canonical order; the outer NFD is defensive"))
mut("C18", "unsafe_dir compares fold(d), not d, with BROAD_FOLDED",
    ('    if fold(d) in BROAD_FOLDED:', '    if d in BROAD_FOLDED:'), [CI_BROAD])
# Round 2 (tester round 8): canon() respells every existing path as stored, so the exact compares
# where a match ALLOWS see one spelling on both sides. C19-C21 and C23-C24 drop the respelling
# where it feeds such a compare (the G cases now pass a variant and must be accepted); C22 folds
# the recorded-repo compare, which a case-only rename of the repo can see (G6).
CI_G1 = "CI G1: --expect-read <repo variant>/x names the stored file: the run passes and records it as stored"
CI_G2 = "CI G2: a bin.js symlink into a case variant of the dsh dir stays inside it: the run passes"
CI_G3 = "CI G3: --continue --repo <variant of the recorded repo> is the same repo: attempt 2 runs"
CI_G4 = "validate --repo: CI G4: a read reported under a case variant of the repo is a repo read"
CI_G4B = "CI G4b: --repo <variant> records the stored repo, and a relative read under dsh's cwd counts"
CI_G5 = "validate --repo: CI G5: an --expect-read file read under a case variant of its path is read"
CI_G6 = "setup: CI G6 --continue after a case-only rename of the recorded repo is CONTINUE_REPO_MISMATCH"
REALFN = '    return canon(os.path.realpath(os.path.expanduser(p)))'
mut("C19", "check_expect compares the stored spelling of an --expect-read file",
    ('    for p in paths:\n        rp = real(p)\n', '    for p in paths:\n        rp = os.path.realpath(p)\n'), [CI_G1])
mut("C20", "check_dsh: bin.js's stored spelling is compared with the dsh dir",
    ('    if not inside(real(binjs), d):', '    if not inside(os.path.realpath(binjs), d):'), [CI_G2])
mut("C21", "--continue: --repo's stored spelling is compared with the recorded repo",
    ('        given = real(a.repo)', '        given = os.path.realpath(a.repo)'), [CI_G3])
mut("C22", "--continue: the recorded repo compared exactly with what it resolves to now (a case-only rename)",
    ('        if repo != rec_repo:', '        if fold(repo) != fold(rec_repo):'), [CI_G6])
mut("C23", "collect_reads: a read path is respelled as stored",
    ('        read_ok.append(canon(os.path.realpath(fp)))', '        read_ok.append(os.path.realpath(fp))'),
    [CI_G4, CI_G5])
mut("C24", "real(): every resolved path is respelled as stored",
    (REALFN, REALFN.replace("canon(os.path.realpath(", "(os.path.realpath(")), [CI_G1, CI_G3, CI_G4B])
mut("C25", "--check prints a recorded code only once (dedupe against the codes already failed)",
    ('            if c not in codes:\n                fails.append((c, "recorded by the run"))',
     '            if True:\n                fails.append((c, "recorded by the run"))'),
    ["H10: --check prints a code recorded twice once",
     "H10: --check prints a recorded code that the stream also fails once"])

# ---------------------------------------------------------------------------------------------
# review round 2 fixes A-P (tester round 8, 2026-11-02), clause by clause

OKRUN = "validate: a fully successful run passes"
# A: the default dsh dir
mut("W01", "A: the default dsh dir is under the account's home, not $HOME",
    ('    return os.path.join(account_home(), ".local", "share"', '    return os.path.join(home_dir(), ".local", "share"'),
    ["print-invocation: default --dsh-dir is <account home>/.local/share/deepseek-review/dsh-0.2.1-rc.5 "
     "(HOME does not move it)"])
# B: a node from PATH must live in a known install location
ROOTS_U = "R2u node_roots: Homebrew and the account home's version managers, nothing else through PATH"
UNTR = '    if not arg and not any(inside(node, r) for r in node_roots()):'
mut("W02", "B: NODE_UNTRUSTED", (UNTR, '    if False:'),
    ["setup: NODE_UNTRUSTED (PATH node outside the known install locations)", ROOTS_U])
mut("W03", "B: NODE_UNTRUSTED only for a node found through PATH (--node may name any node)",
    (UNTR, '    if not any(inside(node, r) for r in node_roots()):'),
    ["node at an unusual location (a copy under fakehome/.nvm, named with --node) starts under the fence"])
NROOTS = '    for r in (*NODE_ROOTS, *(os.path.join(ah, x) for x in NODE_HOME_ROOTS)):'
mut("W04", "B: node_roots: the Homebrew prefixes", (NROOTS, '    for r in (*(os.path.join(ah, x) for x in NODE_HOME_ROOTS),):'),
    [ROOTS_U, OKRUN])
mut("W05", "B: node_roots: the version managers under the account home", (NROOTS, '    for r in NODE_ROOTS:'), [ROOTS_U])
mut("W06", "B: node_roots: /usr/local (Intel Homebrew)",
    ('NODE_ROOTS = ("/opt/homebrew", "/usr/local")', 'NODE_ROOTS = ("/opt/homebrew",)'), [ROOTS_U])
HROOTS = 'NODE_HOME_ROOTS = (".nvm/versions", ".volta", ".asdf/installs")'
for mid, drop in [("W07a", '".nvm/versions", '), ("W07b", '".volta", '), ("W07c", ', ".asdf/installs"')]:
    mut(mid, f"B: node_roots: {drop.strip(', ')}", (HROOTS, HROOTS.replace(drop, "", 1)), [ROOTS_U])
mut("W08", "B: node_roots: under the account's home, not $HOME",
    ('    ah = account_home()\n    roots = []', '    ah = home_dir()\n    roots = []'), [ROOTS_U])
# C: the prompt file
PR_LINK = "setup: R2 a PROMPT_FILE that is a symlink is PROMPT_UNSAFE"
PR_SSH = "setup: R2 a PROMPT_FILE reached through a symlinked dir into ~/.ssh is PROMPT_UNSAFE"
SECRET_U = "R2u in_secret_dir: a file in the realpath of a symlinked ~/.aws"
PR_DIRECT = "setup: R2 a PROMPT_FILE in ~/.ssh passed directly is PROMPT_UNSAFE (resolves into the secret dir)"
PR_REL = "setup: R3 PROMPT_FILE id_r3b run from ~/.ssh is PROMPT_UNSAFE (the opened file resolves into the secret dir)"
mut("W10", "C: PROMPT_UNSAFE for a prompt (the file opened) in a secret dir",
    ('    sd = in_secret_dir(p)\n    if sd:', '    sd = in_secret_dir(p)\n    if False:'), [PR_DIRECT, PR_REL])
mut("W11", "C: the file opened (F_GETPATH) is judged, not the path as given",
    ('        problem = (prompt_target_problem(opened) if opened', '        problem = (prompt_target_problem(path) if opened'),
    [PR_REL])
mut("W12", "C: the prompt is opened O_NOFOLLOW",
    ('        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)', '        fd = os.open(path, os.O_RDONLY)'), [PR_LINK])
mut("W13", "C: ELOOP (a symlinked prompt) is PROMPT_UNSAFE, not PROMPT_MISSING",
    ('        if e.errno == errno.ELOOP:', '        if False:'), [PR_LINK])
ISD = '            for sd in {os.path.join(h, s), real(os.path.join(h, s))}:\n                if inside_ci(p, sd):'
mut("W14", "C: in_secret_dir: the realpath'd secret dir",
    (ISD, ISD.replace("{os.path.join(h, s), real(os.path.join(h, s))}", "{os.path.join(h, s)}")), [SECRET_U])
mut("W15", "C: in_secret_dir: the literal secret dir",
    (ISD, ISD.replace("{os.path.join(h, s), real(os.path.join(h, s))}", "{real(os.path.join(h, s))}")),
    [PR_SSH, SECRET_U],
    equivalent=("as S18: the caller passes real(path), which has every symlink resolved, and homes() are "
                "realpaths, so a p under the literal <h>/<s> is also under real(<h>/<s>): when <h>/<s> is "
                "no symlink they are the same path, and when it is one, no resolved p can hold it"))
# D: --install
INST_ENV = "install: npm gets PATH=<node's dir>:<system dirs>, the account's HOME, and none of the caller's variables"
INST_NONPM = "install: no npm beside node is INSTALL_FAILED, and the dsh dir is never created"
INST_NOEXEC = "install: an npm beside node that is not executable is INSTALL_FAILED, and the dsh dir is never created"
INST_DIRNPM = "install: an npm beside node that is a directory is INSTALL_FAILED, and the dsh dir is never created"
INST_OUT = "install: an npm beside node that resolves outside node's prefix is INSTALL_FAILED, and it never runs"
mut("W20", "D: --install refuses an unsafe_dir() dsh dir",
    ('    if unsafe_dir(d):\n        raise SetupError("DSH_DIR_UNSAFE", f"{d} is a home',
     '    if False:\n        raise SetupError("DSH_DIR_UNSAFE", f"{d} is a home'),
    ["install: --dsh-dir HOME is DSH_DIR_UNSAFE before anything is written"])
mut("W21", "D: --install refuses an existing dsh dir that is no dir",
    ('        if not os.path.isdir(d):\n            raise SetupError("DSH_DIR_UNSAFE"', '        if False:\n            raise SetupError("DSH_DIR_UNSAFE"'),
    ["install: --dsh-dir naming a file is DSH_DIR_UNSAFE"])
IPERM = '        if st.st_uid != os.getuid() or st.st_mode & 0o022:'
mut("W22", "D: --install refuses a dsh dir owned by another user",
    (IPERM, '        if st.st_mode & 0o022:'), ["install: --dsh-dir /usr/share (owned by root) is DSH_DIR_UNSAFE"])
mut("W23", "D: --install refuses a group-writable dsh dir", (IPERM, IPERM.replace("0o022", "0o002")),
    ["install: an existing dsh dir with mode 770 (group- or world-writable) is DSH_DIR_UNSAFE"])
mut("W24", "D: --install refuses a world-writable dsh dir", (IPERM, IPERM.replace("0o022", "0o020")),
    ["install: an existing dsh dir with mode 702 (group- or world-writable) is DSH_DIR_UNSAFE"])
mut("W25", "D: INSTALL_DIR_NOT_EMPTY", ('        if extra:\n', '        if False:\n'),
    ["install: a dir holding other files is INSTALL_DIR_NOT_EMPTY, and its package.json is untouched"])
mut("W26", "D: an earlier install's files are no other files",
    ('set(os.listdir(d)) - INSTALL_ENTRIES', 'set(os.listdir(d))'),
    ["install: a second --install into the same dir runs (package.json, package-lock.json, node_modules are no other files)"])
NPMOK = 'not (os.path.isfile(npm) and os.access(npm, os.X_OK))'
mut("W27", "D: npm beside node must be an executable file", (NPMOK, 'False'), [INST_NONPM, INST_NOEXEC, INST_DIRNPM])
mut("W28", "D: npm must be a regular file", (NPMOK, 'not (os.access(npm, os.X_OK))'), [INST_DIRNPM])
mut("W29", "D: npm must be executable", (NPMOK, 'not (os.path.isfile(npm))'), [INST_NOEXEC])
mut("W30", "D: npm must resolve inside node's prefix",
    ('not inside(real(npm), os.path.dirname(os.path.dirname(node)))', 'False'), [INST_OUT])
NPMENV = '    env = {"PATH": f"{os.path.dirname(node)}:{CHILD_PATH}", "HOME": account_home()}'
mut("W31", "D: npm's PATH starts with node's dir", (NPMENV, NPMENV.replace('f"{os.path.dirname(node)}:{CHILD_PATH}"', "CHILD_PATH")),
    [INST_ENV])
mut("W32", "D: npm's HOME is the account's home", (NPMENV, NPMENV.replace("account_home()", "home_dir()")), [INST_ENV])
mut("W33", "D: npm gets the caller's LANG",
    ('    if os.environ.get("LANG"):\n        env["LANG"] = os.environ["LANG"]\n    argv = [npm',
     '    if False:\n        env["LANG"] = os.environ["LANG"]\n    argv = [npm'), [INST_ENV])
mut("W34", "D: npm runs with the minimal env, not the caller's",
    ('    r = subprocess.run(argv, cwd=d, env=env, stdin=subprocess.DEVNULL)', '    r = subprocess.run(argv, cwd=d, stdin=subprocess.DEVNULL)'),
    [INST_ENV])
mut("W35", "D: nothing is written before npm is checked",
    [('        os.makedirs(d, mode=0o700, exist_ok=True)\n        os.chmod(d, 0o700)\n', '        os.chmod(d, 0o700)\n'),
     ('    d = real(a.dsh_dir or default_dsh_dir())\n    # Nothing is written',
      '    d = real(a.dsh_dir or default_dsh_dir())\n    os.makedirs(d, mode=0o700, exist_ok=True)\n    # Nothing is written')],
    [INST_NONPM, INST_NOEXEC])
# E: everything under a dir named like .env
mut("W40", "E: the .env deny covers everything under a dir so named ((/.*)?)",
    (ENVRX, '(' + BS * 2 + '.env[^/]*|[^/]*' + BS * 2 + '.env)$"'),
    ["R2: files under a dir named like .env (.env.d/cred, cfg/.env/prod) are denied; others stay readable"])
# F: --continue keeps attempt 1's expectations and settings
mut("W41", "F: --continue keeps attempt 1's --expect-read",
    ('    carried = list(first["expect_read"])', '    carried = []'),
    ["R2: --continue keeps attempt 1's --expect-read: a follow-up that never reads it is EXPECTED_READ_MISSING"])
mut("W42", "F: --continue runs with status-1's model, effort and max_tokens",
    ('    model, effort, max_tokens = first["model"], first["effort"], first["max_tokens"]',
     '    model, effort, max_tokens = DEFAULT_MODEL, DEFAULT_EFFORT, MAX_TOKENS_CAP'),
    ["R2: --continue runs attempt 2 with attempt 1's model, effort and max_tokens"])
# G: canon()
CANON_U = "R2u canon: F_GETPATH answering another name or a relative path keeps the path as given"
CANON_RET = '    return got if got and os.path.isabs(got) and fold(got) == fold(p) else p'
mut("W45", "G: canon takes F_GETPATH's answer only when it folds to the path (case and normalization)",
    (CANON_RET, '    return got if got and os.path.isabs(got) else p'), [CANON_U])
mut("W46", "G: canon takes only an absolute answer",
    (CANON_RET, '    return got if got and fold(got) == fold(p) else p'), [CANON_U],
    equivalent=("canon() is only called with realpath() results, which are absolute, and fold() keeps a "
                "leading '/' and maps no other character to U+002F (casefold and canonical NFD never "
                "produce a solidus), so fold(got) == fold(p) already implies that got is absolute"))
# H: a read counts only with a result that is a non-empty string
NULL_RES = "R2: a completed read whose result is null is no read (REPO_NOT_READ)"
BLANK_RES = "R2: a completed read whose result is blank (whitespace only) is no read (REPO_NOT_READ)"
RES_CL = '        if not isinstance(result, str) or not READ_ENVELOPE.fullmatch(result):'
mut("W50", "H: a read's result must be a string", (RES_CL, '        if not READ_ENVELOPE.fullmatch(result):'), [NULL_RES])
mut("W51", "H: a read's result must not be blank", (RES_CL, '        if not isinstance(result, str):'), [BLANK_RES])
mut("W52", "H: a whitespace-only result is blank", (RES_CL, '        if not isinstance(result, str) or not result:'), [BLANK_RES])
# I: strict UTF-8
REVAL = ("R2: attempt 1's reads stop counting once its files fail (a composition warning in err-1.txt) "
         "though status-1 says PASS")
mut("W53", "I: validate decodes the stream strictly (STREAM_NOT_JSON on bad UTF-8)",
    ('        text = stream.decode("utf-8")\n    except UnicodeDecodeError as e:',
     '        text = stream.decode("utf-8", errors="replace")\n    except UnicodeDecodeError as e:'),
    ["R2: a byte that is not UTF-8 in the stream is STREAM_NOT_JSON, never a repaired answer"])
mut("W54", "I: parse_events decodes the stream strictly",
    ('        text = stream.decode("utf-8")\n    except UnicodeDecodeError:\n        return None',
     '        text = stream.decode("utf-8", errors="replace")\n    except UnicodeDecodeError:\n        return None'),
    [REVAL],
    equivalent=("parse_events' only caller is prior_reads, which calls it only after validate() of the same "
                "stream returned no failure, and validate() fails STREAM_NOT_JSON on any stream that is not "
                "UTF-8: parse_events never sees such a stream"))
# J: status_problem, field by field, and validate's own use of the fields
R2S = "R2: --check on a status whose %s is FAIL STATUS_INVALID (exit 1, no traceback)"
R2X_EXIT = "R2: --check on a status whose exit_code is false fails exactly DSH_EXIT_NONZERO STATUS_INVALID"
R2X_NONCE = "R2: --check on a status whose nonce is a regex fails exactly STATUS_INVALID VERDICT_MISSING"
CONT_MT = "setup: R2 --continue on a status-1.json with max_tokens -1 is STATUS_INVALID before attempt 2"
NONCE_CL = '    if not (isinstance(nonce, str) and re.fullmatch(r"[0-9a-f]{16}", nonce)):'
mut("W60", "J: status nonce", (NONCE_CL, '    if False:'), [R2S % "nonce is a number", R2S % "nonce is not 16 hex digits"])
mut("W61", "J: status nonce is a string", (NONCE_CL, '    if not re.fullmatch(r"[0-9a-f]{16}", nonce):'),
    [R2S % "nonce is a number"])
mut("W62", "J: status nonce is 16 hex digits", (NONCE_CL, '    if not isinstance(nonce, str):'),
    [R2S % "nonce is not 16 hex digits"])
mut("W63", "J: status exit_code / signal are integers or null", ('        if v is not None and not is_int(v):', '        if False:'),
    [R2S % "exit_code is false", R2S % "signal is a string"])
mut("W64", "J: status signal checked", ('    for k in ("exit_code", "signal"):', '    for k in ("exit_code",):'),
    [R2S % "signal is a string"])
mut("W65", "J: status exit_code checked", ('    for k in ("exit_code", "signal"):', '    for k in ("signal",):'),
    [R2S % "exit_code is false"])
mut("W66", "J: status cancelled is a bool", ('    if not isinstance(status.get("cancelled"), bool):', '    if False:'),
    [R2S % "cancelled is a string"])
MODEL_CL = '    if not (isinstance(m, str) and MODEL_RE.match(m)):'
mut("W67", "J: status model", (MODEL_CL, '    if False:'), [R2S % "model is a number", R2S % "model is not a model id"])
mut("W68", "J: status model is a string", (MODEL_CL, '    if not MODEL_RE.match(m):'), [R2S % "model is a number"])
mut("W69", "J: status model is a model id", (MODEL_CL, '    if not isinstance(m, str):'), [R2S % "model is not a model id"])
mut("W70", "J: status effort", ('    if status.get("effort") not in EFFORTS:', '    if False:'), [R2S % "effort is xhigh"])
MT_CL = '    if not (is_int(mt) and 1 <= mt <= MAX_TOKENS_CAP):'
mut("W71", "J: status max_tokens", (MT_CL, '    if False:'),
    [R2S % "max_tokens is -1", R2S % "max_tokens is past the cap", R2S % "max_tokens is true", CONT_MT])
mut("W72", "J: status max_tokens is an integer", (MT_CL, '    if not (1 <= mt <= MAX_TOKENS_CAP):'),
    [R2S % "max_tokens is true"])
mut("W73", "J: status max_tokens at least 1", (MT_CL, '    if not (is_int(mt) and mt <= MAX_TOKENS_CAP):'),
    [R2S % "max_tokens is -1", CONT_MT])
mut("W74", "J: status max_tokens at most the cap", (MT_CL, '    if not (is_int(mt) and 1 <= mt):'),
    [R2S % "max_tokens is past the cap"])
mut("W75", "J: is_int() refuses a bool",
    ('    return isinstance(v, int) and not isinstance(v, bool)', '    return isinstance(v, int)'),
    [R2S % "exit_code is false", R2S % "max_tokens is true", R2X_EXIT])
mut("W76", "J: validate's exit check needs an integer 0, not a value equal to 0",
    ('    elif not (is_int(status.get("exit_code")) and status.get("exit_code") == 0):',
     '    elif status.get("exit_code") != 0:'), [R2X_EXIT])
VNONCE = '    nonce = nonce if isinstance(nonce, str) and re.fullmatch(r"[0-9a-f]{16}", nonce) else None'
mut("W77", "J: the VERDICT regex takes a nonce only when it is 16 hex digits",
    (VNONCE, '    nonce = nonce if isinstance(nonce, str) else None'), [R2X_NONCE])
mut("W78", "J: the VERDICT regex takes a nonce only when it is a string",
    (VNONCE, '    nonce = nonce if re.fullmatch(r"[0-9a-f]{16}", nonce) else None'), [R2S % "nonce is a number"])
# K, L: the session cwd and earlier attempts
mut("W80", "K: a session cwd that is not absolute is dropped",
    ('    if not isinstance(session_cwd, str) or ' + NUL + ' in session_cwd or not os.path.isabs(session_cwd):',
     '    if not isinstance(session_cwd, str) or ' + NUL + ' in session_cwd:'),
    ["R2: a session cwd that is not absolute is ignored: a relative read is no read, even run from inside the repo"])
mut("W81", "L: prior_reads re-validates an earlier PASS attempt",
    ('        if validate(stream, err_k, st, list(got))[0]:\n            continue', '        if False:\n            continue'), [REVAL])
mut("W82", "L: prior_reads re-validates with the attempt's err-k.txt", ('                err_k = f.read()', '                err_k = ""'),
    [REVAL])
# M: the key
SCRUB_FORMS = ("R3: after a PASS, no file under <out> holds the key (dsh's sessions, logs and temp files too), "
               "and a symlink out of <out> is never followed")
KEYFORMS_EQ = ("KEY_CHARS (letters, digits, '.', '_', '-') holds no character json.dumps escapes (no quote, "
               "backslash, control or non-ASCII character), so json.dumps(key)[1:-1] == key: the set has one "
               "form, and its order cannot matter")
mut("W85", "M: a key shorter than 8 characters is KEY_INVALID",
    ('        return None if len(key) >= 8 else f"length {len(key)}, shorter than 8"', '        return None'),
    ["setup: R2 a key shorter than 8 characters is KEY_INVALID, never printed"])
SCRUB_SET = '    for form in sorted({key, json.dumps(key)[1:-1]}, key=len, reverse=True):'
mut("W86", "M: scrub_file replaces the JSON-escaped key",
    (SCRUB_SET, '    for form in sorted({key}, key=len, reverse=True):'), [SCRUB_FORMS], equivalent=KEYFORMS_EQ)
mut("W87", "M: scrub_file replaces the key as written",
    (SCRUB_SET, '    for form in sorted({json.dumps(key)[1:-1]}, key=len, reverse=True):'), [SCRUB_FORMS],
    equivalent=KEYFORMS_EQ)
SCRUB_NAMES = '    scrub_tree(out, key)\n    rc = proc.returncode'
mut("W88", "M: every file under <out> is scrubbed after dsh exits", (SCRUB_NAMES, '    rc = proc.returncode'),
    [SCRUB_FORMS])
mut("W89", "M: --continue scrubs <out> before it starts dsh",
    ('    scrub_tree(out, key)\n    n = (attempts_in(out)', '    n = (attempts_in(out)'),
    ["R3: --continue scrubs the key attempt 1 left under <out> before it starts dsh: attempt 2's dsh finds none at startup"])
mut("W90", "M: scrub_file puts the scrubbed copy in place", ('        os.replace(tmp, path)', '        pass'),
    [SCRUB_ERR, SCRUB_FORMS])
# N: symlinks in the dsh dir
DSH_LINK = "setup: R2 a symlink in the dsh dir that resolves outside it is DSH_DIR_UNSAFE"
WALK = '                if not inside(real(e.path), d):'
mut("W92", "N: a symlink in the dsh dir that resolves outside it", (WALK, '                if False:'), [DSH_LINK])
mut("W93", "N: the walk goes below the top of the dsh dir", ('                stack.append(e.path)', '                pass'), [DSH_LINK])
mut("W94", "N: the walk compares the stored spelling of a link's target",
    (WALK, '                if not inside(os.path.realpath(e.path), d):'), [CI_G2])
# O: a tool_result needs an earlier tool_call
RWC_CL = '        elif cid not in seen_calls:'
mut("W95", "O: RESULT_WITHOUT_CALL", (RWC_CL, '        elif False:'),
    H9_RBC + ["validate --repo: a completed tool_result whose callId matches no read call"])
mut("W96", "O: a tool_call or tool_result without a valid callId is CALL_ID_INVALID",
    ('        if not call_id_ok(cid):\n            fails.append(("CALL_ID_INVALID", f"a {kind}',
     '        if False:\n            fails.append(("CALL_ID_INVALID", f"a {kind}'),
    [ODD % "list_callid", "R3: --check on a stream with result_bad_callid is FAIL CALL_ID_INVALID REPO_NOT_READ"])
mut("W97", "O: only an EARLIER tool_call counts",
    (RWC_CL, '        elif cid not in {x.get("callId") for x in events '
     'if x.get("type") == "tool_call" and call_id_ok(x.get("callId"))}:'), H9_RBC)
# P: run_group and the doctor
DOCTOR_U = "R2u doctor: a --dump-config past its limit or cancelled never composes cleanly"
mut("W98", "P: run_group starts the check in its own session (its group can be killed)",
    ('stderr=subprocess.PIPE, start_new_session=True)', 'stderr=subprocess.PIPE, start_new_session=False)'),
    [RG_LIMIT, H8_GC], serial=True)
mut("W99", "P: run_group stops at its limit",
    ('    end = time.monotonic() + limit\n    so = se = b""', '    end = time.monotonic() + 20\n    so = se = b""'),
    [RG_LIMIT], serial=True)
mut("W100", "P: the doctor: a --dump-config that did not finish never composes cleanly",
    ('        composed = done and rc == 0 and not drift', '        composed = rc == 0 and not drift'), [DOCTOR_U])
mut("W101", "P: the doctor says --dump-config timed out",
    ('        elif not done:\n            print("overlay: PROBLEM: --dump-config timed out',
     '        elif False:\n            print("overlay: PROBLEM: --dump-config timed out'), [DOCTOR_U])
mut("W102", "P: the doctor raises CANCELLED on a signal during --dump-config",
    ('            if Cancel.reason is not None:\n                raise SetupError("CANCELLED", f"cancelled by {Cancel.reason} during --dump-config")',
     '            if False:\n                raise SetupError("CANCELLED", f"cancelled by {Cancel.reason} during --dump-config")'),
    [DOCTOR_U])

# gaps closed after review round 2 (tester round 9, 2026-11-02)
WALK_LOCK = "setup: R2 a dir in the dsh dir that cannot be listed is DSH_DIR_UNSAFE (cannot list), never an internal error"
WALK_EXC = '        except OSError:\n            raise SetupError("DSH_DIR_UNSAFE", f"cannot list {cur}") from None'
mut("W103", "check_dsh walk: an unlistable dir is DSH_DIR_UNSAFE (not an internal error)",
    (WALK_EXC, WALK_EXC.replace("except OSError:", "except KeyError:")), [WALK_LOCK])
mut("W104", "check_dsh walk: an unlistable dir is never skipped",
    (WALK_EXC, '        except OSError:\n            continue'), [WALK_LOCK])
mut("W105", "run_group reaps the child it killed at its limit",
    ('    if not done:\n        reap(proc)\n    return done, proc.returncode, so, se', '    return done, proc.returncode, so, se'),
    ["R2: run_group reaps the child it killed at its limit (no zombie left)"], serial=True)
CANON_T = '        if not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):\n            return p'
FIFO_REPO = ("setup: R2 --repo naming a FIFO is REPO_NOT_DIR, and the wrapper never opens it (a writer blocked "
             "on it stays blocked)")
CANON_SEEN = [CI_G1, CI_G2, CI_G3, CI_G4, CI_G4B, CI_G5, CI_G6, CANON_U]
mut("W106", "canon opens only a dir or a regular file (never a FIFO or a device)",
    (CANON_T, '        if False:\n            return p'), [FIFO_REPO])
mut("W107", "canon respells a dir", (CANON_T, '        if not stat.S_ISREG(st.st_mode):\n            return p'), CANON_SEEN)
mut("W108", "canon respells a regular file", (CANON_T, '        if not stat.S_ISDIR(st.st_mode):\n            return p'),
    CANON_SEEN)
mut("W109", "prior_reads re-validates attempt k with the reads of the attempts before it",
    ('        if validate(stream, err_k, st, list(got))[0]:', '        if validate(stream, err_k, st, [])[0]:'),
    ["R2: attempt 3 counts attempt 2's read, which counts only through attempt 1's (prior reads chain)"])
mut("W110", "K: a session cwd holding NUL is dropped",
    ('    if not isinstance(session_cwd, str) or ' + NUL + ' in session_cwd or not os.path.isabs(session_cwd):',
     '    if not isinstance(session_cwd, str) or not os.path.isabs(session_cwd):'),
    ["R2: a session cwd holding NUL is ignored: a relative read is no read (REPO_NOT_READ), never an internal error"])
mut("W111", "D: npm must resolve inside node's own prefix, nothing wider",
    ('not inside(real(npm), os.path.dirname(os.path.dirname(node)))',
     'not inside(real(npm), os.path.dirname(os.path.dirname(os.path.dirname(node))))'),
    ["install: an npm beside node that resolves into a sibling prefix (same parent dir) is INSTALL_FAILED, and it never runs"])
mut("W112", "collect_reads never ~-expands a relative read",
    ('            fp = os.path.join(session_cwd, fp)', '            fp = os.path.join(session_cwd, os.path.expanduser(fp))'),
    ["R2: a relative read of ~/<path> is joined to the session cwd, never expanded to HOME (EXPECTED_READ_MISSING)"])

# ---------------------------------------------------------------------------------------------
# Round 3 fix (wrapper b1b51970): one mutant per guard, each turning its own R3/R3b case red.
R3_DEEP = ("setup: R3 PROMPT_FILE lnk/p.txt under a cwd longer than PATH_MAX (lnk a symlink) is PROMPT_UNSAFE: "
           "its path cannot be checked")
R3_FGP = ("setup: R3 a PROMPT_FILE whose opened path is over 1024 bytes (F_GETPATH fails) is PROMPT_UNSAFE: "
          "it cannot be located")
R3_JUMP = "setup: R3 PROMPT_FILE <R>/jump/../.ssh/id_ed25519 (jump -> ~/.ssh) is PROMPT_UNSAFE naming the symlink <R>/jump"
R3_HARMLESS = "setup: R3 PROMPT_FILE through a user's symlinked dir is PROMPT_UNSAFE even when its target is harmless"
R3_TMPC = "R3 control: a PROMPT_FILE under /tmp (a root-owned symlink to /private/tmp) is accepted: the run passes"
R3_VARC = "R3 control: a PROMPT_FILE spelled through /var (a root-owned symlink to /private/var) is accepted: the run passes"
R3_KIND = "setup: R3 %s is PROMPT_UNSAFE after the open (no symlink involved)"
mut("W113", "R3 #1: a prompt path prefix that cannot be lstat'ed refuses the file (never 'no symlink')",
    ('        except OSError as e:\n            raise SetupError("PROMPT_UNSAFE", f"cannot check',
     '        except OSError as e:\n            return None\n            raise SetupError("PROMPT_UNSAFE", f"cannot check'),
    [R3_DEEP])
mut("W114", "R3 #1: a prompt F_GETPATH cannot locate is refused",
    ('                   else f"{path} cannot be located (F_GETPATH failed)")', '                   else None)'), [R3_FGP])
mut("W115", "R3 #1: a user's symlink on the prompt's path is refused",
    ('        if stat.S_ISLNK(st.st_mode) and st.st_uid != 0:\n            return cur', '        if False:\n            return cur'),
    [R3_JUMP, R3_HARMLESS])
mut("W116", "R3 #1: root's own symlinks (/tmp, /var) are allowed",
    ('        if stat.S_ISLNK(st.st_mode) and st.st_uid != 0:', '        if stat.S_ISLNK(st.st_mode):'), [R3_TMPC, R3_VARC])
mut("W117", "R3 #1: the last component is O_NOFOLLOW's (is a symlink), not the helper's",
    ('    for part in parts[1:-1]:', '    for part in parts[1:]:'), [PR_LINK])
mut("W118", "R3 #1: the helper reads the path as given (link/.. kept)",
    ('    parts = as_given(path).split("/")', '    parts = os.path.abspath(path).split("/")'), [R3_JUMP])
mut("W119", "R3 #1: the helper skips empty and '.' components",
    ('        if part in ("", "."):\n            continue\n', ''), [R3_JUMP],
    equivalent=("an empty or '.' component names the dir already lstat'ed one step before (a trailing '/' or '/.' "
                "resolves it, so it is never a symlink); a non-dir there fails isfile() first (PROMPT_MISSING); and "
                "where '<1023-byte dir>/' itself overflows PATH_MAX, the original goes on to an opened path over "
                "1024 bytes, which F_GETPATH cannot give: PROMPT_UNSAFE either way"))
mut("W120", "R3 #1: a dotfile directly in a home is refused",
    ('        if fold(os.path.dirname(p)) == fold(h) and os.path.basename(p).startswith("."):', '        if False:'),
    [R3_KIND % "PROMPT_FILE <HOME>/.netrc"])
mut("W121", "R3 #1: the home rule needs a dotfile",
    ('        if fold(os.path.dirname(p)) == fold(h) and os.path.basename(p).startswith("."):',
     '        if fold(os.path.dirname(p)) == fold(h):'),
    ["R3 control: a PROMPT_FILE directly in HOME that is not a dotfile is accepted: the run passes"])
mut("W122", "R3 #1: the dotfile rule needs the file directly in a home",
    ('        if fold(os.path.dirname(p)) == fold(h) and os.path.basename(p).startswith("."):',
     '        if os.path.basename(p).startswith("."):'),
    ["R3 control: a dotfile PROMPT_FILE not directly in a home (<R>/.review-prompt) is accepted: the run passes"])
mut("W123", "R3 #1: the .env pattern ignores case",
    (r'ENV_NAME = re.compile(r"\.env[^/]*|[^/]*\.env", re.IGNORECASE)', r'ENV_NAME = re.compile(r"\.env[^/]*|[^/]*\.env")'),
    [R3_KIND % "PROMPT_FILE <R>/.ENV (the pattern ignores case)"])
mut("W124", "R3 #1: the .env pattern's .env* half",
    (r'ENV_NAME = re.compile(r"\.env[^/]*|[^/]*\.env", re.IGNORECASE)', r'ENV_NAME = re.compile(r"[^/]*\.env", re.IGNORECASE)'),
    [R3_KIND % "PROMPT_FILE <R>/.env.d/cred"])
mut("W125", "R3 #1: the .env pattern's *.env half",
    (r'ENV_NAME = re.compile(r"\.env[^/]*|[^/]*\.env", re.IGNORECASE)', r'ENV_NAME = re.compile(r"\.env[^/]*", re.IGNORECASE)'),
    [R3_KIND % "PROMPT_FILE <R>/prod.env"])
mut("W126", "R3 #1a: real() takes .. after the symlink (no abspath first)",
    (REALFN, '    return canon(os.path.realpath(os.path.abspath(os.path.expanduser(p))))'),
    ["setup: R3 --repo <repo>/jump/.. with jump -> ~/.ssh/sub is REPO_SECRET_OVERLAP (.. taken after the symlink, as the kernel does)"])
mut("W127", "R3 #1: --node keeps link/.. as the kernel reads it",
    ('        cand = as_given(arg)', '        cand = os.path.abspath(os.path.expanduser(arg))'),
    ["R3: --node <d>/link/../bin/node (link -> <np>/sub) is <np>/bin/node, as the kernel opens it: the run passes"])
OUT_AS = '    a = as_given(arg).rstrip("/") or "/"'
mut("W128", "R3 #1: --out keeps link/.. as the kernel reads it",
    (OUT_AS, '    a = os.path.abspath(os.path.expanduser(arg)).rstrip("/") or "/"'),
    ["R3: --out <d2>/link/../o (link -> <el>/sub) is created at <el>/o, where the kernel puts it, never at <d2>/o"])
OUT_DOT = "setup: R3 --out <C>/newdir/. is OUT_EXISTS: it must name a new directory"
OUT_DOTDOT = "setup: R3 --out <C>/.. is OUT_EXISTS: it must name a new directory"
OUT_ROOT = "setup: R3 --out / is OUT_EXISTS: it must name a new directory"
OUT_NAME = '    if name in ("", ".", ".."):'
mut("W129", "R3 #1: --out must name a new directory", (OUT_NAME, '    if False:'), [OUT_DOT, OUT_DOTDOT, OUT_ROOT])
mut("W130", "R3 #1: --out . is refused", (OUT_NAME, '    if name in ("", ".."):'), [OUT_DOT])
mut("W131", "R3 #1: --out .. is refused", (OUT_NAME, '    if name in ("", "."):'), [OUT_DOTDOT])
mut("W132", "R3 #1: --out / is refused", (OUT_NAME, '    if name in (".", ".."):'), [OUT_ROOT])
mut("W133", "R3 #1: a trailing slash on --out names the dir before it", (OUT_AS, '    a = as_given(arg)'),
    ["R3: --out <C>/newo/ (a trailing slash) names <C>/newo: the run passes there"])
R3_LOCK = ("R3: a key file dsh left mode 0000 is scrubbed, a symlink to a dir outside <out> is never entered, "
           "and no scrub WARNING is printed")
R3_UCHG = ("R3: a key file under <out> that cannot be replaced is named in a scrub WARNING, leaves no .scrub-* temp "
           "file, and the run goes on")
R3_HL = "R3: a file under <out> hard-linked to one outside is scrubbed as a new file: the outside file keeps its bytes"
mut("W134", "R3 #2: scrub_tree never enters a symlinked dir",
    ('os.walk(root, followlinks=False)', 'os.walk(root, followlinks=True)'), [R3_LOCK])
mut("W135", "R3 #2: scrub_tree skips a symlink (lstat), never tries it",
    ('                if not stat.S_ISREG(os.lstat(p).st_mode):', '                if not stat.S_ISREG(os.stat(p).st_mode):'),
    [SCRUB_FORMS])
mut("W136", "R3 #2: an unreadable file is made readable, then scrubbed",
    ('                if not os.access(p, os.R_OK):\n                    os.chmod(p, 0o600)\n', ''), [R3_LOCK])
mut("W137", "R3 #2: a file that cannot be scrubbed is named in a WARNING",
    ('                print(scrub(f"deepseek-review: WARNING: could not scrub {p}: {e.strerror}"),\n'
     '                      file=sys.stderr)', '                pass'), [R3_UCHG])
mut("W138", "R3 #2: a scrub error is a WARNING, never an internal error",
    ('            except OSError as e:\n                print(scrub(f"deepseek-review: WARNING',
     '            except KeyError as e:\n                print(scrub(f"deepseek-review: WARNING'), [R3_UCHG])
mut("W139", "R3 #2: a failed scrub removes its temp copy",
    ('            try:\n                os.unlink(tmp)\n            except OSError:\n                pass\n            raise',
     '            raise'), [R3_UCHG])
mut("W140", "R3 #2: the scrub writes a new file and renames it over (a hard link keeps its bytes)",
    ('    if new != data:\n        tfd, tmp = tempfile.mkstemp(',
     '    if new != data:\n        with open(path, "wb") as f:\n            f.write(new)\n        return\n'
     '        tfd, tmp = tempfile.mkstemp('), [R3_HL])
mut("W141", "R3 #2: scrub_file opens with O_NOFOLLOW",
    ('    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)\n    with os.fdopen(fd, "rb") as f:\n        data = f.read()',
     '    fd = os.open(path, os.O_RDONLY)\n    with os.fdopen(fd, "rb") as f:\n        data = f.read()'), [SCRUB_FORMS],
    equivalent=("scrub_file is called only by scrub_tree, right after an lstat() found a regular file at that path; "
                "only a swap of the path for a symlink between the lstat and the open (a race inside <out>, which "
                "only the user and the dead dsh could write) reaches the flag"))
mut("W142", "R3 #2: scrub_file replaces the longer form first", (SCRUB_SET, '    for form in sorted({key, json.dumps(key)[1:-1]}):'),
    [SCRUB_FORMS], equivalent=KEYFORMS_EQ)
R3_SHAPE = "R3: --check on a stream with %s is FAIL %s"
mut("W143", "R3 #3: two tool_calls with one callId are CALL_ID_INVALID",
    ('            if cid in seen_calls:\n                fails.append(("CALL_ID_INVALID", f"two tool_calls',
     '            if False:\n                fails.append(("CALL_ID_INVALID", f"two tool_calls'),
    [R3_SHAPE % ("dup_call", "CALL_ID_INVALID")])
mut("W144", "R3 #4: two tool_results for one callId are CALL_ID_INVALID", ('        elif cid in answered:', '        elif False:'),
    [R3_SHAPE % ("dup_result", "CALL_ID_INVALID")])
mut("W145", "R3 #5: a read counts only with dsh's envelope", (RES_CL, '        if not isinstance(result, str) or not result.strip():'),
    [R3_SHAPE % (v, "REPO_NOT_READ") for v in ("plain_read", "dir_envelope", "envelope_tail")])
mut("W146", "R3 #5: the envelope's type must be file",
    (r'</path>\n<type>file</type>\n<content>', r'</path>\n<type>[a-z]+</type>\n<content>'),
    [R3_SHAPE % ("dir_envelope", "REPO_NOT_READ")])
mut("W147", "R3 #5: the envelope is the whole result", ('READ_ENVELOPE.fullmatch(result)', 'READ_ENVELOPE.match(result)'),
    [R3_SHAPE % ("envelope_tail", "REPO_NOT_READ")])
SESS_CWD = '        if not (isinstance(cwd, str) and os.path.isabs(cwd) and ' + NUL + ' not in cwd):'
mut("W148", "R3 #6: a relative session cwd is SESSION_INVALID",
    (SESS_CWD, '        if not (isinstance(cwd, str) and ' + NUL + ' not in cwd):'),
    ["R2: a session cwd that is not absolute is ignored: a relative read is no read, even run from inside the repo"])
mut("W149", "R3 #6: a session cwd holding NUL is SESSION_INVALID",
    (SESS_CWD, '        if not (isinstance(cwd, str) and os.path.isabs(cwd)):'),
    ["R2: a session cwd holding NUL is ignored: a relative read is no read (REPO_NOT_READ), never an internal error"])
mut("W150", "R3 #6: a session cwd that is not a string is SESSION_INVALID (never an internal error)",
    (SESS_CWD, '        if not (os.path.isabs(cwd) and ' + NUL + ' not in cwd):'), [ODD % "cwd_int"])
SESS_ID = '        elif not (isinstance(sid, str) and SESSION_ID_RE.fullmatch(sid)):'
R3_SID = "R3: --check on a stream whose sessionId is %s is FAIL SESSION_INVALID"
mut("W151", "R3 #6: an invalid sessionId is SESSION_INVALID", (SESS_ID, '        elif False:'),
    [R3_SID % "'bad id!'", R3_SID % "'-lead'", R3_SID % "201 characters long"])
mut("W152", "R3 #6: a sessionId that is not a string is SESSION_INVALID (never an internal error)",
    (SESS_ID, '        elif not SESSION_ID_RE.fullmatch(sid):'), [R3_SHAPE % ("sid_int", "SESSION_INVALID")])
SID_RE = 'SESSION_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,199}")'
mut("W153", "R3 #6: a sessionId starts with a letter or digit", (SID_RE, 'SESSION_ID_RE = re.compile(r"[A-Za-z0-9._:-]{1,200}")'),
    [R3_SID % "'-lead'"])
mut("W154", "R3 #6: a sessionId is at most 200 characters",
    (SID_RE, 'SESSION_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,200}")'), [R3_SID % "201 characters long"])
mut("W155", "R3 #6: a 200-character sessionId is valid",
    (SID_RE, 'SESSION_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,198}")'),
    ["R3 control: --check on a stream whose sessionId is 200 characters long passes"])
mut("W156", "R3 #6: the whole sessionId must match", ('SESSION_ID_RE.fullmatch(sid)', 'SESSION_ID_RE.match(sid)'),
    [R3_SID % "'bad id!'"])
mut("W157", "R3 #6: --continue takes only a valid sessionId from run-1.jsonl",
    ('SESSION_ID_RE.fullmatch(ev["sessionId"])', 'ev["sessionId"]'),
    ["R3: --continue after an attempt whose sessionId is invalid ('bad id!') is CONTINUE_NO_SESSION"])
R3_CARRY = ("R3: --continue carries attempt 2's --expect-read into attempt 3: a follow-up that never reads it is "
            "EXPECTED_READ_MISSING")
mut("W158", "R3 #7: --continue carries every earlier attempt's --expect-read",
    ('        carried += st["expect_read"]', '        pass'), [R3_CARRY])
mut("W159", "R3 #7: a malformed status-k is STATUS_INVALID",
    ('        if problem:\n            raise SetupError("STATUS_INVALID", f"status-{k}.json',
     '        if False:\n            raise SetupError("STATUS_INVALID", f"status-{k}.json'),
    ["setup: R3 --continue with status-2.json malformed (expect_read 5) is STATUS_INVALID naming status-2.json"])
CARRY_IF = '        if k == 1 or not os.path.exists(os.path.join(out, f"status-{k}.json")):'
mut("W160", "R3 #7: a missing status-k is skipped", (CARRY_IF, '        if k == 1:'),
    ["R3: --continue with status-2.json missing (attempt 2 killed before its record) skips it: attempt 3 runs and passes"])
mut("W161", "R3 #7: status-1 is not loaded twice",
    (CARRY_IF, '        if not os.path.exists(os.path.join(out, f"status-{k}.json")):'), [R3_CARRY],
    equivalent=("for k == 1 the loop would load status-1.json again, the file mode_continue already loaded and "
                "checked with status_problem, and add its expect_read a second time; dict.fromkeys() then drops "
                "the duplicates in order, so the expect list is the same"))
R3_CANCEL = "CI R3 cancel: a signal during validate, and one after the checkpoint"
mut("W162", "R3 #8: a signal during validate cancels the attempt",
    ('        if Cancel.reason is not None and not status["cancelled"]:', '        if False:'), [R3_CANCEL])
mut("W163", "R3 #8: after the checkpoint the signals are held until the answer is printed",
    ('    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)', '    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])'),
    [R3_CANCEL])
R3_UNREAD = "setup: R3 --repo with mode 0311 (not listable, not in a secret dir) is REPO_UNREADABLE"
REPO_ACC = '    if not os.access(repo, os.R_OK | os.X_OK):'
mut("W164", "R3 #9: a repo the user cannot list is REPO_UNREADABLE", (REPO_ACC, '    if False:'), [R3_UNREAD])
mut("W165", "R3 #9: listing needs read permission", (REPO_ACC, '    if not os.access(repo, os.X_OK):'), [R3_UNREAD])
mut("W166", "R3 #9: listing needs search permission", (REPO_ACC, '    if not os.access(repo, os.R_OK):'), [R3_UNREAD],
    equivalent=("check_repo runs `git -C <repo> rev-parse` just before; without search (x) permission git cannot "
                "chdir into the repo and the repo is REPO_NOT_GIT before this line is reached"))
mut("W167", "R3 #10: a key is letters, digits, '.', '_' and '-' only (KEY_CHARS, not 'printable')",
    ('    bad = [i for i, c in enumerate(key) if c not in KEY_CHARS]',
     '    bad = [i for i, c in enumerate(key) if not (33 <= ord(c) <= 126)]'),
    ["R2: a key holding a quote, a backslash, a space or a '+' is KEY_INVALID by length and positions; its value "
     "is printed nowhere and dsh never starts"])
R3_ROOTS = "CI R3 node_roots: realpath'd, and never / or a home"
ROOT_IF = '        if rr != "/" and not any(inside_ci(h, rr) for h in homes()):'
mut("W168", "R3 #11: node_roots takes each root where it leads", ('        rr = real(r)  #', '        rr = r  #'), [R3_ROOTS])
mut("W169", "R3 #11: a root at / or a home is dropped", (ROOT_IF, '        if True:'), [R3_ROOTS])
mut("W170", "R3 #11: a root at a home is dropped", (ROOT_IF, '        if rr != "/":'), [R3_ROOTS])
mut("W171", "R3 #11: a root at / is dropped", (ROOT_IF, '        if not any(inside_ci(h, rr) for h in homes()):'), [R3_ROOTS],
    equivalent=("every home is inside /, so any(inside_ci(h, '/')) is true whenever homes() is not empty, and "
                "homes() always holds the account's home: a root at / is dropped by the second clause too"))
mut("W172", "R3 #12: a given --out in a dir the fence lets node read is OUT_OVERLAP",
    ('    if out is not None:\n        check_out_node(out, node_dirs)', '    if False:\n        check_out_node(out, node_dirs)'),
    ["setup: R3 --out <np>/lib/o with --node <np>/bin/node is OUT_OVERLAP (the fence lets node read its prefix)"])
mut("W173", "R3 #12: the auto out dir in a dir the fence lets node read is OUT_OVERLAP",
    ('                check_out_node(out, node_dirs)\n', ''),
    ["setup: R3 no --out with --node directly in the per-user temp dir is OUT_OVERLAP (the auto out dir would be in "
     "node's prefix)"])
mut("W174", "R3 #12: --continue checks the out dir against node's dirs",
    ('    check_out_node(out, node_read_dirs(node))', '    pass'),
    ["setup: R3 --continue on an out inside the prefix of --node is OUT_OVERLAP"])
mut("W175", "R3 #13: --timeout over 24h is a usage error", ('    if secs > TIMEOUT_MAX:', '    if False:'),
    ["usage: R3 --timeout 25h (over 24h) is a usage error"])
mut("W176", "R3 #13: --timeout 24h itself is allowed", ('    if secs > TIMEOUT_MAX:', '    if secs >= TIMEOUT_MAX:'),
    ["R3 control: --timeout 24h (the limit itself) is accepted: the run passes"])
mut("W177", "R3 #13: a review.patch.yml that is not UTF-8 is CONTINUE_PATCH_CHANGED",
    ('    except (OSError, ValueError):\n        raise SetupError("CONTINUE_PATCH_CHANGED"',
     '    except OSError:\n        raise SetupError("CONTINUE_PATCH_CHANGED"'),
    ["setup: R3 --continue with <out>/review.patch.yml no longer UTF-8 is CONTINUE_PATCH_CHANGED"])
mut("W178", "R3 #13: an out dir that cannot be made is OUT_NOT_CREATED",
    ('    except OSError as e:\n        raise SetupError("OUT_NOT_CREATED"', '    except KeyError as e:\n        raise SetupError("OUT_NOT_CREATED"'),
    ["setup: R3 --out under a parent the user cannot write is OUT_NOT_CREATED"])
mut("W179", "R3 #13: --install into a dir it cannot create is DSH_DIR_UNSAFE",
    ('    except OSError as e:\n        raise SetupError("DSH_DIR_UNSAFE", f"cannot create',
     '    except KeyError as e:\n        raise SetupError("DSH_DIR_UNSAFE", f"cannot create'),
    ["setup: R3 --install into a dir it cannot create is DSH_DIR_UNSAFE, and npm never runs"])

# ---------------------------------------------------------------------------------------------
# machinery

def sha256_file(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def make_copy(dst):
    """dst/deepseek/{bin,dsh,scripts}: a copy of the plugin the harness and wrapper run from."""
    root = os.path.join(dst, "deepseek")
    os.makedirs(root)
    for sub in ("bin", "dsh", "scripts"):
        shutil.copytree(os.path.join(PLUGIN, sub), os.path.join(root, sub), symlinks=True,
                        ignore=shutil.ignore_patterns("__pycache__"))
    return root


def apply(src, repl):
    for old, new in repl:
        c = src.count(old)
        if c != 1:
            return None, f"target found {c} times: {old[:70]!r}"
        src = src.replace(old, new)
    return src, None


def ere_escape(s):
    return re.sub(r'([\\.\[\](){}*+?|^$])', r'\\\1', s)


def selection(blocks):
    return "^(" + "|".join(ere_escape(b) for b in sorted(blocks)) + ")$"


def run_harness(root, dsr_only, real_dir, log_path):
    env = dict(os.environ)
    env["DSR_ONLY"] = dsr_only
    env.pop("DSH_REAL_DIR", None)
    if real_dir:
        env["DSH_REAL_DIR"] = real_dir
    t0 = time.monotonic()
    p = subprocess.Popen(["/bin/bash", os.path.join(root, "scripts", "test-deepseek-review.sh")],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                         env=env, cwd=root, start_new_session=True)
    killed = []

    def watchdog():
        if p.poll() is None:
            killed.append(1)
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

    timer = threading.Timer(RUN_TIMEOUT, watchdog)
    timer.start()
    written, truncated = 0, False
    with open(log_path, "wb") as log:
        for chunk in iter(lambda: p.stdout.read(65536), b""):
            room = LOG_CAP - written
            if room > 0:
                log.write(chunk[:room])
                written += min(len(chunk), room)
            if len(chunk) > room:
                truncated = True
    rc = p.wait()
    timer.cancel()
    with open(log_path, "rb") as f:
        text = f.read().decode("utf-8", "replace")
    return {"rc": rc, "text": text, "wall": round(time.monotonic() - t0, 1),
            "timed_out": bool(killed), "truncated": truncated}


COUNT_RE = re.compile(r"^(\d+) passed, (\d+) failed, (\d+) skipped$")


def parse(text):
    """The verdict lines, FAIL blocks and the final counts, cross-checked."""
    lines = text.split("\n")
    oks, fails, skips, desel = [], {}, 0, []
    cur = None
    for ln in lines:
        if ln.startswith("FAIL  "):
            cur = ln[6:]
            fails.setdefault(cur, []).append(ln)
            continue
        # A FAIL block's detail runs to the next verdict or section line: a detail can span
        # several lines, and the continuation lines are not indented (e.g. the modes list).
        if cur is not None and not (ln.startswith(("ok    ", "SKIP ", "DESEL [", "== ", "selection: "))
                                    or COUNT_RE.match(ln)):
            fails[cur].append(ln)
            continue
        cur = None
        if ln.startswith("ok    "):
            oks.append(ln[6:])
        elif ln.startswith("SKIP "):
            skips += 1
        elif ln.startswith("DESEL ["):
            desel.append(ln)
    nonempty = [ln for ln in lines if ln.strip()]
    m = COUNT_RE.match(nonempty[-1]) if nonempty else None
    problems = []
    if not m:
        problems.append("no final 'N passed, M failed, K skipped' line (empty or truncated output)")
        counts = None
    else:
        counts = tuple(int(x) for x in m.groups())
        nfail = sum(1 for ln in lines if ln.startswith("FAIL  "))
        if (len(oks), nfail, skips) != counts:
            problems.append(f"verdict lines (ok {len(oks)}, FAIL {nfail}, SKIP {skips}) disagree with "
                            f"the counts line {counts}")
    return {"oks": oks, "fails": fails, "desel": desel, "counts": counts, "problems": problems}


def listing(base_root, workdir):
    r = run_harness(base_root, "^$", None, os.path.join(workdir, "listing.log"))
    pr = parse(r["text"])
    if pr["problems"] or pr["counts"][1] != 0:
        sys.exit(f"FATAL: the listing run is not clean: {pr['problems'] or pr['fails']}")
    m = {}
    for ln in pr["desel"]:
        mm = re.match(r"^DESEL \[(.*?)\] (.*)$", ln)
        if mm:
            m.setdefault(mm.group(2), set()).add(mm.group(1))
    return m, r["wall"]


def judge(mt, pr, run):
    if run["timed_out"]:
        return "BROKEN", f"harness run killed after {RUN_TIMEOUT}s"
    if run["truncated"]:
        return "BROKEN", "log truncated at the cap"
    if pr["problems"]:
        return "BROKEN", "; ".join(pr["problems"])
    failed = pr["counts"][1]
    if mt["equivalent"]:
        if failed == 0:
            return "EQUIVALENT-OK", mt["equivalent"]
        return "ELSEWHERE", "declared equivalent but red: " + ", ".join(sorted(pr["fails"]))[:300]
    if failed == 0:
        return "SURVIVED", "selected run green"
    own = [n for n in mt["expect"] if n in pr["fails"]]
    if not own:
        return "ELSEWHERE", "red only on: " + ", ".join(sorted(pr["fails"]))[:400]
    if mt["detail"]:
        hit = [n for n in own if any(mt["detail"] in ln for ln in pr["fails"][n])]
        if not hit:
            return "ELSEWHERE", (f"own case red but no failure text holds {mt['detail']!r}: "
                                 + " | ".join(pr["fails"][own[0]][1:3])[:300])
        own = hit
    first = pr["fails"][own[0]]
    return "CAUGHT", f"{own[0]} :: {(first[1].strip() if len(first) > 1 else '')[:160]}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True, help="a fresh dir for copies and logs")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--only", default="", help="ERE on mutant ids")
    ap.add_argument("--real-dir", default=os.environ.get("DSH_REAL_DIR", ""),
                    help="dsh install for the real=True mutants (default: $DSH_REAL_DIR)")
    ap.add_argument("--phase", choices=("all", "parallel", "serial"), default="all")
    a = ap.parse_args()

    t_start = time.monotonic()
    tree_sha = sha256_file(WRAPPER)
    print(f"tree wrapper sha256 at start: {tree_sha}", flush=True)
    os.makedirs(a.work, exist_ok=False)
    ids = [m["id"] for m in MUTANTS]
    if len(ids) != len(set(ids)):
        sys.exit("FATAL: duplicate mutant ids")
    todo = [m for m in MUTANTS if re.search(a.only, m["id"])]
    if a.phase == "parallel":
        todo = [m for m in todo if not m["serial"]]
    elif a.phase == "serial":
        todo = [m for m in todo if m["serial"]]

    base_root = make_copy(os.path.join(a.work, "base"))
    vmap, lwall = listing(base_root, a.work)
    print(f"listing: {len(vmap)} selectable cases in {lwall}s", flush=True)
    with open(WRAPPER, encoding="utf-8") as f:
        clean_src = f.read()

    results = {}
    plans = []
    for m in todo:
        blocks = set()
        missing = [n for n in m["expect"] if n not in vmap]
        for n in m["expect"]:
            blocks |= vmap.get(n, set())
        src, why = apply(clean_src, m["repl"])
        if missing:
            results[m["id"]] = ("BROKEN", f"expected case(s) not in the harness: {missing}", None)
            continue
        if why:
            results[m["id"]] = ("BROKEN", why, None)
            continue
        if not blocks and not m["equivalent"]:
            results[m["id"]] = ("BROKEN", "no expected case", None)
            continue
        if m["equivalent"] and not blocks:
            # An equivalent mutant still runs the cases nearest its guard.
            blocks = {b for n, bs in vmap.items() if "REPO_SECRET_OVERLAP" in n for b in bs}
        plans.append((m, src, selection(blocks), a.real_dir if m["real"] else ""))

    if any(m["real"] for m, *_ in plans) and not a.real_dir:
        sys.exit("FATAL: real=True mutants need --real-dir or DSH_REAL_DIR")

    # Baselines: the clean copy once per distinct (selection, real) pair.
    base_keys = sorted({(sel, rd, m["serial"]) for m, _s, sel, rd in plans})
    baseline = {}

    def run_base(key):
        sel, rd, _serial = key
        i = base_keys.index(key)
        r = run_harness(base_root, sel, rd, os.path.join(a.work, f"baseline-{i:03d}.log"))
        return key, r, parse(r["text"])

    def run_mut(plan):
        m, src, sel, rd = plan
        d = os.path.join(a.work, m["id"])
        root = make_copy(d)
        w = os.path.join(root, "bin", "deepseek-review")
        with open(w, "w", encoding="utf-8") as f:
            f.write(src)
        cp = subprocess.run(["/usr/bin/python3", "-c",
                             "import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)",
                             w, os.path.join(d, "compiled.pyc")], capture_output=True, text=True)
        if cp.returncode != 0:
            return m, ("BROKEN", "mutant does not compile: " + " ".join(cp.stderr.split())[-200:], None)
        r = run_harness(root, sel, rd, os.path.join(a.work, f"{m['id']}.log"))
        pr = parse(r["text"])
        v, why = judge(m, pr, r)
        shutil.rmtree(d, ignore_errors=True)
        return m, (v, why, r["wall"])

    def base_ok(m, sel, rd):
        key = (sel, rd, m["serial"])
        r, pr = baseline[key]
        if pr["problems"] or r["timed_out"]:
            return f"baseline broken: {pr['problems'] or 'timeout'}"
        if pr["counts"][1] != 0:
            return "baseline red: " + ", ".join(sorted(pr["fails"]))[:300]
        notok = [n for n in m["expect"] if n not in pr["oks"]]
        if notok:
            return f"baseline did not print ok for {notok}"
        return None

    def phase(plans_here, base_here, jobs):
        with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
            for key, r, pr in ex.map(run_base, base_here):
                baseline[key] = (r, pr)
                print(f"baseline {base_keys.index(key):03d}: {pr['counts']} in {r['wall']}s "
                      f"{'RED ' + str(sorted(pr['fails'])) if pr['counts'] and pr['counts'][1] else ''}", flush=True)
        ready = []
        for plan in plans_here:
            m, _src, sel, rd = plan
            why = base_ok(m, sel, rd)
            if why:
                results[m["id"]] = ("BROKEN", why, None)
            else:
                ready.append(plan)
        with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
            for m, res in ex.map(run_mut, ready):
                results[m["id"]] = res
                print(f"{m['id']:5s} {res[0]:13s} {res[2]}s  {m['guard']}  -- {res[1][:200]}", flush=True)

    par = [p for p in plans if not p[0]["serial"]]
    ser = [p for p in plans if p[0]["serial"]]
    if par:
        phase(par, [k for k in base_keys if not k[2]], a.jobs)
    if ser:
        phase(ser, [k for k in base_keys if k[2]], 1)

    # Report.
    end_sha = sha256_file(WRAPPER)
    wall = round(time.monotonic() - t_start)
    rows = []
    for m in MUTANTS:
        if m["id"] not in results:
            continue
        v, why, w = results[m["id"]]
        rows.append({"id": m["id"], "guard": m["guard"], "expect": m["expect"], "verdict": v, "why": why,
                     "wall": w, "serial": m["serial"], "real": m["real"]})
    with open(os.path.join(a.work, "results.json"), "w") as f:
        json.dump({"rows": rows, "tree_sha_start": tree_sha, "tree_sha_end": end_sha, "wall": wall}, f, indent=1)
    good = {"CAUGHT", "EQUIVALENT-OK"}
    bad = [r for r in rows if r["verdict"] not in good]
    print()
    for r in rows:
        print(f"{r['id']}\t{r['verdict']}\t{r['guard']}\t{r['why'][:180]}")
    print()
    print(f"mutants: {len(rows)}, caught {sum(r['verdict'] == 'CAUGHT' for r in rows)}, "
          f"equivalent {sum(r['verdict'] == 'EQUIVALENT-OK' for r in rows)}, not caught {len(bad)}; wall {wall}s")
    if end_sha != tree_sha:
        print(f"FAIL: the tree wrapper changed during the run: {tree_sha} -> {end_sha}")
        sys.exit(1)
    print(f"tree wrapper sha256 unchanged: {end_sha}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
