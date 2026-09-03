#!/usr/bin/env bash
# Claude Code status line.
#
#   dev-setup (main*+2) ctx:77% ^1.2M v84k $7.13 5h:35% 7d:4% PR#12 Opus 5.1M [xhigh] 10:13:22
#
# Layout: dir (branch) context% tokens cost rate-limits pr model [effort] flags clock.
# Colours: context and the rate limits are green/yellow/red by threshold.
#
# Notes for future edits:
#   - Rendered on a ~300 ms debounce, so everything here must stay cheap. No
#     network calls; the PR badge comes from the payload, not from `gh`.
#   - settings.json invokes a bare `bash`, which can resolve to macOS /bin/bash
#     3.2 -- keep this file 3.2-compatible (no printf '%(%s)T', no `declare -A`).
#   - Payload schema for this Claude Code version: `claude` binary, search for
#     "How to use the statusLine command". Fields come and go between versions,
#     so every jq access below is `// ""`-guarded.
#   - Test: bash statusline-command.sh < a-captured-payload.json

# ---- toggles -----------------------------------------------------------------
SL_TOKENS=1       # cumulative session tokens (parses the transcript, cached)
SL_RATELIMIT_7D=1 # show the 7-day window next to the 5-hour one
SL_PR=1           # show the open PR/MR for the branch
SL_CACHE_WARN=1   # warn when the prompt cache is cold or about to expire
SL_CLOCK=1

# How to count input: "total" is every input token including cache reads -- the
# number the API bills against. "fresh" excludes cache reads, leaving what is
# charged at write rate. On one long session that is 135.4M vs 2.3M, so the two
# tell very different stories; pick the one you want to react to. Output totals
# are the same either way.
SL_TOKENS_MODE=total

# printf's %f both parses and prints through the numeric locale, so a comma-decimal
# environment printed "$7,00" -- it stopped reading "7.133" at the dot. LC_ALL, not
# LC_NUMERIC: an inherited LC_ALL outranks LC_NUMERIC and put the bug straight back.
LC_ALL=C

input=$(cat)

