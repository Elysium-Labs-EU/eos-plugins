#!/usr/bin/env bash
# Guards against accidental drift between this repo's plugins and the eos
# plugin contract they consume. PROTOCOL.md is that contract, mirrored from
# eos core (see eos#138 companion issue) -- there is no shared Go package to
# apidiff, since plugins talk to eos over env vars + stdio, not a Go API.
#
# This checks that every EOS_SINK_* environment variable a plugin reads is
# one PROTOCOL.md documents. A plugin using an undocumented var means either
# the plugin invented an env var eos doesn't set (a bug), or eos's contract
# changed and PROTOCOL.md wasn't updated to match (drift) -- either way, a
# human should look at it before it ships.
set -euo pipefail

cd "$(dirname "$0")/.."

documented="$(grep -oE 'EOS_SINK_[A-Z_]*' PROTOCOL.md | sort -u)"
used="$(grep -rhoE 'EOS_SINK_[A-Z_]*' --include='*.go' -- eos-sink-*/ | sort -u)"

undocumented="$(comm -23 <(echo "$used") <(echo "$documented"))"

if [ -n "$undocumented" ]; then
  echo "check-protocol-drift FAILED: env var(s) used in plugin code but not documented in PROTOCOL.md:"
  while IFS= read -r var; do echo "  $var"; done <<<"$undocumented"
  echo
  echo "Either document the var in PROTOCOL.md, or fix the plugin to use the documented contract."
  exit 1
fi

echo "check-protocol-drift OK: all EOS_SINK_* vars used in plugin code are documented in PROTOCOL.md."
