#!/usr/bin/env bash
# Blocks accidental large or binary blobs from landing in history.
#
# Runs against files added or modified vs a base ref (PR diffs, not the whole
# tree) so pre-existing large files don't retroactively break CI. A path
# tracked via Git LFS (declared `filter=lfs` in .gitattributes) is exempt --
# that's the sanctioned way to add a legitimately large or binary file.
#
#   LARGE_FILE_BASE       base ref (default: origin/main); CI sets it to PR target
#   LARGE_FILE_MAX_BYTES  size threshold in bytes (default: 512000, ~500KiB)
#
# Pure bash + git, no extra deps.
set -euo pipefail

MAX_BYTES="${LARGE_FILE_MAX_BYTES:-512000}"
BASE="${LARGE_FILE_BASE:-origin/main}"

if ! git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
  git fetch --quiet origin "${BASE#origin/}" 2>/dev/null || true
fi
if git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
  DIFF_BASE="$(git merge-base "$BASE" HEAD 2>/dev/null || echo "$BASE")"
else
  echo "check-large-files: base ref '$BASE' unresolvable; nothing to compare against, passing." >&2
  exit 0
fi

is_lfs_tracked() {
  local file="$1"
  [ -f .gitattributes ] || return 1
  git check-attr filter -- "$file" | grep -q 'filter: lfs$'
}

CHANGED="$(git diff --diff-filter=ACMR --name-only "$DIFF_BASE" HEAD || true)"
if [ -z "$CHANGED" ]; then
  echo "check-large-files: no added/modified files vs $BASE; nothing to gate."
  exit 0
fi

bad=0
while IFS= read -r file; do
  [ -f "$file" ] || continue
  if is_lfs_tracked "$file"; then
    continue
  fi

  size="$(wc -c < "$file" | tr -d ' ')"
  if [ "$size" -gt "$MAX_BYTES" ]; then
    echo "  TOO LARGE  ${size} bytes  $file  (limit ${MAX_BYTES} bytes)"
    bad=1
    continue
  fi

  if git diff --numstat "$DIFF_BASE" HEAD -- "$file" | grep -q $'^-\t-\t'; then
    echo "  BINARY     $file"
    bad=1
  fi
done <<<"$CHANGED"

if [ "$bad" -ne 0 ]; then
  echo
  echo "check-large-files FAILED: large or binary blob(s) staged without Git LFS."
  echo "Either shrink/remove the file, or track it with Git LFS (git lfs track '<pattern>')."
  exit 1
fi

echo "check-large-files OK: no oversized or binary blobs vs $BASE."
