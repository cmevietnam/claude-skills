# CLI reference

Observations of **dsh 0.2.1-rc.5** on macOS 14 (Darwin 23.5), node 25.2.1 (Homebrew), made on
2026-11-01 with a loopback Anthropic-Messages mock unless marked otherwise. dsh's GitHub README
documents `master`, which is ahead of rc.5. Flags it describes, such as `--permission-mode`,
`--approval-policy`, `--add-dir` and a `reason` field on `final`, **do not exist in rc.5**.
Re-verify everything here before changing `PINNED_VERSION`.

## `deepseek-review`

```
deepseek-review [--model M] [--effort low|high|max] [--max-tokens N] [--repo DIR]
                [--expect-read PATH]... [--out DIR] [--timeout T]
                [--node PATH] [--dsh-dir DIR] PROMPT_FILE
deepseek-review --continue OUT_DIR [--repo DIR] [--expect-read PATH]... PROMPT_FILE
deepseek-review --check OUT_DIR [--attempt N]
deepseek-review --print-invocation [run options] PROMPT_FILE
deepseek-review --install [--dsh-dir DIR] [--node PATH]
deepseek-review --doctor [--dsh-dir DIR] [--node PATH]
```

**Defaults:**

- model `deepseek-flash` (DeepSeek-V4.1-Flash), effort `max`, `--max-tokens 393216` (range
  1–393216);
- `--timeout 30m` (seconds, or `<n>s|m|h`; at most 24h);
- dsh dir `~/.local/share/deepseek-review/dsh-0.2.1-rc.5`, under the account's home from the
  password database (an inherited `HOME` does not move it);
- node: `--node`, or the first absolute PATH entry holding `node` whose realpath is under
  `/opt/homebrew`, `/usr/local`, `~/.nvm/versions`, `~/.volta` or `~/.asdf/installs` (the
  account's home). A node anywhere else needs `--node`;
- paths: every path the wrapper resolves is resolved the way the kernel opens it (`R/link/..` is
  the dir above where `link` leads) and respelled as the volume stores it (letter case, Unicode
  form), so `--repo /users/ME/x` records `/Users/me/x`, as dsh reports it;
- out dir: a fresh `mkdtemp` under the per-user temp dir (`getconf DARWIN_USER_TEMP_DIR`); an
  inherited `TMPDIR` is ignored.

**Exit codes:** 0 = a review (stdout is the answer); 1 = dsh ran but the result is not a review;
2 = setup or usage error, nothing sent.

**Setup errors** (`deepseek-review: ERROR <CODE>: …`, exit 2):

- prompt: `PROMPT_MISSING`, `PROMPT_EMPTY`, `PROMPT_UNSAFE` (the prompt file is a symlink, its
  path goes through a symlink not owned by root, or the file opened is in a home's secret dir, is
  a dotfile directly in a home, or matches the `.env` pattern);
- options: `MODEL_INVALID`, `EFFORT_INVALID`, `MAX_TOKENS_INVALID`;
- key: `KEY_MISSING`, `KEY_INVALID` (any character other than letters, digits, `.`, `_` and `-`,
  or shorter than 8 characters; reports only the length and the bad positions);
- repo scope: `REPO_NOT_DIR`, `REPO_IS_ROOT`, `REPO_HOME_OR_ABOVE`, `REPO_SECRET_OVERLAP`,
  `REPO_NOT_GIT`, `REPO_DOTFILES`, `REPO_UNREADABLE` (a dir you cannot list), `REPO_BAD_CHARS`.
  The home checks apply to both realpath(`$HOME`) and the account's home from the password
  database;
- expect-read: `EXPECT_READ_NEEDS_REPO`, `EXPECT_READ_OUTSIDE_REPO`;
- out dir: `OUT_EXISTS`, `OUT_PARENT_MISSING`, `OUT_OVERLAP` (also inside, or holding, a dir the
  fence lets node read), `OUT_NOT_CREATED`, `OUT_PERMS`;
- node: `NODE_NOT_FOUND`, `NODE_IN_SCOPE`, `NODE_UNTRUSTED` (a node found through PATH outside
  the known install locations above), `NODE_DIR_UNSAFE` (the fence could allow node's dirs only by
  opening a home, a secret dir or a broad system dir; `safety-model.md`);
- dsh: `DSH_MISSING`, `DSH_DIR_UNSAFE` (also when the dir is unsafe by the same rule, or its
  `bin.js` or any other symlink in it resolves outside it), `DSH_VERSION_MISMATCH` (also when
  `--version` times out);
- `--continue`: `CONTINUE_REPO_MISMATCH` (a different `--repo`, or the recorded repo now resolves
  elsewhere), `CONTINUE_NO_SESSION`, `CONTINUE_PATCH_CHANGED`, `STATUS_INVALID` (a malformed
  status record of any earlier attempt). It re-runs every repo scope check on the recorded repo,
  and the out-dir overlap checks against the dsh dir and node it is given. The `--expect-read`
  files every earlier attempt's status recorded stay required (an attempt killed before its
  status has none to carry); new `--expect-read` files add to them. Before it starts dsh, it
  scrubs the key from every file in the out dir;
