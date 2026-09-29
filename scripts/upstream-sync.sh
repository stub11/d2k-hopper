#!/bin/sh
set -eu

latest="$(git rev-parse upstream/feat/telegram-tunnel)"
state_file=".github/upstream-sync-state"
state="$(tr -d '[:space:]' < "$state_file" 2>/dev/null || true)"

if [ -z "$state" ]; then
  state="$(git rev-parse upstream/feat/telegram-tunnel~1)"
fi

if [ "$latest" = "$state" ]; then
  echo "Upstream D2K unchanged at $latest"
  exit 0
fi

echo "Upstream D2K changed: $state -> $latest"
git log --reverse --format='%H %s' "$state..$latest"

unhandled="$(git log --format='%H %s' "$state..$latest" | grep -v 'fix(mips): accept positive pipe success on MIPS' || true)"

if [ -n "$unhandled" ]; then
  title="Upstream D2K changes need Hopper adaptation: $latest"
  existing="$(gh issue list --state open --search "$title in:title" --json number --jq '.[0].number' || true)"

  if [ -z "$existing" ]; then
    gh issue create       --title "$title"       --body "Upstream branch: https://github.com/necronicle/d2k/tree/feat/telegram-tunnel

Latest revision: $latest
Last acknowledged Hopper revision: $state

Unhandled changes:
$unhandled

This sync is fail-closed. No unreviewed upstream code was copied and the acknowledged state was not advanced. Add a targeted adapter only after verifying Hopper compatibility and passing scripts/check.sh."
  else
    echo "Open tracking issue already exists: #$existing"
  fi

  echo "Stopping: upstream contains unhandled changes."
  exit 1
fi

for commit in $(git log --format='%H' "$state..$latest"); do
  subject="$(git show -s --format='%s' "$commit")"
  case "$subject" in
    'fix(mips): accept positive pipe success on MIPS'*)
      sh scripts/upstream-adapt-mips-pipe.sh
      ;;
  esac
done

sh scripts/check.sh

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

if ! git diff --quiet; then
  git add -A
  git commit -m "sync(upstream): adapt D2K $latest for Hopper"
  git push origin HEAD:main
fi

printf '%s\n' "$latest" > "$state_file"
git add "$state_file"

if ! git diff --cached --quiet; then
  git commit -m "chore(sync): record upstream D2K revision $latest"
  git push origin HEAD:main
fi

echo "Upstream D2K sync complete at $latest"
