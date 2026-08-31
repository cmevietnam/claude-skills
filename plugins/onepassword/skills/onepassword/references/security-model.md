# Security model — what is protected, and what is not

Read the "what is not" part first. A security mechanism you have misunderstood is
worse than none at all, because it manufactures confidence with nothing under it.

## The accurate claim about this tool

`opgate` is a **cooperative control** plus a layer of **accident prevention**. It
binds whoever calls it. It is **not** a sandbox and it **cannot** constrain a
process that deliberately goes around it.

That is inherent, not a weak implementation: 1Password authorizes `op` per
**terminal session**, for about ten minutes, renewed on each use, and that
authorization is inherited by every child process. Anything that can run a command
as you can call `/opt/homebrew/bin/op` directly and skip this tool entirely. Real
enforcement would need a broker the agent cannot reconfigure, replace or route
around, in an environment where the agent cannot see `op` at all — that is a
different architecture, not a patch.

So the accurate claim is: **every time `opgate` reads from or writes to the vault, it
asks for your Touch ID.** Not "every secret access on this machine requires Touch ID".

What deliberately does not go through the gate, and why:

- `scan` and `import --dry-run` read plaintext `.env` files on disk. The file is
  already sitting there and `cat` can read it; the gate adds nothing. Neither prints
  a value.
- `scan`, `items` and `doctor` read vault **metadata** (item titles, category, tags)
  via `op item list`. No field values are in that.
