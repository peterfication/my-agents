#!/usr/bin/env bash
# Claude Code status line: dir (branch*) ctx% $cost 5h-limit model [effort] time
# Colors: context & 5h rate-limit are green/yellow/red by threshold.
input=$(cat)

# jq drives the whole status line; if it isn't installed yet (e.g. before brew-core),
# degrade to just the directory name rather than erroring on every render.
if ! command -v jq >/dev/null 2>&1; then
  cwd=$(printf '%s' "$input" | sed -n 's/.*"current_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -z "$cwd" ] && cwd=$PWD
  printf '%s' "${cwd##*/}"
  exit 0
fi

# One jq pass; each field on its own line so EMPTY fields stay aligned on read.
# (Splitting one @tsv line with `read` collapses empty fields — TAB is whitespace
# IFS — and shifts every value left, so per-line reads are used instead.)
{
  IFS= read -r cwd
  IFS= read -r branch
  IFS= read -r ctx_remaining
  IFS= read -r model
  IFS= read -r effort
  IFS= read -r cost
  IFS= read -r ratelimit
} < <(jq -r '
  .cwd // .workspace.current_dir // "",
  .workspace.git_worktree // "",
  (.context_window.remaining_percentage // "" | tostring),
  .model.display_name // "",
  .effort.level // "",
  (.cost.total_cost_usd // "" | tostring),
  (.rate_limits.five_hour.used_percentage // "" | tostring)' <<<"$input")

[ -z "$cwd" ] && cwd=$PWD
dir=${cwd##*/} # basename, no fork

# Branch (fall back to symbolic-ref) + dirty flag
if [ -z "$branch" ] && [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
fi
dirty=""
if [ -n "$branch" ]; then
  git -C "$cwd" --no-optional-locks diff --quiet 2>/dev/null &&
    git -C "$cwd" --no-optional-locks diff --cached --quiet 2>/dev/null ||
    dirty="*"
fi

# ANSI colors
g=$'\033[32m'
y=$'\033[33m'
r=$'\033[31m'
b=$'\033[34m'
z=$'\033[0m'

# Parts (string interpolation with the colour vars; printf -v only where formatting)
git_part=""
[ -n "$branch" ] && git_part=" ${y}(${branch}${dirty})${z}"

ctx_part=""
if [ -n "$ctx_remaining" ]; then
  printf -v rem '%.0f' "$ctx_remaining"
  if [ "$rem" -gt 30 ]; then
    c=$g # plenty of context left
  elif [ "$rem" -gt 10 ]; then
    c=$y        # getting tight
  else c=$r; fi # nearly full
  ctx_part=" ${c}ctx:${rem}%${z}"
fi

cost_part=""
[ -n "$cost" ] && printf -v cost_part ' $%.2f' "$cost"

rl_part=""
if [ -n "$ratelimit" ]; then
  printf -v rl '%.0f' "$ratelimit"
  if [ "$rl" -ge 90 ]; then
    c=$r # close to the 5h limit
  elif [ "$rl" -ge 70 ]; then
    c=$y
  else c=$g; fi
  rl_part=" ${c}5h:${rl}%${z}"
fi

model_part=""
[ -n "$model" ] && model_part=" $model"
effort_part=""
[ -n "$effort" ] && effort_part=" [$effort]"

printf '%s%s%s%s%s%s%s %s' \
  "${b}${dir}${z}" "$git_part" "$ctx_part" "$cost_part" "$rl_part" \
  "$model_part" "$effort_part" "$(date +%H:%M:%S)"
