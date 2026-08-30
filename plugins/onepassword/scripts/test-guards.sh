#!/usr/bin/env bash
# Regression tests for the two PreToolUse guards. No 1Password, no Touch ID, no
# network — these are pure input/output checks on the hook scripts, so they are
# cheap to run after any change to the matching rules.
#
#   bash scripts/test-guards.sh
set -uo pipefail

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pass=0 fail=0

decision() { # <script> <json>
  printf '%s' "$2" | bash "$1" | sed -n 's/.*"permissionDecision":"\([a-z]*\)".*/\1/p'
}

json() { # <key> <value>
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{sys.argv[1]:sys.argv[2]}}))' "$1" "$2"
}

check() { # <script> <key> <input> <expected>
  local got; got=$(decision "$1" "$(json "$2" "$3")"); got=${got:-pass}
  if [[ "$got" == "$4" ]]; then
    pass=$((pass + 1)); printf '  ok   %-44s %s\n' "$3" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-44s got=%s want=%s\n' "$3" "$got" "$4"
  fi
}

bash_guard="$dir/guard-bash.sh"
read_guard="$dir/guard-read.sh"

echo "guard-bash — direct op calls must be denied"
check "$bash_guard" command 'op read op://Dev/app/KEY'            deny
check "$bash_guard" command 'op item get app --vault Dev'         deny
check "$bash_guard" command 'op document get doc'                 deny
check "$bash_guard" command 'op inject -i t -o o'                 deny
check "$bash_guard" command 'op run --env-file .env -- npm start' deny
check "$bash_guard" command 'echo hi && op read op://a/b/c'       deny
check "$bash_guard" command 'bash -c "op item get x"'             deny
check "$bash_guard" command 'sh -c "op read op://a/b/c | pbcopy"' deny

echo "guard-bash — metadata-only op calls and opgate must pass"
check "$bash_guard" command 'op vault list'                       pass
check "$bash_guard" command 'op item list --vault Dev'            pass
check "$bash_guard" command 'op --version'                        pass
check "$bash_guard" command 'opgate run -- npm run dev'           pass
check "$bash_guard" command 'opgate list'                         pass

echo "guard-bash — reading a plaintext secret file must ask"
check "$bash_guard" command 'cat .env'                            ask
check "$bash_guard" command 'cat api/.env.production'             ask
check "$bash_guard" command 'grep TOKEN .env'                     ask
check "$bash_guard" command 'cat ~/.ssh/id_rsa'                   ask

echo "guard-bash — templates, public keys and unrelated commands must pass"
check "$bash_guard" command 'cat .env.example'                    pass
check "$bash_guard" command 'cat .env.op'                         pass
check "$bash_guard" command 'cat ~/.ssh/id_rsa.pub'               pass
check "$bash_guard" command 'npm test'                            pass
check "$bash_guard" command 'git log --oneline -5'                pass
check "$bash_guard" command 'develop run something'               pass
check "$bash_guard" command 'echo ".env" >> .gitignore'           pass

echo "guard-read"
check "$read_guard" file_path '/p/.env'                           ask
check "$read_guard" file_path '/p/.env.production'                ask
check "$read_guard" file_path '/p/certs/server.pem'               ask
check "$read_guard" file_path '/home/u/.ssh/id_ed25519'           ask
check "$read_guard" file_path '/home/u/.aws/credentials'          ask
check "$read_guard" file_path '/p/.env.example'                   pass
check "$read_guard" file_path '/p/.env.op'                        pass
check "$read_guard" file_path '/home/u/.ssh/id_ed25519.pub'       pass
check "$read_guard" file_path '/p/src/env.ts'                     pass
check "$read_guard" file_path '/p/README.md'                      pass

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