- `import` and `put` also read metadata **before** asking for a fingerprint, so they
  can refuse early (an item that is not opgate's, two files deriving one item name).
  `import` reads one extra field, `opgate_source` — a path. The reason: refusing
  _after_ you have touched the sensor wastes the one thing this design spends
  sparingly. An item's actual secret values are only read **after** approval.

A reviewer correctly pointed out that an earlier version read the **whole** item —
every concealed value — into shell variables before you had a chance to say no. Not
any more.

## The two problems being solved

Two different problems, usually conflated:

1. **Secrets sitting plaintext on disk.** Any process, any agent that can read the
   file gets them. Solved by moving them into 1Password.
2. **Secrets reaching the model's context.** This one is new; a traditional `.env`
   did not have it. When an agent runs `cat .env` or `op read`, the value enters the
   transcript and is shipped to the model provider, where it may be retained. Solved
   by never letting a secret travel through the agent's stdout.

Problem 2 is why `opgate` has no `read` command, and why `op run` — which masks its
own output — is the primary primitive rather than `op read`.

## The layers

**Layer 1 — the Touch ID gate.** `touchid-gate` uses LocalAuthentication with
`touchIDAuthenticationAllowableReuseDuration = 0`, so macOS does not reuse a recent
unlock and the sheet appears every time. No TTL, no cache, no environment variable
that turns it off. The path to the binary is pinned at
`~/.local/share/opgate/bin/` — `XDG_DATA_HOME` is deliberately not honoured, because
otherwise anyone who can set an environment variable could point it at a fake gate
that exits 0.

**Layer 2 — masking.** `op run` replaces secret values with
`<concealed by 1Password>` in the child process's stdout and stderr. `--no-masking`
is never used.

**Layer 3 — the hooks.** Block direct `op read` calls, and ask before a plaintext
secret file is opened. Accident prevention, not a sandbox. One approval opens a
**60-minute window for that one file** — see "Approval windows" below.

**Layer 4 — the audit log.** `~/.local/state/opgate/access.log`, chmod 600. It holds
variable names and references only, never values. It is neither signed nor
tamper-proof, and `OPGATE_CALLER` is set by the caller, so the caller field is a hint
rather than an authenticated identity.

## Known ways around it

Listed here rather than left for you to discover later.

**Not fixable at this layer:**

- **Calling `op` directly.** Once the 1Password session is authorized,
  `op read op://…` works without touching the gate. The hook covers this path in
  Claude Code; Codex has no hook system, so nothing covers it there.
- **The child command is arbitrary code.** After you approve, `opgate run -- npm run
dev` hands the secrets to a process whose `package.json` the agent may have just
  edited. The sheet says "npm run dev", not what will actually run. **Read the
  command on the sheet**, and remember that approving a command means trusting it.
- **`PATH` is trusted.** A fake `pbcopy` receives whatever `opgate copy` sends.
- **Secrets in a child's environment are visible** to other processes running as the
  same user. That is inherent to `op run`, and
  [1Password says so plainly](https://www.1password.dev/cli/secrets-environment-variables).
  Not a flaw in `opgate`, but you should know.
- **Literal values in `.env.op`** are not secrets resolved by 1Password, so `op run`
  does not mask them. `opgate list`, `run` and `doctor` all warn about them.
- **`op://` variables already in the environment** (`export X=op://…` in a shell
  profile) are resolved by `op run` on _every_ invocation. `run` and `exec` list them
  on the sheet but do not block them — they are yours.
- **`op run`'s masking is exact string matching.** `env | base64` inside the child
  command carries the secret out in an encoding the masking does not recognise. That
  is a 1Password limitation, and it is why "read the command on the sheet" is not
  empty advice.
- **A Grep across a whole directory** reads any `.env` inside it without the hook
  asking. The Grep hook only fires when Grep points straight at a secret file;
  asking on every directory-wide Grep would be too noisy for anyone to keep reading.

**The hook's tokenizer** matches tokens without understanding context: `git commit -m
"docs: op read"` is blocked by mistake because the two tokens sit next to each other.
The window is 6 tokens after `op`, so prose mentioning `op` and `read` further apart
gets through. Accepted.

**Patched, but only a speed bump:**

- **Replacing the gate binary.** It lives in a directory you own, so anything running
  as you can overwrite it. `opgate build` records its sha256 and the gate checks it
  before running, writing a `TAMPER` record to the audit log and exiting 78 on a
  mismatch. This is **tamper evidence, not tamper proofing** — whoever can write the
  binary can write the hash file too. Its value is turning a one-environment-variable
  move into a deliberate act that leaves a trace.

**Removed outright:**

- `OPGATE_GATE=none` and the `sudo` fallback — both disabled layer 1 through an
  environment variable, which is precisely the thing being guarded against. `sudo`
  was worse: under a `NOPASSWD` configuration, `sudo -v` succeeds silently, asking
  nothing.
- `OPGATE_TTL` — the marker was a predictable file in a writable directory, so
  creating one yourself skipped the prompt. The marker key did not include the
  command or the reference either, so approving one `exec` opened every other `exec`
  in the same directory. The **layer 3** approval window reuses that idea at a very
  different layer — read "Approval windows" before concluding they are the same thing.

## Approval windows — layer 3 only

The guards used to answer "ask" every single time the agent reached for a plaintext
secret file. Answering the same prompt about the same `.env` thirty times in one
session is how you stop reading prompts, so an approval now opens a **60-minute
window for that one file**. Inside the window the guard answers "allow"; outside it,
nothing changes.

How a window opens, and why neither path is somewhere an agent can quietly stand:

- **You approved a prompt.** The PreToolUse guard writes the key it would grant into
  `pending/<call-id>`; the PostToolUse hook promotes it. Claude Code does not run
  PostToolUse for a call that was denied or cancelled, so a promotion is your yes and
  nothing else. The Post hook does no classification of its own — it only promotes
  what the guard already decided, so the two hooks cannot drift apart about what
  counts as a secret file.
- **`opgate unlock --minutes N <path>…`**, which is Touch ID gated even though it
  moves no secret value. That is what makes a window traceable: every one opened
  legitimately has a `GRANT` record in `opgate audit`.

Deliberate limits:

- **Per file, by resolved path.** Approving `.env` does not open `.env.production`,
  and a command that touches two secret files needs both windows open.
- **Never over a `deny`.** A window makes a plaintext file quieter. It has no effect
  on the branch that blocks direct `op` calls, which stays denied.
- **The auto-remember length is a constant, not an environment variable.** A knob
  that widens a security window is a knob the guarded thing can turn. `unlock` may
  ask for longer (up to 8h) because that number appears on the Touch ID sheet before
  it takes effect.
- **Modes where nothing was asked record nothing.** Under `bypassPermissions`,
  `dontAsk` or `auto` no prompt is shown, so the tool running proves nothing. The
  check is an allowlist (`default`, `plan`, `acceptEdits`), so an unrecognised future
  mode also records nothing.
- **Unparsable is not approved.** A grant file with the wrong version, a non-numeric
  expiry, or a path that does not match the file being opened is treated as no grant.

### Why this is a different trade from `OPGATE_TTL`

`OPGATE_TTL` cached **layer 1** — the Touch ID gate on the vault itself. Forging its
marker file bought you real secret values without a fingerprint, and the key did not
include the command, so approving one `exec` opened every `exec` in the directory. It
deserved to be removed.

A layer-3 window caches the answer to "may I open a file that is already sitting
plaintext on your disk". Layer 3 is explicitly the accident-preventer, not the
sandbox: an agent that _wants_ that file can already reach it with a command the
tokenizer does not recognise, so the window does not lower the ceiling. What it does
raise is the accident surface — for one named file, for one hour, in a session you
were part of.

Forging a grant is still possible; it is a file in a directory you own. The answer is
evidence rather than prevention, the same trade as the gate binary hash: every window
opened writes `GRANT` and every window used writes `GRANT-USED`, so a grant with no
matching record in `opgate audit` is a forgery you can see. `opgate grants` lists what
is open, `opgate lock` closes it, and `opgate doctor` warns about any window it finds.

## What the prompt says, and what it does not

The Touch ID sheet names the project, the `.env.op` file, the list of variables and
the command about to run. It is **not** cryptographically bound to what happens next:
the file is re-read after you approve, so a background process could swap it while
you are deciding. For the threat model here — an agent leaking by accident, not an
active attacker — that is acceptable. Just do not mistake it for a commitment.

`opgate exec` shows the **whole reference**, not only the variable name, because
`DATABASE_URL=op://Prod/admin/root` and a dev reference look identical when you only
see the name.

## Why there is no `opgate read`

This question keeps coming back. The answer: for a command that prints a secret to
stdout, _every_ use of it pushes the value into the transcript. There is no safe way
to use it, so there is no command.

| You want to                           | Use                                                    |
| ------------------------------------- | ------------------------------------------------------ |
| Run a command that needs a secret     | `opgate run -- <cmd>`                                  |
| Paste a secret somewhere by hand      | `opgate copy <ref>`                                    |
| Satisfy a tool that insists on a file | `opgate inject -i tpl -o out` (out must be gitignored) |

If a genuine fourth need turns up, add a purpose-built command that delivers the
secret exactly where it is needed — do not add `read`.

## `inject` — the one operation that leaves plaintext behind

That is what it is for. The guard rails:

- Refuses `/dev/*` and `/proc/*` even with `--force`, because `-o /dev/stdout` turns
  a "write a file" command into writing straight into the transcript.
- Refuses symlinks, FIFOs, sockets and anything that is not a regular file.
- Resolves the path (`..` and symlinked directories) before checking it.
- Requires `git check-ignore` unless `--force`.
- `umask 077` plus `chmod 600`.

What `git check-ignore` does **not** tell you: whether the file is inside a Docker
build context, whether it gets backed up, cloud-synced or indexed, whether someone
will `git add -f` it, and whether `.gitignore` changes later. Delete the file when
you are done with it.

## If you suspect a secret leaked

Rotate it. Nothing else is worth doing first. A value that reached the transcript
cannot be taken back, and `opgate audit` tells you which secrets were touched and
when, so you know what to rotate.
