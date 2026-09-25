# Turning findings into tests

## Principle

A green test suite proves only what it checks. The size of the suite says nothing;
coverage of the **failure mode** is what counts.

Mandatory order: **write the test first, watch it fail, then fix.** Fix first and write
the test afterwards, and all you prove is that the current code does what the current
code does.

## Why the reviewer's input is the best source

You write tests from the shapes you thought of while writing the code, which is exactly
the set that missed the bug. A reviewer thinks of different shapes. Its attack input is
the one thing you have that is guaranteed to lie outside your own imagination.

In the run that produced this skill, 38 secret-classification tests were green while
`DB_PASS=hunter2` was classified as "config" and written straight into a file the docs
said was safe to commit, because every test used values the author had already thought
of. The reviewer came up with `hunter2` in three seconds.

## How

For each finding that reproduced:

1. Add a case with **exactly the input the reviewer gave**, not a tidied-up version.
2. Run it: it must fail. If it passes, you have not understood the bug.
3. Fix.
4. Run again: it must pass, and **every earlier case must still pass**.

Put these cases in a group labelled by review round, so that a later reader knows where
they came from:

```bash
echo "ROUND 3: wildcard allowlist removed — only exact name matches become config"
t PUBLIC_PASSCODE     '1234'   secret
t NEXT_PUBLIC_PINCODE '1234'   secret
```

## Run tests in the production environment

A test that runs under a different shell from the real thing is testing a different
program. With bash specifically, a function that works under test but dies under
`set -euo pipefail` is common: a `grep` with no match returns 1, and under `set -e` that
kills the whole function. In the run above, exactly that bug made a scanner silently try
only one pattern out of eleven, and the tests stayed green because they did not enable
`set -e`.

Watch the version too: macOS ships bash 3.2, which has no `${v,,}` and no associative
arrays. Test under `/bin/bash`, not Homebrew's bash 5.

## Three classes of bug that slip past self-written tests

Each deserves its own case, because they are all of the "runs fine, does the wrong
thing" kind:

**The last element is dropped.** `printf '%s'` without a trailing newline makes a
`while read` loop skip the last token, and the last token is often the one that matters
most (a filename, the final variable). Always have a case that puts the thing to catch in
the **last** position.

**An empty field shifts the columns.** Tab is an IFS whitespace character, so `read`
merges two adjacent tabs: one empty field in the middle shifts every later field to the
left. Use a placeholder character (`-`) for empty fields, and test the number of records
parsed.

**Environment variables change a tool's behaviour.** `GREP_OPTIONS`, `LC_ALL`, `IFS` and
`PATH` can each turn a correct pipeline into a wrong one. If the code depends on a tool's
output format, force the flag explicitly (`grep -H`) **and** test under a hostile
environment.