# jq drives the whole status line; if it isn't installed yet (e.g. before brew-core),
# degrade to just the
# directory name rather than erroring on every render.
if ! command -v jq >/dev/null 2>&1; then
  cwd=$(printf '%s' "$input" | sed -n 's/.*"current_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -z "$cwd" ] && cwd=$PWD
  printf '%s' "${cwd##*/}"
  exit 0
fi

# One jq pass; each field on its own line so EMPTY fields stay aligned on read.
# (Splitting one @tsv line with `read` collapses empty fields -- TAB is whitespace
# IFS -- and shifts every value left, so per-line reads are used instead.)
{
  IFS= read -r cwd
  IFS= read -r session_id
  IFS= read -r transcript
  IFS= read -r wt_name
  IFS= read -r ctx_remaining
  IFS= read -r model
  IFS= read -r effort
  IFS= read -r cost
  IFS= read -r rl5
  IFS= read -r rl5_reset
  IFS= read -r rl7
  IFS= read -r rl7_reset
  IFS= read -r spend
  IFS= read -r pr_num
  IFS= read -r pr_kind
  IFS= read -r pr_state
  IFS= read -r fast_mode
  IFS= read -r cache_cold
  IFS= read -r cache_expires
  IFS= read -r thinking_off
  IFS= read -r style
  IFS= read -r agent_name
} < <(jq -r '
  .cwd // .workspace.current_dir // "",
  .session_id // "",
  .transcript_path // "",
  .worktree.name // "",
  (.context_window.remaining_percentage // "" | tostring),
  .model.display_name // "",
  .effort.level // "",
  (.cost.total_cost_usd // "" | tostring),
  (.rate_limits.five_hour.used_percentage // "" | tostring),
  (.rate_limits.five_hour.resets_at // "" | tostring),
  (.rate_limits.seven_day.used_percentage // "" | tostring),
  (.rate_limits.seven_day.resets_at // "" | tostring),
  (.rate_limits.spend_limit.used_percentage // "" | tostring),
  (.pr.number // "" | tostring),
  .pr.kind // "pr",
  .pr.review_state // "",
  (.fast_mode == true | tostring),
  (.prompt_cache.warm == false | tostring),
  (.prompt_cache.expires_at // "" | tostring),
  (.thinking.enabled == false | tostring),
  .output_style.name // "",
  .agent.name // ""' <<<"$input" 2>/dev/null)

[ -z "$cwd" ] && cwd=$PWD
dir=${cwd##*/} # basename, no fork

# Clock and "now" in one fork (bash 3.2 has no printf '%(%s)T').
{
  IFS= read -r now
  IFS= read -r clock
} < <(date '+%s
%H:%M:%S')

# ---- git: one call for branch, upstream divergence and dirty state -----------
branch=""
dirty=""
ab=""
if [ -n "$cwd" ]; then
  while IFS= read -r line; do
    case $line in
      '# branch.head '*) branch=${line#\# branch.head } ;;
      '# branch.ab '*) ab=${line#\# branch.ab } ;;
      '#'*) ;;
      ?*) dirty="*" ;;
    esac
  done < <(git -C "$cwd" --no-optional-locks status \
    --porcelain=v2 --branch --untracked-files=no 2>/dev/null)
fi
[ "$branch" = "(detached)" ] && branch="detached"
# +N/-M ahead/behind, shown only when non-zero.
div=""
if [ -n "$ab" ]; then
  # shellcheck disable=SC2086  # splitting "+N -M" into two fields is the point
  set -- $ab
  [ "$1" != "+0" ] && div="$div$1"
  [ "$2" != "-0" ] && div="$div$2"
fi

# ---- cumulative session tokens ------------------------------------------------
# The payload's context_window numbers describe the *window* (and only the last
# response's output), not the session, so session totals are summed out of the
# transcript. Only the bytes appended since the last render are parsed; each API
# response is appended to a small per-session ledger which awk re-aggregates.
# The ledger is what makes this exact: one API response is written to the
# transcript once per content block, and those repeats are not always adjacent
# (measured -- adjacency-only dedupe over-counted one session by ~4%), so the
# dedupe needs to see every id, not just the previous one.
tok_in=""
tok_out=""
if [ "$SL_TOKENS" = 1 ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  cdir="${TMPDIR:-/tmp}/claude-statusline"
  [ -d "$cdir" ] || { mkdir -p "$cdir" 2>/dev/null; }
  # session_id arrives on stdin, so it is not trusted as a path component. Replacing
  # everything outside [A-Za-z0-9_-] rules out "/" and "." and with them any escape
  # from $cdir -- the .off file is opened with ">", so a traversal would truncate
  # whatever it landed on. It also stops a malformed id silently killing the feature.
  sid=${session_id//[!A-Za-z0-9_-]/_}
  sid=${sid:0:64}
  [ -n "$sid" ] || sid=unknown
  ledger="$cdir/$sid.ledger"
  offset_f="$cdir/$sid.off"
  off=$(cat "$offset_f" 2>/dev/null)
  case $off in '' | *[!0-9]*) off=0 ;; esac
  size=$(stat -f%z "$transcript" 2>/dev/null || stat -c%s "$transcript" 2>/dev/null || echo 0)
  if [ "$size" -lt "$off" ]; then # transcript rotated or rewound
    rm -f "$ledger" "$offset_f" 2>/dev/null
    off=0
  fi
  if [ ! -f "$ledger" ]; then # opportunistic prune, once per session
    find "$cdir" -type f -mtime +7 -delete 2>/dev/null
  fi
  # Only advance when the file ends on a newline: a half-written final line would
  # abort jq and lose the delta. The next render picks it up 300 ms later.
  if [ "$size" -gt "$off" ] && [ -z "$(tail -c 1 "$transcript")" ]; then
    # From a pipe jq is ~4x slower than reading the file itself (0.52 s vs 0.14 s
    # on a 15 MB transcript), so the cold pass -- the only large one -- is fed the
    # path directly; the incremental deltas are a few kB and the pipe is free.
    if [ "$off" -eq 0 ]; then
      feed() { jq -rn "$1" "$transcript"; }
    else
      feed() { tail -c "+$((off + 1))" "$transcript" | jq -rn "$1"; }
    fi
    # The offset only advances on success. A failed pass may have appended part of
    # the delta, and the next render appends it again -- the id dedupe absorbs that.
    # shellcheck disable=SC2016  # \(...) is jq string interpolation, not shell
    if feed '
         inputs | select(.message.usage != null) | .message as $m | $m.usage as $u |
         "\($m.id // "?") \($u.input_tokens // 0) \($u.output_tokens // 0) \($u.cache_creation_input_tokens // 0) \($u.cache_read_input_tokens // 0)"' \
      >>"$ledger" 2>/dev/null; then
      printf '%s\n' "$size" >"$offset_f" 2>/dev/null
    fi
  fi
  if [ -s "$ledger" ]; then
    {
      IFS= read -r tok_in
      IFS= read -r tok_out
    } < <(
      awk -v mode="$SL_TOKENS_MODE" '
        !seen[$1]++ { i += $2; o += $3; cw += $4; cr += $5 }
        END { printf "%d\n%d\n", (mode == "fresh" ? i + cw : i + cw + cr), o }' "$ledger"
    )
  fi
fi

# 1234 -> 1k, 1234567 -> 1.2M
human() {
  if [ "$1" -ge 1000000 ]; then
    printf '%d.%dM' $(($1 / 1000000)) $((($1 % 1000000) / 100000))
  elif [ "$1" -ge 1000 ]; then
    printf '%dk' $(($1 / 1000))
  else printf '%d' "$1"; fi
}

# 5400 -> 1h30m, 300 -> 5m
until_human() {
  s=$(($1 - now))
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -ge 3600 ]; then
    printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
  else printf '%dm' $((s / 60)); fi
}

# ---- rendering ----------------------------------------------------------------
if [ -n "${NO_COLOR:-}" ]; then
  g=""
  y=""
  r=""
  b=""
  m=""
  d=""
  z=""
else
  g=$'\033[32m'
  y=$'\033[33m'
  r=$'\033[31m'
  b=$'\033[34m'
  m=$'\033[35m'
  d=$'\033[2m'
  z=$'\033[0m'
fi

git_part=""
[ -n "$branch" ] && git_part=" ${y}(${branch}${dirty}${div})${z}"
[ -n "$wt_name" ] && git_part="$git_part ${m}wt:${wt_name}${z}"

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

tok_part=""
if [ -n "$tok_in" ] && [ "$tok_in" -gt 0 ]; then
  tok_part=" ${d}^$(human "$tok_in") v$(human "$tok_out")${z}"
fi

cost_part=""
[ -n "$cost" ] && printf -v cost_part ' $%.2f' "$cost"

# A limit's countdown is only interesting once the limit itself is.
rl_part=""
if [ -n "$rl5" ]; then
  printf -v v '%.0f' "$rl5"
  if [ "$v" -ge 90 ]; then
    c=$r
  elif [ "$v" -ge 70 ]; then
    c=$y
  else c=$g; fi
  rl_part=" ${c}5h:${v}%"
  [ "$v" -ge 70 ] && [ -n "$rl5_reset" ] && rl_part="$rl_part($(until_human "${rl5_reset%%.*}"))"
  rl_part="$rl_part${z}"
fi
if [ "$SL_RATELIMIT_7D" = 1 ] && [ -n "$rl7" ]; then
  printf -v v '%.0f' "$rl7"
  if [ "$v" -ge 90 ]; then
    c=$r
  elif [ "$v" -ge 70 ]; then
    c=$y
  else c=$d; fi
  rl_part="$rl_part ${c}7d:${v}%"
  [ "$v" -ge 70 ] && [ -n "$rl7_reset" ] && rl_part="$rl_part($(until_human "${rl7_reset%%.*}"))"
  rl_part="$rl_part${z}"
fi
if [ -n "$spend" ]; then # only behind a Claude gateway
  printf -v v '%.0f' "$spend"
  rl_part="$rl_part ${y}spend:${v}%${z}"
fi

pr_part=""
if [ "$SL_PR" = 1 ] && [ -n "$pr_num" ]; then
  case $pr_kind in mr) lbl="MR!$pr_num" ;; *) lbl="PR#$pr_num" ;; esac
  case $pr_state in
    approved) c=$g ;;
    changes_requested) c=$r ;;
    draft) c=$d ;;
    *) c=$y ;;
  esac
  pr_part=" ${c}${lbl}${z}"
fi

# "Opus 5 (1M context)" is too wide for a status line; "Opus 5.1M" is not.
case $model in *"(1M context)"*) model="${model% (1M context)}.1M" ;; esac
model_part=""
[ -n "$model" ] && model_part=" $model"
effort_part=""
[ -n "$effort" ] && effort_part=" ${d}[$effort]${z}"

# Flags: only the states that differ from the default are worth the width.
flags=""
[ "$fast_mode" = true ] && flags="${flags} !"    # /fast is on
[ "$thinking_off" = true ] && flags="${flags} ~" # thinking off
[ -n "$agent_name" ] && flags="${flags} @${agent_name}"
[ -n "$style" ] && [ "$style" != default ] && flags="${flags} :${style}"
if [ "$SL_CACHE_WARN" = 1 ]; then
  if [ "$cache_cold" = true ]; then
    flags="${flags} ${r}cache:cold${z}" # next turn re-sends everything
  elif [ -n "$cache_expires" ] && [ $((${cache_expires%%.*} - now)) -lt 300 ]; then
    flags="${flags} ${y}cache:${z}$(until_human "${cache_expires%%.*}")"
  fi
fi

clock_part=""
[ "$SL_CLOCK" = 1 ] && clock_part=" ${d}${clock}${z}"

printf '%s%s%s%s%s%s%s%s%s%s%s' \
  "${b}${dir}${z}" "$git_part" "$ctx_part" "$tok_part" "$cost_part" "$rl_part" \
  "$pr_part" "$model_part" "$effort_part" "$flags" "$clock_part"
