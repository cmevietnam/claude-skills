# Secrets when working with Linode

Everything printed to the terminal goes into the conversation transcript and up to
the model provider. A credential that lands there counts as leaked and must be
rotated. Linode has four places to trip, and each has a right way.

The `onepassword` skill (the `opgate` command) is where secrets are fetched from
and stored. `opgate list` shows which variables the project already has.

## 1. Root password when creating or rebuilding a Linode

Never write the value literally: it lands in the transcript, in shell history, and
in the process table at once. The hook refuses that form outright.

```bash
opgate exec ROOT_PASS=op://Dev/cme/LINODE_ROOT_PASS -- \
  linode-cli linodes create --tags cme --tags staging \
    --label cme-web-1 --root_pass "$ROOT_PASS"
```

If the vault has no value yet, add the line
`LINODE_ROOT_PASS=op://Dev/cme/LINODE_ROOT_PASS` to `.env.op`, then have the user
run `opgate put cme LINODE_ROOT_PASS`. Do not ask for the password in chat — the
answer would sit in the transcript.

## 2. LKE kubeconfig

`lke kubeconfig-view` returns a base64 kubeconfig, i.e. full credentials for the
cluster. Send it straight to a file; never let it reach stdout:

```bash
linode-cli lke kubeconfig-view 580172 --json \
  | jq -r '.[0].kubeconfig' | base64 -d > ~/.kube/cme-prod.yaml
chmod 600 ~/.kube/cme-prod.yaml
```

The hook asks when the command's stdout does **not** end in a file or in `opgate`
at the end of the pipeline. `2>/dev/null` does not count (that is stderr), and
neither does `| base64 -d` — the command after the pipe still prints.

## 3. Credentials that Linode generates

`object-storage keys-create`, `databases *-creds-view`, `*-creds-reset` all return
values that work immediately. Store them in 1Password in the same pipeline; do not
copy by hand:

```bash
linode-cli object-storage keys-create --label cme --json \
  | jq -r .secret_key | opgate put cme LINODE_OBJ_SECRET
```

`object-storage keys-create` is the one create allowed to be piped: the id and the
secret arrive together, and forcing the id onto stdout for the recording hook would
force the secret into the transcript too. In exchange, the id is **not** recorded
automatically — record it by hand right after:

```bash
linode-cli object-storage keys-list --json | jq -r '.[] | "\(.id)\t\(.label)"'
lingate own object-storage <id> --env staging
```

Every other create of a ledger type (VPC, database, placement group…) is
**refused** when its stdout is piped or redirected, or when it shares a Bash call
with another `linode-cli` invocation — the recording hook reads the id from the
whole call's stdout and would record the wrong one. Run them **alone**, bare, with
`--json`.

To check that a value is present, compare inside a child process; do not print it:

```bash
opgate run -- sh -c '[ -n "$LINODE_OBJ_SECRET" ] && echo present'
```

## 4. linode-cli's own token

`LINODE_CLI_TOKEN` lives in `~/.config/linode-cli`. Do not `cat` that file, do not
`echo $LINODE_CLI_TOKEN`, and do not pass `--debug` to anything (it prints the
`Authorization` header). To change the token, let the user run
`linode-cli configure` — the hook only asks there, it never allows on its own.

To check the token still works without exposing anything:

```bash
lingate doctor
```

## If something leaked

Treat it as leaked for real, even if it showed once:

- root password → `linode-cli linodes disk-reset-password …`
- object storage key → `object-storage keys-delete`, then create a new key
- database credential → `databases <engine>-creds-reset <id>`
- API token → revoke under `profile tokens-list` / recreate with `linode-cli configure`

Then put the new value into 1Password with `opgate put`.
