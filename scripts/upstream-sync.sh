#!/bin/sh
set -eu

latest="$(git rev-parse upstream/feat/telegram-tunnel)"
state_file=".github/upstream-sync-state"

[ -f "$state_file" ] || { echo "Missing $state_file; refusing to guess the upstream baseline." >&2; exit 1; }
state="$(tr -d '[:space:]' < "$state_file")"
[ -n "$state" ] || { echo "Empty $state_file; refusing to guess the upstream baseline." >&2; exit 1; }

[ "$latest" = "$state" ] && { echo "Upstream D2K unchanged at $latest"; exit 0; }

echo "Upstream D2K changed: $state -> $latest"
report="$(mktemp)"
trap 'rm -f "$report"' EXIT
sh scripts/upstream-diff-report.sh "$state" "$latest" > "$report"
if [ -n "${UPSTREAM_SYNC_REPORT:-}" ]; then
  cp "$report" "$UPSTREAM_SYNC_REPORT"
fi

unhandled=""
safe_count=0
while IFS="$(printf '\t')" read -r commit subject; do
  [ -n "$commit" ] || continue
  case "$commit" in
    d86d00b5dbab9066384422159712c5b74335937e) safe_count=$((safe_count + 1)) ;;
    *) unhandled="${unhandled}${commit} ${subject}\n" ;;
  esac
done <<EOF
$(git log --reverse --format='%H%x09%s' "$state..$latest")
EOF

if [ -n "$unhandled" ]; then
  title="Upstream D2K changes need Hopper adaptation: $latest"
  existing="$(gh issue list --state open --search "$title in:title" --json number --jq '.[0].number' || true)"
  if [ -z "$existing" ]; then
    if ! gh issue create --title "$title" --body "Upstream branch: https://github.com/necronicle/d2k/tree/feat/telegram-tunnel

Latest revision: $latest
Last acknowledged Hopper revision: $state

Unhandled changes:
$unhandled

Subsystem mapping and full diff report:
$(sed -n '1,320p' "$report")

This sync is fail-closed. No unreviewed upstream code was copied and the acknowledged state was not advanced.

Known-safe upstream revisions are allowlisted by exact commit SHA, not by commit title. Add a new SHA only after verifying the concrete diff, Hopper compatibility, and scripts/check.sh."; then
      echo "Could not create the tracking issue; upstream remains blocked. Diff report: ${UPSTREAM_SYNC_REPORT:-$report}" >&2
    fi
  else
    echo "Open tracking issue already exists: #$existing"
  fi
  echo "Stopping: upstream contains unhandled changes."
  exit 1
fi

for commit in $(git log --format='%H' "$state..$latest"); do
  case "$commit" in
    d86d00b5dbab9066384422159712c5b74335937e) sh scripts/upstream-adapt-mips-pipe.sh ;;
  esac
done

sh scripts/check.sh
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

push_main() {
  git fetch origin main
  if ! git merge-base --is-ancestor origin/main HEAD; then
    echo "Main advanced during sync; refusing to replace remote history." >&2
    return 1
  fi
  git push origin HEAD:main
}

if ! git diff --quiet; then
  git add -A
  git commit -m "sync(upstream): adapt D2K $latest for Hopper"
  push_main
fi

printf '%s\n' "$latest" > "$state_file"
git add "$state_file"
if ! git diff --cached --quiet; then
  git commit -m "chore(sync): record upstream D2K revision $latest"
  push_main
fi

echo "Upstream D2K sync complete at $latest (safe revisions: $safe_count)"
