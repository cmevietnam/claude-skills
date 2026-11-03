# Safety model

dsh is a general coding agent. Its defaults suit a person driving it in their own project. They
do not suit an unattended reviewer reading material someone else wrote, where a prompt injection
in a diff is a realistic input. This page lists what dsh 0.2.1-rc.5 does by default, what
`deepseek-review` changes, how each change is enforced, and what remains open.

Each "source" is the dsh documentation or composed config as read on 2026-10-31/11-01. The
behaviour column was verified with the pinned rc.5 against a loopback mock unless marked otherwise.

## dsh defaults and the countermeasures

| dsh default (source)                                                                                                                                                         | Risk                                                                                | What the wrapper does                                                                                                                                                      | Enforced by                                                  |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `fs-local`: "absolute paths and parent traversal remain unrestricted"; `SandboxMode` "governs filesystem effects only" and `read-only` "asks the backend to deny writes"     | The model reads `~/.ssh`, `~/.aws` or another repo, and the content goes to the API | Seatbelt read allowlist (below)                                                                                                                                            | macOS kernel (`sandbox-exec`)                                |
| `sandbox-policy.mode` defaults to `workspace-write`; `tool-fs` registers `write`/`edit`                                                                                      | The reviewer edits the repo                                                         | `sandbox-policy.mode: read-only`, `approval.policy: never`, `tool-fs` write/edit/applyPatch off, `DSH_PERMISSION_MODE=read-only`, Seatbelt `(deny file-write*)`            | Overlay + kernel                                             |
| `tool-bash`, `tool-jobs`, subagents (spawn, fork), PTC (`run_code`), MCP, skills, goals, plan mode, `working_directory` are mounted                                          | Code execution and exfiltration                                                     | Rows disabled; observed tool list: `glob`, `grep`, `read`, `todo_write`                                                                                                    | Overlay; checked by the mock-wire test                       |
| `web_fetch` "runs in every sandbox and approval mode without per-call confirmation and can reach loopback and private-network hosts"; `web_search` is billed from 2026-11-01 | SSRF, exfiltration, cost                                                            | `web`, `web-search-deepseek`, `web-deepseek-api`, `web-fetch-http`, `tool-web` disabled                                                                                    | Overlay                                                      |
| `session-log-deepseek` "Shipped profiles mount the plugin"; `enabled` defaults to `true` and uploads the canonical Session log in `dsh_session_log` with each request        | A second, structured copy of the whole session goes to DeepSeek                     | Row disabled                                                                                                                                                               | Overlay; the mock-wire test asserts no `dsh_*` request field |
| `plugin-package-inventory-deepseek` adds `dsh_plugin_packages` to requests                                                                                                   | Installation diagnostics leave the machine                                          | Row disabled                                                                                                                                                               | Overlay; same assertion                                      |
| OTel session telemetry to `dsh-otel-collector.deepseeksvc.com` (feedback-gated)                                                                                              | Telemetry leaves the machine                                                        | `otel` and `session-telemetry-otel` disabled, `DSH_TELEMETRY_DISABLED=1`                                                                                                   | Overlay + env                                                |
| `session-title-first-prompt-llm` makes an extra model call with the first 4 KB of the prompt                                                                                 | Extra request, extra cost                                                           | Row disabled                                                                                                                                                               | Overlay                                                      |
| `agent-instructions` loads the repo's `AGENTS.md`/`CLAUDE.md` (64 KB budget)                                                                                                 | Claude-directed instructions steer the reviewer                                     | Row disabled                                                                                                                                                               | Overlay                                                      |
| Credentials: inherited env, then `<cwd>/.env`, then `$DSH_HOME/.env`; `$DEEPSEEK_BASE_URL` overrides the endpoint                                                            | A repo `.env` or an inherited variable points the key at another origin             | Child env is an allowlist; `baseURL` pinned in `run-N.patch.yml`; Seatbelt denies `.env*` in the repo (dsh then logs `failed to load .env: EPERM` and continues, verified) | Wrapper + kernel                                             |
| `llm-pi-ai` and `llm-deepseek-account` routes are mounted                                                                                                                    | Other providers or the account route are reachable                                  | Rows disabled                                                                                                                                                              | Overlay                                                      |
| Sessions persist under `~/.dsh`, with an anonymous user id in `~/.dsh/.anonymous-user-id`                                                                                    | Transcripts pile up; one id links every run                                         | `HOME=DSH_HOME=<out>/home`: sessions stay in the run's private out dir, and each run gets a fresh id                                                                       | Wrapper                                                      |
| A patch row id that does not exist only warns (`patch: entry "<id>" not found`) and dsh runs anyway                                                                          | An upgrade silently drops a hardening row                                           | Any such warning, or `entry did not activate`, fails the run (`COMPOSE_WARNING`)                                                                                           | Wrapper                                                      |

## What the caller's environment cannot choose

The wrapper runs before any fence, with the key in its env, so nothing the caller inherited may
pick the code it runs:

