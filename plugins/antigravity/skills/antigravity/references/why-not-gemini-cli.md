# Why this replaced the Gemini CLI path

Recorded 2026-09-05, so the question does not get re-litigated. If a future user asks to
"use Gemini CLI" for a second opinion, this is what happens.

## What was tried

`@google/gemini-cli` (binary `gemini`), upgraded from 0.22.4 to 0.58.0 for the test.
Sign-in with a personal Google account succeeded every time — the browser flow completed
and `~/.gemini/oauth_creds.json` was written. Every run then died at the tier check:

```
Error authenticating: IneligibleTierError: This client is no longer supported for Gemini
Code Assist for individuals. To continue using Gemini, please migrate to the Antigravity
suite of products: https://antigravity.google
  ineligibleTiers: [{ reasonCode: 'UNSUPPORTED_CLIENT', tierId: 'free-tier',
                      tierName: 'Gemini Code Assist for individuals' }]
```

Four attempts, four identical rejections:

| Attempt                                     | Result                                                                   |
| ------------------------------------------- | ------------------------------------------------------------------------ |
| First sign-in, 0.58.0                       | Auth OK → `IneligibleTierError`, exit 55 (untrusted workspace masked it) |
| Rerun with cached credentials               | Same error, exit 1                                                       |
| Cleared `oauth_creds.json`, signed in again | Same error                                                               |
| Preview build `0.59.0-preview.0`            | Same error                                                               |

## What that means

- **It is not a login problem.** Authentication succeeds; the entitlement check after it
  fails. Re-running the login cannot change an account-level entitlement.
- **A consumer Google AI Pro / Gemini Advanced subscription does not help.** That is a
  different product from Gemini Code Assist, which is what `oauth-personal` authenticates
  against. The account still resolves to `free-tier`.
- **Upgrading the client does not help.** Despite `reasonCode: UNSUPPORTED_CLIENT`, this is
  not version gating — the preview build fails identically. `gemini-cli` _itself_ is the
  unsupported client for that tier.
- **A "fresh" login may silently reuse the same account.** The browser had a live Google
  session, so no account picker appeared. Signing out of Google first is required to
  actually choose a different account.

## The remaining routes, if someone insists

- **`GEMINI_API_KEY`** from [AI Studio](https://aistudio.google.com/apikey) bypasses Code
  Assist entirely and has its own free tier. This is the only way to keep using
  `gemini-cli` on a personal account.
- **Vertex AI** (`GOOGLE_GENAI_USE_VERTEXAI`) needs a GCP project with billing.
- **`GOOGLE_CLOUD_PROJECT`** takes a different branch in `_doSetupUser` — the ineligible
  throw only fires when no project id is set — but that is the Code Assist Standard route
  and needs a project with the Cloud AI Companion API enabled. Not a shortcut.
- **Antigravity**, which is what the error message itself recommends, and what this plugin
  wraps.

## One structural advantage worth keeping in mind

`gemini-cli` had no reasoning-effort control at all; depth came only from the model choice.
`agy` exposes `--effort low|medium|high` and serves Claude and GPT-OSS models alongside
Gemini from the same binary, which makes a genuine two-reviewer diff a one-flag change.

## Findings from that work that still apply

Two hazards were found in `gemini-cli` before it was abandoned. They are recorded here
because the same shapes recur in other agent CLIs:

- **`--approval-mode plan` was less safe headless than the default.** The bundled policy
  auto-allowed `exit_plan_mode` in non-interactive runs and switched the session to YOLO —
  one model-initiated call converting a "read-only" run into full write and shell access.
- **`--help` misdescribed its own interactivity.** It claimed a positional prompt ran
  interactively; the code treated a set positional query, or a non-TTY stdout, as headless.

The lesson carried into this plugin: read the shipped policy files and the code, not the
help text, and never assume the safest-sounding flag is the safest one.
