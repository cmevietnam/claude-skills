#!/usr/bin/env bash
# Compile the Touch ID gate into a stable location outside the plugin directory.
#
# The binary must NOT live under the plugin dir: ${CLAUDE_PLUGIN_ROOT} changes on every
# plugin update, which would silently orphan a compiled artifact there.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

src="$script_dir/touchid-gate.swift"
out="$OPGATE_GATE_BIN"

[[ "$(uname -s)" == "Darwin" ]] || die "the Touch ID gate is macOS-only (found $(uname -s))"
command -v swiftc >/dev/null 2>&1 || die "swiftc not found — install Xcode command line tools: xcode-select --install"
[[ -f "$src" ]] || die "missing source: $src"

mkdir -p -- "$(dirname -- "$out")"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/opgate-build.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

info "compiling touchid-gate…"
swiftc -O -framework LocalAuthentication -o "$tmp/touchid-gate" "$src"

# Ad-hoc sign: LocalAuthentication refuses to present its sheet for a binary with no
# code signature at all.
codesign --force --sign - "$tmp/touchid-gate" >/dev/null 2>&1 \
  || warn "codesign failed; the Touch ID sheet may not appear"

mv -f -- "$tmp/touchid-gate" "$out"
chmod 755 "$out"
info "built $out"