- **The interpreter.** The shebang is `#!/usr/bin/env -S -u DEVELOPER_DIR /usr/bin/python3 -I`:
  a fixed path, isolated mode (no `PYTHONPATH`, no user site, no script or cwd dir on
  `sys.path`), and no `DEVELOPER_DIR`. `/usr/bin/python3`, `/usr/bin/git` and `/usr/bin/otool`
  are xcrun shims that run the tool from `$DEVELOPER_DIR` when it is set (verified 2026-11-02 on
  this macOS; `SDKROOT`, and `TOOLCHAINS` given as a path, did not redirect them).
- **git** (the repo check) is always `/usr/bin/git`, with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`
  and `HOME=<the account's home>` only: no key, no `GIT_*`, no `DEVELOPER_DIR`. `otool` (node's
  dylib scan) gets the fixed `PATH` only.
- **The home.** Every home-based refusal (repo scope, out dir, the unsafe-dir rule below) applies
  to realpath(`$HOME`) and to the account's home from the password database, so a spoofed `HOME`
  cannot move the refusals away from the real one. The default dsh dir is under the account's
  home too: `HOME=<a checkout>` cannot make the wrapper run a dsh planted in that checkout.
- **node.** A node found through PATH is used only when its realpath is under Homebrew's prefix
  (`/opt/homebrew`, `/usr/local`) or a version manager's dir in the account's home
  (`~/.nvm/versions`, `~/.volta`, `~/.asdf/installs`); anywhere else is `NODE_UNTRUSTED`, and a
  node elsewhere is used only when named with `--node`. Each root counts where it resolves (a
  symlinked `~/.nvm` works), and a root that resolves to `/` or to a home is dropped. A PATH entry
  the caller does not control therefore cannot hand the wrapper a node that receives the key.
- **npm** (`--install` only) is the one beside node, never one from PATH, and gets
  `PATH=<node's dir>:/usr/bin:/bin:/usr/sbin:/sbin`, the account's `HOME` and `LANG` only.
  `--install` checks the dsh dir before it writes anything: never an unsafe dir, never an existing
  dir holding anything but a dsh install's files.