- `CANCELLED`: a signal arrived during the `dsh --version` check, before anything was sent;
- other: `NO_SANDBOX`.

`--install` writes nothing before it has checked the dsh dir: an unsafe dir, or one it cannot
create, is `DSH_DIR_UNSAFE`,
and an existing dir holding anything but `package.json`, `package-lock.json` and `node_modules` is
`INSTALL_DIR_NOT_EMPTY`. It runs the `npm` beside node (never one from PATH) with
`PATH=<node's dir>:/usr/bin:/bin:/usr/sbin:/sbin`, the account's `HOME` and `LANG` only: no key,
no `npm_config_*`, no `NODE_OPTIONS`. `INSTALL_FAILED` (no npm beside node, or npm failing)
exits 1.

**Validation failures** (`deepseek-review: FAIL <CODE>: …`, one line per failed check, exit 1,
stdout empty):

- process: `DSH_EXIT_NONZERO`, `CANCELLED`, `COMPOSE_WARNING`;
- stream shape: `STREAM_EMPTY`, `STREAM_NOT_JSON` (also stdout that is not valid UTF-8),
  `SESSION_NOT_FIRST`, `SESSION_INVALID` (the session event has no absolute cwd or no valid
  `sessionId`), `FINAL_NOT_LAST`, `FINAL_NOT_UNIQUE`, `ERROR_EVENT`, `RESULT_WITHOUT_CALL` (a
  `tool_result` whose callId no earlier `tool_call` carries), `CALL_ID_INVALID` (a `tool_call` or
  `tool_result` without a valid callId, two `tool_call`s sharing one, or two results for one
  call);
