#!/usr/bin/env bash
# Tests for the dotenv parser. Two kinds:
#
#   1. pure unit checks of parse_env_file (always run)
#   2. differential checks against the installed `op run` (skipped when 1Password
#      is locked, since the point is to compare real behaviour)
#
# The differential part matters more than it looks: if this parser and op disagree
# about which variables a file declares, the Touch ID sheet under-reports what is
# about to be resolved. That is a security defect, not a formatting one.
set -uo pipefail

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$dir/lib/classify.sh"
source "$dir/lib/common.sh"

pass=0 fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/opgate-test-parser.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

chk() { # <label> <got> <want>
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n       got  [%s]\n       want [%s]\n' "$1" "$2" "$3"; fi
}

parse_one() { # <label> <file-content> <var> -> prints value
  printf '%s' "$2" > "$tmp/e"
  parse_env_file "$tmp/e" 2>/dev/null || { printf '<refused>'; return; }
  local i
  for (( i = 0; i < ${#OPG_NAMES[@]}; i++ )); do
    [[ "${OPG_NAMES[$i]}" == "$3" ]] && { printf '%s' "${OPG_VALUES[$i]}"; return; }
  done
  printf '<absent>'
}

names_of() { printf '%s' "$1" > "$tmp/e"; parse_env_file "$tmp/e"
  local IFS=,; printf '%s' "${OPG_NAMES[*]-}"; }

echo "variable names"
chk "export with several spaces" "$(names_of 'export    API_TOKEN=x')" "API_TOKEN"
chk "export with a tab"          "$(names_of "export$(printf '\t')API_TOKEN=x")" "API_TOKEN"
chk "whitespace around the ="    "$(names_of 'ADMIN_TOKEN = op://Dev/a/B')" "ADMIN_TOKEN"
chk "name starting with a digit" "$(names_of '1TOKEN=x')" "1TOKEN"
chk "comments and blank lines skipped" "$(names_of '# c

A=1
B=2')" "A,B"
chk "last line with no trailing newline" "$(names_of 'A=1
B=2')" "A,B"

echo "values"
chk "trailing comment"          "$(parse_one x 'API_TOKEN=abc123 #rotation-note' API_TOKEN)" "abc123"
chk "comment with no space before it" "$(parse_one x 'API_TOKEN=abc123#note' API_TOKEN)" "abc123"
chk "# inside single quotes"    "$(parse_one x "APP_NAME='Acme # prod'" APP_NAME)" "Acme # prod"
chk "# inside double quotes"    "$(parse_one x 'APP_NAME="Acme # prod"' APP_NAME)" "Acme # prod"
chk "double quotes, escaped \\n" "$(parse_one x 'A="x\ny"' A)" "$(printf 'x\ny')"
chk "double quotes, \\t STAYS two characters (as op does)" "$(parse_one x 'A="a\tb"' A)" 'a\tb'
chk "double quotes, trailing \\n kept" "$(parse_one x 'A="x\n"' A | od -An -c | tr -s ' ')" "$(printf 'x\n' | od -An -c | tr -s ' ')"
chk "single quotes keep \\n literal" "$(parse_one x "A='x\\ny'" A)" 'x\ny'
chk "escaped quote"             "$(parse_one x 'A="say \"hi\""' A)" 'say "hi"'
chk "value containing an ="     "$(parse_one x 'A=k=v' A)" "k=v"
chk "CRLF"                   "$(parse_one x "$(printf 'A=1\r\nB=2\r\n')" A)" "1"
chk "trailing whitespace trimmed" "$(parse_one x 'A=val   ' A)" "val"

echo "multiline values"
chk "multiline in double quotes" "$(parse_one x 'A="line1
line2"
B=2' A)" "$(printf 'line1\nline2')"
chk "a variable after a multiline value is still seen" "$(names_of 'A="line1
line2"
B=2')" "A,B"
chk "PEM in single quotes" "$(parse_one x "K='-----BEGIN X-----
body
-----END X-----'" K)" "$(printf -- '-----BEGIN X-----\nbody\n-----END X-----')"

echo "round 3 — the parser REFUSES what op refuses, instead of guessing"
refuses() { # <label> <content>
  printf '%s' "$2" > "$tmp/e"
  if out=$( (parse_env_file "$tmp/e") 2>&1 ); then fail=$((fail+1)); printf '  FAIL %s — did not refuse\n' "$1"
  else pass=$((pass+1)); printf '  ok   %s\n' "$1"; fi
}
refuses "BOM at the start of the file" "$(printf '\xef\xbb\xbfA=1\nB=2\n')"
refuses "unclosed quote"               'A="abc'
refuses "unclosed quote, trailing escape" 'A="abc\"'
printf 'A=ab\000cd\n' > "$tmp/e"   # written directly: $(...) would strip the NUL
if (parse_env_file "$tmp/e") >/dev/null 2>&1; then fail=$((fail+1)); printf '  FAIL NUL byte — did not refuse\n'
else pass=$((pass+1)); printf '  ok   byte NUL\n'; fi
refuses "\$VAR inside double quotes"  'A="$HOME/x"'
refuses "\$VAR unquoted"              'A=$HOME/x'
refuses "\${VAR}"                   'A="${HOME}"'

echo "round 3 — what op accepts, the parser accepts"
chk "\$ inside single quotes is literal" "$(parse_one x "A='\$HOME'" A)" '$HOME'
chk "\\\$ escaped inside double quotes is kept" "$(parse_one x 'A="\$x"' A)" '\$x'
chk "\$ at end of string is not an expansion" "$(parse_one x 'A=cost5$' A)" 'cost5$'
chk "exportHIDDEN -> HIDDEN (as op does)" "$(names_of 'exportHIDDEN=1' 2>/dev/null)" "HIDDEN"
chk "duplicate: one name, the last value" "$(names_of 'A=1
A=2
B=3')/$(parse_one x 'A=1
A=2' A)" "A,B/2"

echo "round 3 — dotenv_quote round-trips through the parser"
eval "$(sed -n '/^dotenv_quote()/,/^}/p' "$dir/../bin/opgate")"
rt() { # <label> <value>
  printf 'V=%s\n' "$(dotenv_quote "$2")" > "$tmp/e"
  # Subshell + sentinel: `die` inside the parser must not kill the test, and
  # $(...) must not eat a trailing newline we are specifically testing for.
  local got; got=$( (parse_env_file "$tmp/e" 2>/dev/null && printf '%sx' "${OPG_VALUES[0]}") ); got="${got%x}"
  if [[ "$got" == "$2" ]]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n       got  [%s]\n       want [%s]\n' "$1" "$got" "$2"; fi
}
rt "plain string"         'simple'
rt "whitespace"           'has space'
rt "double quote"         'has"quote'
rt "hash"                 'has#hash'
rt "newline"             "$(printf 'two\nlines')"
rt "trailing newline"     "$(printf 'end\n')"
rt "real tab"             "$(printf 'a\tb')"
rt "backslash-t, 2 chars" 'a\tb'
rt "dollar (single quotes)" 'cost $5'
rt "backslash"           'a\b'
rt "URL"                 'https://a.example/x?y=1'

echo "measured directly against op run"
if op vault list --format json </dev/null >/dev/null 2>&1; then
  # op resolves these files; if it exports a variable this parser does not list,
  # the approval prompt would be lying about scope.
  cat > "$tmp/diff.env" <<'X'
export    A_ONE=1
B_TWO = 2
1DIGIT=3
C_THREE=val #comment
D_FOUR='keep # this'
E_FIVE="multi
line"
F_SIX="tab\there"
G_SEVEN="end\n"
exportH_EIGHT=8
X
  op_names=$(op run --env-file="$tmp/diff.env" -- \
    sh -c 'env | grep -E "^(A_ONE|B_TWO|1DIGIT|C_THREE|D_FOUR|E_FIVE|F_SIX|G_SEVEN|H_EIGHT|exportH_EIGHT)=" | cut -d= -f1 | sort | tr "\n" ","' 2>/dev/null)
  parse_env_file "$tmp/diff.env" 2>/dev/null
  our_names=$(printf '%s\n' "${OPG_NAMES[@]-}" | grep -E '^(A_ONE|B_TWO|1DIGIT|C_THREE|D_FOUR|E_FIVE|F_SIX|G_SEVEN|H_EIGHT|exportH_EIGHT)$' | sort | tr '\n' ',')
  chk "the variable list matches op run" "$our_names" "$op_names"

  for v in C_THREE D_FOUR E_FIVE F_SIX G_SEVEN; do
    # Compared as octal dumps so a trailing newline or a literal backslash is
    # visible in the diff rather than swallowed by $(...).
    op_val=$(op run --env-file="$tmp/diff.env" -- sh -c "printf '%s' \"\$$v\" | od -An -c" 2>/dev/null | tr -s ' ')
    parse_env_file "$tmp/diff.env" 2>/dev/null
    our_val=""; for (( k = 0; k < ${#OPG_NAMES[@]}; k++ )); do [[ "${OPG_NAMES[$k]}" == "$v" ]] && our_val=$(printf '%s' "${OPG_VALUES[$k]}" | od -An -c | tr -s ' '); done
    chk "value of $v matches op run (od)" "$our_val" "$op_val"
  done
else
  printf '  skipped: 1Password is locked, cannot compare against op run\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
