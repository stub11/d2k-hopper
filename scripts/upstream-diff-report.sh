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

echo "=== HOPPER OVERLAP / SUBSYSTEM MAP ==="
git diff --name-only "$state..$latest" |
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ -e "$path" ]; then
    overlap="OVERLAP"
  else
    overlap="UPSTREAM-ONLY"
  fi
  classification="$(sh scripts/upstream-classify.sh "$path")"
  printf '%s\t%s\n' "$overlap" "$classification"
done
echo

echo "=== DIFF ==="
git diff --no-ext-diff --unified=3 "$state..$latest"