- **The prompt file** is refused (`PROMPT_UNSAFE`) when it is a symlink; when its path goes
  through a symlink not owned by root (`R/prompts/.netrc` with `R/prompts -> ~`, or
  `R/jump/../.ssh/id_ed25519`; root's `/tmp` and `/var` are fine); or when the file the kernel
  opened (`F_GETPATH` on the open file) is in a home's secret dir, is a dotfile directly in a home
  (`~/.netrc`), or has a name matching the `.env` pattern below. A checkout's
  `review.txt -> ~/.ssh/id_ed25519` is refused, not sent.
- **`..` after a symlink.** Every path is resolved the way the kernel opens it: `R/jump/..` is
  the dir above where `jump` leads, never `R`. A check of the text `R` would pass a path the
  kernel resolves elsewhere.
- **`--continue`** re-runs every repo scope check on the repo `status-1.json` recorded and
  requires the same realpath (a repo swapped for a symlink to `~/.ssh` is refused), checks that
  the dsh dir it is given does not overlap the out dir, and keeps every `--expect-read` file any
  earlier attempt recorded.
- **The key on disk.** dsh writes its stdout and stderr straight to files, and keeps sessions and
  startup diagnostics (which can hold credential values) in its home. After dsh exits, on every
  outcome, the wrapper replaces the key with `[REDACTED]` in every regular file under the out
  dir, never following a symlink, and `--continue` does it again before it starts dsh. The key
  may hold only letters, digits, `.`, `_` and `-` (`KEY_INVALID` otherwise), so it has no escaped
  spelling the scrub could miss.

**Unsafe dirs.** The fence never allows whole a dir that is: a broad system prefix (`/`, `/usr`,
`/usr/local`, `/opt`, `/opt/homebrew`, `/Users`, `/private`, …); a home or a dir above one; a
direct child of a home (`~/.local`, `~/Documents`); or a dir that overlaps one of a home's secret
dirs (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config`, `~/.dsh`, `~/.claude`, `~/.codex`,
`~/.gemini`, `~/.kimi-code`, `~/Library`). The one exemption: node's own bin dir and
`<prefix>/lib` may be direct children of a home (node at `~/bin/node` gets `~/bin` and `~/lib`,
never `~`).

**Letter case.** realpath keeps the caller's spelling (`/USERS/ME/bin/node` stays so), while
Seatbelt applies a rule, `subpath` and `regex` alike, to the real dir whatever its case (verified
2026-11-02: an allow on `.../CASEPROBE/SECRET` let `cat .../caseprobe/Secret/file` through, and a
`.env` regex built from an upper-cased repo path still denied `.env`). Two layers deal with it:

- every path the wrapper resolves that exists is respelled as the volume stores it (`F_GETPATH`;
  only the case and Unicode form may change), so the repo it records matches the cwd dsh reports
  and the fence names the stored dirs;
- every check that refuses on a match (the unsafe-dir rule, the repo scope, the out-dir and node
  scope, the dsh-repo overlap, the prompt file) also compares paths folded for letter case and
  Unicode normalization, as APFS does, which covers a path that does not exist yet (the out dir)
  and one the wrapper cannot open to respell (a dir without read permission). A repo the wrapper
  cannot list is refused (`REPO_UNREADABLE`): its spelling cannot be checked, and the reviewer
  could not list it either.

The checks where a match allows (an `--expect-read` file inside the repo, dsh's symlinks inside its
dir, the reads counted for `--repo`, the repo a `--continue` recorded) compare the stored
spellings exactly.

- A dsh dir that is unsafe, or whose `bin.js` or any other symlink in it resolves outside it, is
  refused (`DSH_DIR_UNSAFE`): dsh imports its other packages through `node_modules`, so one
  symlinked package would run code from elsewhere. The walk takes about 0.9 s on the pinned install
  (68,982 entries, 12 symlinks, all inside).
- A node whose dirs can be allowed only by opening an unsafe dir is refused (`NODE_DIR_UNSAFE`).
  fnm on macOS keeps node under `~/Library/Application Support/fnm`, which overlaps `~/Library`:
  pass `--node` with a node installed elsewhere (Homebrew and nvm work).

## The Seatbelt fence

Each attempt gets a generated profile, `fence-N.sb`, and dsh runs under
`/usr/bin/sandbox-exec -f fence-N.sb`. Paths are escaped in code. The repo path is
regex-escaped for the `.env` rule.

- `(deny file-read*)`, then `file-read*` allowed only on:
  - `/System/Library`, `/usr/lib`, `/usr/share`, the dyld cache dirs and the literal `/`;
  - single files: `/private/etc/ssl/cert.pem`, `resolv.conf`, `hosts`, `localtime`, and a few
    `/dev` nodes;
  - node's prefix (its Cellar dir under Homebrew), or only its bin dir and `<prefix>/lib` when
    the prefix is an unsafe dir; each dylib dir `otool -L` lists for it; and Homebrew's
    `etc/openssl@3` plus its CA dir (node aborts at startup without the OpenSSL config). No
    unsafe dir is ever added;
  - the dsh install dir;
  - the repo (or `<out>/work`, the cwd of a run without `--repo`);
  - `<out>/home` and `<out>/tmp`;
  - two single files at the top of `<out>`: `review.patch.yml` and this attempt's
    `run-N.patch.yml`, the overlays dsh reads at startup. Nothing else there is readable: not
    the prompts, the streams, the status files or another attempt's patch.
- `file-read-metadata` is allowed everywhere, so that realpath and stat work.
- Under the repo, at any depth, names that start with `.env` (`.env`, `.envrc`, `.env-prod`,
  `.environment`) or end in `.env` (`prod.env`) are denied, and so is everything under a dir so
  named (`.env.d/credentials`, `.env/prod`). Seatbelt matches them case-insensitively on APFS, so
  `.ENV` is denied too; `x.env.example` and `environment.md` stay readable. Seatbelt matches the resolved path: a `.env` that is a symlink to another repo file is
  readable, as that file is under its own name, and one pointing outside the repo is denied like
  any outside file.
- `(deny file-write*)`, except `<out>/home`, `<out>/tmp` and a few `/dev` nodes.

Verified with the pinned rc.5, first under a probe fence in the feasibility step, then under
the wrapper's own `fence-N.sb`: by the test suite (`--doctor`'s fenced `--dump-config`, and a full
headless turn with the `read` tool against a loopback mock), and by the live probes of
2026-11-01, where `read`, `glob` and `grep` all completed (`cli-reference.md`, Live probe):

- repo reads, `glob` and `grep` work; `grep` uses the ripgrep bundled in the package, run as a
  child process that inherits the sandbox;
- reads of `~/.zshrc`, `/Users/Shared`, `/private/etc/ssh/ssh_config`, a file next to the run
  dir and the repo `.env` return `EPERM`, which the model sees as
  `tool_result status: "error"`;
- a write into the repo returns `EPERM`;
- TLS to `api.deepseek.com` works.

## What none of this covers

- **The network is open.** Seatbelt cannot filter by host name. With every network tool
  disabled, the remaining outbound channel is the model request itself, which by design
  already carries the material.
- **Everything readable inside the repo can be sent**, untracked files included, except the
  `.env`-like names above. Do not use `--repo` on a tree that holds secrets in other files.
- **The cwd is visible to DeepSeek.** dsh adds a runtime-context block with the absolute
  working directory, so the local user name and path layout are visible.
- **Request metadata:** DeepSeek receives
  `x-deepseek-harness-user-id` (fresh per run), `x-deepseek-harness-session-id` and a
  `deepseek-harness/0.2.1-rc.5` user agent.
- **The key reaches DeepSeek twice per run.** On the official endpoint the API-key route
  calls `GET https://api.deepseek.com/models` with the key, besides the model requests. It is
  the same origin.
- **This is cooperative on the caller's side.** Anything that can run commands as the user
  can run dsh, or `curl`, without the wrapper. The fence binds the reviewer, not the person
  or agent invoking it.
- **The prompt text is on disk** in `<out>/prompt-N.txt` (mode 0600, in a 0700 dir).
- **A wrapper killed with SIGKILL cannot scrub.** If dsh printed the key before that, the copy
  stays in the out dir until a `--continue` on it, or until the dir is deleted.
