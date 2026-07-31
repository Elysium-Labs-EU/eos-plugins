#!/usr/bin/env bash
# Enforces `any` over `interface{}` for consistency (Go 1.18+ alias for the
# same type; this repo picks one spelling). Cheap grep across all *.go
# files rather than a linter rule, so it also catches the type in comments
# and string literals that a type-aware linter would ignore.
set -euo pipefail

hits="$(grep -rn 'interface{}' --include='*.go' . || true)"
if [ -n "$hits" ]; then
  echo "check-any-convention FAILED: use \`any\` instead of \`interface{}\`:"
  echo "$hits"
  exit 1
fi

echo "check-any-convention OK: no interface{} usage found."