- turn outcome: `NO_TURN_END`, `TURN_NOT_COMPLETED`;
- answer: `FINAL_EMPTY`, `VERDICT_MISSING`, `VERDICT_DUPLICATE`;
- reading: `REPO_NOT_READ`, `EXPECTED_READ_MISSING`. A `tool_result` counts as a read only when
  its `tool_call` came earlier in the stream, it completed with dsh's file envelope
  (`<path>…</path>`, `<type>file</type>`, `<content>…</content>`), and its path, taken as
  written (absolute, or joined to the session's absolute cwd; never `~`-expanded), resolves inside
  the repo. For attempt N ≥ 2, the reads of earlier attempts whose status records `verdict: PASS`
  and whose files still validate count too; a failed attempt's reads never do;
- record: `STATUS_INVALID` (`repo_mode` not a boolean, `repo_mode` true without an absolute
  `repo`, `expect_read` not a list of paths, `nonce` not 16 hex digits, `exit_code` or `signal`
  neither an integer nor null, `cancelled` not a boolean, or `model`, `effort` or `max_tokens`
  outside what the options accept).

**`--check`** re-runs these checks from the attempt's files. It also fails `ATTEMPT_INCOMPLETE`
when `status-N.json`, `run-N.jsonl` or `err-N.txt` cannot be read (a wrapper killed with SIGKILL
leaves no status), and it keeps a recorded FAIL: the reason codes in `status-N.json` are reported
even when the evidence for them is gone (an emptied `err-N.txt`), and a FAIL with no codes is
`RECORDED_FAIL`.

**Out dir.** `home/` (DSH_HOME), `tmp/` and `work/` (the cwd when `--repo` is absent), plus
`review.patch.yml`. Per attempt N: `prompt-N.txt`, `run-N.patch.yml`, `fence-N.sb`,
`run-N.jsonl`, `err-N.txt`, `status-N.json`. Directories are 0700, files 0600, and nothing is
overwritten. After dsh exits, on every outcome, the key is replaced with `[REDACTED]`, as written
and as JSON escapes it, in every regular file under the out dir: the captures, and what dsh keeps
in its home (sessions, startup diagnostics). Symlinks are not followed. A wrapper killed with
SIGKILL cannot scrub; the next `--continue` does it before it starts dsh.

**Launch.** cwd is the repo, or `<out>/work`; the prompt goes on stdin; dsh runs in its own
process group:

```
/usr/bin/sandbox-exec -f <out>/fence-N.sb <node> <dsh-dir>/node_modules/@deepseek-ai/dsh/lib/bin.js \
  --profile headless --patch <out>/review.patch.yml --patch <out>/run-N.patch.yml --json [--session-id ID] -
```

**Child env (allowlist).**

- `PATH=/usr/bin:/bin:/usr/sbin:/sbin`;
- `HOME=DSH_HOME=<out>/home`, `TMPDIR=<out>/tmp`;
- `DSH_TELEMETRY_DISABLED=1`, `DSH_PERMISSION_MODE=read-only`;
- `DEEPSEEK_API_KEY` passed through, and `LANG` if set.

**Version check.** Before the run, `dsh --version` runs under the same fence and env, minus
`DEEPSEEK_API_KEY`, in its own process group. Its limit is the smaller of 120 s and `--timeout`;
past it the group is killed and the attempt ends `DSH_VERSION_MISMATCH` (timed out). A signal
during the check kills the group and ends the attempt `ERROR CANCELLED`, exit 2, nothing sent.

**Cancellation.** On a timeout or SIGINT/SIGTERM/SIGHUP, the wrapper SIGTERMs the process group,
waits 6 s (dsh drains for 5 s and exits **0** on SIGTERM), then SIGKILLs it. The run is FAIL
`CANCELLED` regardless of what dsh printed. A signal while the finished run is being checked
cancels it too; one after the verdict is recorded waits until the answer is printed, so the
status file and the output always agree.

## dsh 0.2.1-rc.5 headless, as observed

**Flags.** `dsh --profile headless --help` lists only `--json`, `--session-id <id>` and `-h`.
The task is a positional argument, or `-` for stdin. Permissions come from config rows (and
`DSH_PERMISSION_MODE`), not from flags.

**Install.** `npm ci --ignore-scripts` from the lockfile works: 618 packages, **854 MB**, about
15 s. Five packages declare install scripts:

- `dsh-subprocess-local` (spawn helper);
- `koffi`, `node-pty` (native);
- `protobufjs`;
- `@google/genai`.

dsh, `glob`, `grep` (bundled `@vscode/ripgrep`) and `read` all work with the scripts skipped.

**Start-up.** `--version` and `--dump-config` take about 1 s each, offline.

**NDJSON stream (`--json`):**

```
{"type":"session","sessionId":"session-…","cwd":"/abs/cwd"}
{"type":"status","phase":"turn_start","turn":1}
{"type":"status","phase":"step_start","turn":1,"step":1}
{"type":"thinking","text":"…"}
{"type":"tool_call","callId":"toolu_1","tool":"read","input":{"file_path":"/abs/path"}}
{"type":"tool_result","callId":"toolu_1","status":"completed","result":"<path>…</path>\n<type>file</type>\n<content>\n1: …"}
{"type":"status","phase":"step_end","turn":1,"step":1,"usage":{"inputTokens":11,"outputTokens":42,"cacheReadTokens":3,"totalTokens":56}}
{"type":"text","text":"…"}
{"type":"status","phase":"turn_end","turn":1,"reason":{"kind":"completed"}}
{"type":"final","text":"…"}
```

**Where the outcome is:**

- The turn outcome is on `status`/`turn_end` `.reason.kind`; `final` has no reason in rc.5.
- A provider `max_tokens` stop gives `"kind":"max-tokens"`, the partial text in `final`, and
  exit 1.
- A provider `refusal` gives
  `"kind":"error","error":{"code":"MALFORMED_RESPONSE","message":"…unsupported stop reason refusal"}`,
  an empty `final`, and exit 1.
- A usage error is a single `{"type":"error","message":"…"}` line.
- A fenced read is a `tool_result` with `"status":"error"` and `"result":"Error: EPERM: …"`.

**stderr:**

- `dsh: failed to load .env: Error: EPERM…`: harmless, the fence did its job.
- `dsh: failed to read overlay <file>: Error: EPERM…`: the fence does not allow that `--patch`
  file. dsh exits 1 before any request. The wrapper's fence allows exactly `<out>/review.patch.yml`
  and `<out>/run-N.patch.yml`, and `--doctor` checks it (`overlay: composes cleanly under the
fence`).
- `DSH_VERSION_MISMATCH … node has N hard links`: macOS can hand dyld any name of a hard-linked
  file, so `@loader_path/../lib` may resolve outside the fence. Use a node binary with one link.
- `DSH_VERSION_MISMATCH … timed out after Ns`: `dsh --version` did not answer in time; its
  process group was killed.
- `dsh: warning: 1 entry did not activate`, or `dsh: [<patch>] patch: entry "<id>" not found`:
  the composition is not what the overlay says. The wrapper fails the run.

**What the request looks like** (captured by the mock):

- `POST /v1/messages`, streaming, with `model`, `max_tokens: 393216`,
  `thinking: {type: enabled}` and `output_config: {effort: high}`;
- tools exactly `glob`, `grep`, `read`, `todo_write`;
- no `dsh_*` field;
- headers: `x-api-key`, `anthropic-version: 2023-06-01`, `x-deepseek-harness-user-id`,
  `x-deepseek-harness-session-id`, `user-agent: deepseek-harness/0.2.1-rc.5`;
- the system prompt is a 482-char tool guide;
- the first user message carries the prompt plus a runtime-context block (absolute cwd, "file
  policy: read-only", "approval prompts are disabled").

## DeepSeek API (api-docs.deepseek.com, read 2026-10-31)

**Models:**

- `deepseek-v4-pro` (DeepSeek-V4-Pro-0813, text only);
- `deepseek-flash` (DeepSeek-V4.1-Flash-1017, takes images). The legacy names
  `deepseek-v4-flash*` are served by V4.1-Flash.

Context is 1M tokens for both.

**`max_tokens`.** Range 1–393216. API defaults: 8K without thinking, 64K with thinking, 128K at
effort `max`.

**Effort.** `none|low|high|max`, default `high`. Unknown values are mapped, not rejected:
`minimal`→low, `medium`→high, `xhigh`→high, `ultra`→max. Hence the wrapper's strict
`low|high|max`.

**Anthropic format.** `thinking.type enabled|disabled` (`budget_tokens` ignored),
`output_config.effort`; `cache_control` is ignored. A named `tool_choice` returns a 400 in
thinking mode.

**Concurrency.** 500 for v4-pro and 2500 for flash, per account. Above that: HTTP 429. Under
load the server sends keep-alive lines, and it closes a request that has not started inference
within 10 minutes.

**Pricing, USD per 1M tokens:**

| Model                       | Cache hit | Input (miss) | Output |
| --------------------------- | --------- | ------------ | ------ |
| `deepseek-v4-pro`, peak     | 0.044     | 1.32         | 3.96   |
| `deepseek-v4-pro`, off-peak | 0.022     | 0.66         | 1.98   |
| `deepseek-flash`, peak      | 0.006     | 0.30         | 1.20   |
| `deepseek-flash`, off-peak  | 0.003     | 0.15         | 0.60   |

Peak hours are 01:00–04:00 and 06:00–10:00 UTC, Mon–Fri, excluding Chinese public holidays. In
Vietnam (UTC+7) that is 08:00–11:00 and 13:00–17:00. Prices change; re-read the pricing page
before quoting a bill.

**Data.** Processed and stored in the PRC. The privacy policy lists training among its purposes,
and no API retention period is published.

## Live probe

**Run 1: 2026-11-01, 18:00 UTC (Sunday, off-peak), `deepseek-v4-pro` at `high`** (the default
until 2026-11-02, `max_tokens` 393216). One run through `opgate exec`. The repo was a throwaway one holding a
14-line Python file with a planted off-by-one, run with `--expect-read` on that file.

- **Verdict:** PASS. The reviewer read `src/window.py` (one `read` call, relative path), found
  the planted bug with two correct counter-examples, and ended with the nonce line
  (`VERDICT-…: FINDINGS`). `turn_end` was `completed`, dsh exited 0, and stderr held only the
  `/models` listing line.
- **Time:** dsh ran for 16.1 s (`wall_seconds`). From the dsh launch, the `session` event came
  at about 1.9 s (boot plus the `/models` call), and the first step (thinking plus the `read`
  call) ended about 1.7 s later. The second step, 1370 output tokens, took about 12.5 s, roughly
  110 tokens/s. The NDJSON carries one block per step, not token deltas, so there is no
  streaming time-to-first-token to measure. The fenced `--version` check took 0.12–0.16 s
  (3 warm runs, measured afterwards). Touch ID approval at `opgate exec` comes on top.
- **Tokens:** 2 steps. Step 1: 1372 input, 0 cached, 47 output. Step 2: 251 input, 1408 cached,
  1370 output. dsh's `inputTokens` counts cache misses only, and `cacheReadTokens` the hits. The
  summed `usage` in `status-1.json` was 1623 in, 1408 cached, 1417 out.
- **Reasoning:** counted inside `outputTokens`. The stream's `thinking` blocks were 3562
  characters, against 590 for the answer, and no separate reasoning count is reported.
- **Budget used:** about 0.4% of `max_tokens`. Whether reasoning counts against it is settled by
  run 3 below.
- **Served model:** the stream does not name it. Attribution comes from the request config
  (`run-1.patch.yml`) and the `model:` line the wrapper prints.
- **Cost:** about $0.004 off-peak: 1623 × $0.66/M + 1408 × $0.022/M + 1417 × $1.98/M. That is
  about $0.008 at peak prices.
- **Tools used:** only `read`.

**Runs 2 and 3: 2026-11-01, 18:13 UTC (off-peak), `deepseek-flash` at `max`** (the default since
2026-11-02). One `opgate exec`, the same repo and prompt.

- **Run 2 (defaults):** PASS in 12.4 s over 3 steps:
  - step 1 read `src/window.py`;
  - step 2 ran `glob` (`**/*.py`) and `grep` (`last_n|count_recent`), both `completed` under the
    wrapper's fence (`grep` is the ripgrep bundled with dsh);
  - step 3 answered.

  It found the planted bug with three correct counter-examples, one of them for `len < n`
  (V4-Pro had stated that case only in general terms). Usage: 1813 in, 3712 cached, 1787 out, with 2053 + 1646
  characters of thinking. Cost about $0.0014 off-peak (about $0.003 at peak).

- **Run 3 (`--max-tokens 300`):** FAIL, as it should. Step 2 spent exactly 300 output tokens, all
  of them thinking (883 characters, no text). The turn ended `max-tokens` and dsh exited 1. The
  wrapper printed `FAIL DSH_EXIT_NONZERO`, `TURN_NOT_COMPLETED` (`'max-tokens'`) and
  `VERDICT_MISSING`, with nothing on stdout. **So reasoning counts against `max_tokens`**, which is
  why the default is the API maximum. Cost about $0.0003.
