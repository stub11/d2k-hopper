#!/bin/sh
set -eu

state="$1"
latest="$2"

echo "=== UPSTREAM RANGE ==="
echo "$state..$latest"
echo

echo "=== COMMITS ==="
git log --reverse --format='%H %ad %s' --date=iso-strict "$state..$latest"
echo

echo "=== FILE CHANGE SUMMARY ==="
git diff --stat "$state..$latest"
echo

echo "=== CHANGED FILES ==="
git diff --name-status "$state..$latest"
echo

echo "=== HOPPER OVERLAP ==="
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
git diff --name-only "$state..$latest" > "$tmp"

while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ -e "$path" ]; then
    printf 'OVERLAP: %s\n' "$path"
  else
    printf 'UPSTREAM-ONLY: %s\n' "$path"
  fi
done < "$tmp"

echo
echo "=== DIFF ==="
git diff --no-ext-diff --unified=3 "$state..$latest"
