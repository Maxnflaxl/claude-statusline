#!/usr/bin/env bash
# claude-statusline — https://github.com/maxnflaxl/claude-statusline
# Colorful three-line Claude Code statusline with icons.
# Line 1: dir · git · model (effort) · cost · time · rate-limit bars
# Line 2: context (+activity icon, cache hit rate) · token rate · session in/out
# Line 3: +added -removed (delta) for the working tree (incl. untracked) · session LOC
# Reads the Claude Code status JSON from stdin. Every field falls back gracefully.

# Consistent number formatting regardless of user locale (bash 3.2's builtin
# printf ignores per-command LC_ALL assignments, so export it globally).
export LC_ALL=C

# Where the token-accounting cache and rate-sample log live. Follows the same
# override Claude Code itself uses, so a relocated config dir keeps them together.
STATE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

input="$(cat)"

# ---- helpers -------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# macOS has no tac; use tail -r there.
revlines() { if have tac; then tac "$@"; else tail -r "$@"; fi; }

# Portable file size in bytes (BSD stat vs GNU stat).
fsize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }

# Humanize a token count: 950 / 12.3K / 1.2M
fmt_tok() {
  awk -v n="${1:-0}" 'BEGIN{
    if (n>=1000000) printf "%.1fM", n/1000000;
    else if (n>=1000) printf "%.1fK", n/1000;
    else printf "%d", n;
  }'
}

jqr() { # jqr <filter> <default>
  local out=""
  if have jq; then
    out="$(printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null)"
  fi
  [ -n "$out" ] && printf '%s' "$out" || printf '%s' "$2"
}

# ---- ANSI colors ---------------------------------------------------------
R=$'\033[0m'; DIM=$'\033[2m'
C_MODEL=$'\033[38;5;213m'    # pink/magenta
C_DIR=$'\033[38;5;39m'       # blue
C_GIT=$'\033[38;5;208m'      # orange
C_GITDIRTY=$'\033[38;5;196m' # red
C_CTX=$'\033[38;5;220m'      # yellow
C_COST=$'\033[38;5;46m'      # green
C_TIME=$'\033[38;5;51m'      # cyan
C_ADD=$'\033[32m'            # green
C_DEL=$'\033[31m'            # red
C_RL_OK=$'\033[38;5;75m'     # regular blue (rate limit healthy)
C_RL_WARN=$'\033[38;5;220m'  # yellow (getting close)
C_RL_HIT=$'\033[38;5;196m'   # red (hit)
C_STAGED=$'\033[38;5;46m'    # green (staged files)
C_UNSTAGED=$'\033[38;5;220m' # yellow (unstaged changes)
C_UNTRACKED="$DIM"           # dim (untracked files)
SEP="${DIM} │ ${R}"

# ---- fields --------------------------------------------------------------
model="$(jqr '.model.display_name' 'Claude')"
# Drop a trailing "(… context)" note — it's the default window, not worth the width.
model="${model% (*context)}"
effort="$(jqr '.effort.level' '')"
cur_dir="$(jqr '.workspace.current_dir' "$(jqr '.cwd' "$PWD")")"
dir_name="$(basename "$cur_dir" 2>/dev/null)"
transcript="$(jqr '.transcript_path' '')"
session_id="$(jqr '.session_id' '')"
cost_usd="$(jqr '.cost.total_cost_usd' '')"
dur_ms="$(jqr '.cost.total_duration_ms' '')"
ctx_pct="$(jqr '.context_window.used_percentage' '')"
ctx_size="$(jqr '.context_window.context_window_size' '')"
ctx_tokens="$(jqr '.context_window.current_usage | (.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens)' '')"
cache_read="$(jqr '.context_window.current_usage.cache_read_input_tokens' '')"
loc_added="$(jqr '.cost.total_lines_added' '')"
loc_removed="$(jqr '.cost.total_lines_removed' '')"
rl5_pct="$(jqr '.rate_limits.five_hour.used_percentage' '')"
rl5_reset="$(jqr '.rate_limits.five_hour.resets_at' '')"
rl7_pct="$(jqr '.rate_limits.seven_day.used_percentage' '')"
rl7_reset="$(jqr '.rate_limits.seven_day.resets_at' '')"
now="$(date +%s)"

# ---- git -----------------------------------------------------------------
git_seg=""
diff_line=""
if git -C "$cur_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$cur_dir" branch --show-current 2>/dev/null)"
  [ -z "$branch" ] && branch="$(git -C "$cur_dir" rev-parse --short HEAD 2>/dev/null)"

  # Count working-tree state from porcelain: staged (index col X), unstaged
  # (worktree col Y), and untracked (??). `IFS=` keeps the two status columns
  # intact — a default read would strip the leading space of " M file".
  gstatus="$(git -C "$cur_dir" status --porcelain 2>/dev/null)"
  n_staged=0; n_unstaged=0; n_untracked=0
  while IFS= read -r gl; do
    [ -z "$gl" ] && continue
    x="${gl:0:1}"; y="${gl:1:1}"
    if [ "$x$y" = "??" ]; then n_untracked=$(( n_untracked + 1 )); continue; fi
    [ "$x" != " " ] && [ "$x" != "?" ] && n_staged=$(( n_staged + 1 ))
    [ "$y" != " " ] && [ "$y" != "?" ] && n_unstaged=$(( n_unstaged + 1 ))
  done <<EOF
$gstatus
EOF

  if [ -n "$gstatus" ]; then
    gcol="$C_GITDIRTY"
    gmark=""
    [ "$n_staged"    -gt 0 ] && gmark="${gmark} ${C_STAGED}●${n_staged}${R}"
    [ "$n_unstaged"  -gt 0 ] && gmark="${gmark} ${C_UNSTAGED}✚${n_unstaged}${R}"
    [ "$n_untracked" -gt 0 ] && gmark="${gmark} ${C_UNTRACKED}?${n_untracked}${R}"
  else
    gcol="$C_GIT"; gmark=" ✓"
  fi
  # ahead/behind
  ab="$(git -C "$cur_dir" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)"
  behind="$(printf '%s' "$ab" | awk '{print $1}')"; ahead="$(printf '%s' "$ab" | awk '{print $2}')"
  updown=""
  [ -n "$ahead" ] && [ "$ahead" -gt 0 ] 2>/dev/null && updown="${updown} ${gcol}↑${ahead}${R}"
  [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null && updown="${updown} ${gcol}↓${behind}${R}"
  git_seg="${gcol}${branch}${R}${gmark}${updown}"

  # Include untracked files in the diff count without mutating the real index:
  # replay `add -N` against a throwaway copy of the index. A plain
  # `git add . -N` here genuinely stages deletions and plants intent-to-add
  # entries, corrupting in-progress commits.
  # The `:/` pathspec anchors the add at the repo root: `diff HEAD` below is
  # never path-limited, so a cwd-relative `.` would count tracked changes
  # repo-wide but untracked ones only at or below cwd.
  tmpidx="$(mktemp)"
  idxpath="$(git -C "$cur_dir" rev-parse --path-format=absolute --git-path index 2>/dev/null)"
  [ -f "$idxpath" ] && cp "$idxpath" "$tmpidx" 2>/dev/null
  GIT_INDEX_FILE="$tmpidx" git -C "$cur_dir" add -N :/ >/dev/null 2>&1
  shortstat="$(GIT_INDEX_FILE="$tmpidx" git -C "$cur_dir" diff HEAD --shortstat 2>/dev/null)"
  rm -f "$tmpidx"
  diff_added="$(printf '%s' "$shortstat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')"
  diff_removed="$(printf '%s' "$shortstat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+')"
  diff_added=${diff_added:-0}
  diff_removed=${diff_removed:-0}
  delta=$(( diff_added - diff_removed ))
  if [ "$delta" -ge 0 ]; then delta_str="+${delta}"; else delta_str="${delta}"; fi
  diff_line="${C_ADD}+${diff_added}${R} ${C_DEL}-${diff_removed}${R} ${DIM}(${delta_str})${R}"
fi

# ---- current activity icon (from transcript) ------------------------------
# Newest main-chain entry decides: assistant tool_use → tool icon,
# tool_result (assistant is thinking/streaming) → ✻, plain text → nothing.
act=""
if [ -n "$transcript" ] && [ -f "$transcript" ] && have jq; then
  last_state="$(tail -n 60 "$transcript" 2>/dev/null | jq -rR '
      fromjson? | select(.isSidechain != true)
      | select(.type=="assistant" or .type=="user")
      | if .type=="assistant"
        then ([.message.content[]? | select(.type=="tool_use") | .name] | last // "text")
        else (if ([.message.content[]? | select(.type=="tool_result")] | length) > 0 then "result" else "prompt" end)
        end' 2>/dev/null | tail -n 1)"
  case "$last_state" in
    Bash)                          act="" ;;
    Read)                          act="󰈔" ;;
    Edit|Write|NotebookEdit)       act="󰏫" ;;
    Grep|Glob)                     act="" ;;
    WebFetch|WebSearch)            act="󰖟" ;;
    Agent|Task|Workflow)           act="󱙺" ;;
    TodoWrite|TaskCreate|TaskUpdate|TaskList|TaskGet) act="" ;;
    Skill)                         act="" ;;
    AskUserQuestion)               act="" ;;
    mcp__*)                        act="󰐻" ;;
    result)                        act="✻" ;;
    text|prompt|"")                act="" ;;
    *)                             act="" ;;
  esac
fi

# ---- context usage --------------------------------------------------------
# Prefer harness-reported context_window figures; fall back to counting
# tokens from the transcript against the configured window size.
ctx_seg=""
if [ -z "$ctx_pct" ] || [ -z "$ctx_tokens" ]; then
  if [ -n "$transcript" ] && [ -f "$transcript" ] && have jq; then
    t="$(revlines "$transcript" 2>/dev/null | jq -rR '
        fromjson? | .message.usage
        | select(. != null)
        | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))' 2>/dev/null | head -n 1)"
    [ -n "$t" ] && ctx_tokens="$t"
    if [ -z "$ctx_pct" ] && [ -n "$ctx_tokens" ]; then
      size="${ctx_size:-200000}"
      [ "$size" -gt 0 ] 2>/dev/null || size=200000
      ctx_pct=$(( ctx_tokens * 100 / size ))
    fi
  fi
fi
if [ -n "$ctx_pct" ]; then
  # Dynamic color: blue with headroom, yellow past 60%, red past 85% —
  # same escalation language as the rate-limit bars.
  ctx_col="$C_RL_OK"
  if [ "$ctx_pct" -ge 85 ] 2>/dev/null; then ctx_col="$C_RL_HIT"
  elif [ "$ctx_pct" -ge 60 ] 2>/dev/null; then ctx_col="$C_RL_WARN"; fi
  # Cache hit rate: share of the current window served from the prompt cache.
  cache_seg=""
  if [ -n "$cache_read" ] && [ -n "$ctx_tokens" ] && [ "$ctx_tokens" -gt 0 ] 2>/dev/null; then
    hit=$(( cache_read * 100 / ctx_tokens ))
    cache_seg=" ${DIM}◈${hit}%${R}"
  fi
  if [ -n "$ctx_tokens" ] && [ "$ctx_tokens" -gt 0 ] 2>/dev/null; then
    ktok=$(( ctx_tokens / 1000 ))
    ctx_seg="${ctx_col}${ktok}k (${ctx_pct}%)${act:+ ${act}}${R}${cache_seg}"
  else
    ctx_seg="${ctx_col}${ctx_pct}%${act:+ ${act}}${R}${cache_seg}"
  fi
fi

# ---- rate limits ----------------------------------------------------------
rel_time() { # rel_time <epoch> — "3d4h", "2h10m", "45m"
  local d=$(( $1 - now )); [ "$d" -lt 0 ] && d=0
  local dd=$(( d / 86400 )) hh=$(( (d % 86400) / 3600 )) mm=$(( (d % 3600) / 60 ))
  if [ "$dd" -gt 0 ]; then printf '%dd%dh' "$dd" "$hh"
  elif [ "$hh" -gt 0 ]; then printf '%dh%dm' "$hh" "$mm"
  else printf '%dm' "$mm"; fi
}

rl_seg() { # rl_seg <label> <pct> <resets_at> — dot-matrix bar, dynamic color
  local label="$1" pct="$2" resets="$3"
  [ -n "$pct" ] || return 0
  local col="$C_RL_OK" extra=""
  if [ "$pct" -ge 100 ] 2>/dev/null; then
    col="$C_RL_HIT"
  elif [ "$pct" -ge 70 ] 2>/dev/null; then
    col="$C_RL_WARN"
  fi
  if [ "$col" != "$C_RL_OK" ] && [ -n "$resets" ]; then
    extra=" ↻$(rel_time "$resets")"
  fi
  local cells=8
  local filled=$(( (pct * cells + 50) / 100 ))
  [ "$filled" -gt "$cells" ] && filled="$cells"
  local i fill="" empty=""
  for (( i=0; i<cells; i++ )); do
    if [ "$i" -lt "$filled" ]; then fill="${fill}⣿"; else empty="${empty}⣀"; fi
  done
  printf '%s' "${col}${label} ${fill}${R}${DIM}${empty}${R}${col} ${pct}%${extra}${R}"
}

rl5_seg="$(rl_seg '5h' "$rl5_pct" "$rl5_reset")"
rl7_seg=""
# The 7-day limit only matters when its reset is still at least 6h away.
if [ -n "$rl7_pct" ] && [ -n "$rl7_reset" ] && [ $(( rl7_reset - now )) -ge 21600 ] 2>/dev/null; then
  rl7_seg="$(rl_seg '7d' "$rl7_pct" "$rl7_reset")"
fi

# ---- session LOC (what Claude changed this session) ------------------------
loc_seg=""
if [ -n "$loc_added" ] || [ -n "$loc_removed" ]; then
  loc_added=${loc_added:-0}; loc_removed=${loc_removed:-0}
  loc_delta=$(( loc_added - loc_removed ))
  if [ "$loc_delta" -ge 0 ]; then loc_delta_str="+${loc_delta}"; else loc_delta_str="${loc_delta}"; fi
  loc_seg="${DIM}󰏫 ${R}${C_ADD}+${loc_added}${R} ${C_DEL}-${loc_removed}${R} ${DIM}(${loc_delta_str})${R}"
fi

# ---- cost ----------------------------------------------------------------
cost_seg=""
if [ -n "$cost_usd" ]; then
  cost_fmt="$(printf '%.2f' "$cost_usd" 2>/dev/null)"
  [ -n "$cost_fmt" ] && cost_seg="${C_COST}\$${cost_fmt}${R}"
fi

# ---- session time --------------------------------------------------------
time_seg=""
if [ -n "$dur_ms" ] && [ "$dur_ms" -gt 0 ] 2>/dev/null; then
  secs=$(( dur_ms / 1000 )); h=$(( secs/3600 )); m=$(( (secs%3600)/60 )); s=$(( secs%60 ))
  if [ "$h" -gt 0 ]; then dur="${h}h${m}m"; elif [ "$m" -gt 0 ]; then dur="${m}m"; else dur="${s}s"; fi
  time_seg="${C_TIME}${dur}${R}"
fi

# ---- token throughput (in / out / t-per-min / sparkline) ------------------
# Cumulative session totals come from the transcript (dedup by message id,
# same accounting as ccbox: in = input + cache_creation, out = output). The
# parse is cached on transcript byte-size so it only reruns when the file grows
# — the statusline redraws far more often than new tokens actually land.
# NB: don't touch `out` here — that name is the assembled line-1 buffer below.
tok_in=""; tok_out=""
if [ -n "$transcript" ] && [ -f "$transcript" ] && have jq; then
  tsize="$(fsize "$transcript")"
  ucache_dir="$STATE_DIR/statusline-usage-cache"
  ucache="$ucache_dir/${session_id:-nosess}"
  c_size=""; c_in=""; c_out=""
  [ -f "$ucache" ] && read -r c_size c_in c_out _ < "$ucache" 2>/dev/null
  if [ -n "$tsize" ] && [ "$tsize" = "$c_size" ] && [ -n "$c_in" ]; then
    tok_in="$c_in"; tok_out="$c_out"
  else
    read -r tok_in tok_out < <(
      grep -a '"usage"' "$transcript" 2>/dev/null | jq -Rrn '
        [ inputs | fromjson? | select(.type=="assistant")
          | {id: .message.id, u: .message.usage}
          | select(.u != null and .id != null) ]
        | unique_by(.id)
        | reduce .[] as $x ({i:0,c:0,o:0};
            .i += ($x.u.input_tokens // 0)
            | .c += ($x.u.cache_creation_input_tokens // 0)
            | .o += ($x.u.output_tokens // 0))
        | "\(.i + .c) \(.o)"' 2>/dev/null)
    if [ -n "$tok_in" ]; then
      mkdir -p "$ucache_dir" 2>/dev/null
      printf '%s %s %s\n' "$tsize" "$tok_in" "$tok_out" > "$ucache"
      # Drop entries for sessions untouched for a day — a cache file is only
      # useful while its session is live (or being resumed), and this dir would
      # otherwise grow one stale file per session forever. Piggybacks on the
      # cache miss so it costs nothing on the redraw path, and the worst case
      # for over-pruning is a single re-parse.
      find "$ucache_dir" -type f -mtime +1 -delete 2>/dev/null
    fi
  fi
fi

tpm=""; spark=""; in_grew=0; out_grew=0
if [ -n "$tok_in" ] && [ -n "$session_id" ]; then
  RATE_LOG="$STATE_DIR/statusline-token-rate.log"
  # Append the current totals as a timestamped sample; GC anything older than
  # 300s. Shared across sessions, filtered by session_id when we read it back.
  rtmp="$(mktemp)"
  [ -f "$RATE_LOG" ] && awk -v now="$now" '($1+0) >= now-300' "$RATE_LOG" > "$rtmp" 2>/dev/null
  printf '%s %s %s %s\n' "$now" "$session_id" "$tok_in" "$tok_out" >> "$rtmp"
  mv -f "$rtmp" "$RATE_LOG" 2>/dev/null

  # Rate over a 60s window; activity over 10s; sparkline bucketed over 120s.
  # Sort by timestamp first: the delta logic needs chronological samples, and a
  # clock step or an interleaved write could otherwise put a row out of order.
  IFS=$'\t' read -r tpm spark in_grew out_grew < <(sort -n -k1,1 "$RATE_LOG" 2>/dev/null | awk \
      -v now="$now" -v sid="$session_id" -v win=60 -v sw=120 -v nb=22 '
    BEGIN{ L[1]="▁";L[2]="▂";L[3]="▃";L[4]="▄";L[5]="▅";L[6]="▆";L[7]="▇";L[8]="█" }
    $2==sid { ts[m]=$1+0; ci[m]=$3+0; co[m]=$4+0; io[m]=ci[m]+co[m]; m++ }
    END{
      rate=0; ig=0; og=0; s=""
      if (m>=2) {
        f=-1; for(i=0;i<m;i++) if(ts[i]>=now-win){ f=i; break }
        if(f>=0 && m-1>f){ el=ts[m-1]-ts[f]; if(el>0) rate=(io[m-1]-io[f])/el }
        g=-1; for(i=0;i<m;i++) if(ts[i]>=now-10){ g=i; break }
        if(g>=0 && m-1>g){ if(ci[m-1]>ci[g])ig=1; if(co[m-1]>co[g])og=1 }
        bs=sw/nb
        for(i=1;i<m;i++){ d=io[i]-io[i-1]; if(d<=0) continue
          idx=nb-1-int((now-ts[i])/bs); if(idx>=0 && idx<nb) b[idx]+=d }
        mx=0; for(i=0;i<nb;i++) if(b[i]>mx) mx=b[i]
        for(i=0;i<nb;i++){ lv=1
          if(mx>0){ lv=1+int(b[i]/mx*7+0.5); if(lv<1)lv=1; if(lv>8)lv=8 }
          s=s L[lv] }
      } else { for(i=0;i<nb;i++) s=s L[1] }
      printf "%d\t%s\t%d\t%d\n", int(rate+0.5), s, ig, og
    }')
fi

# Line-2 pieces: token rate (@ t/s) and the in/out counters, built separately
# so the assembler can order them as: context | rate | in/out.
rate_seg=""; io_seg=""
if [ -n "$tok_in" ]; then
  C_IN=$'\033[38;5;39m'; C_OUT=$'\033[38;5;220m'; C_TM=$'\033[38;5;213m'
  in_arr="$DIM"; [ "${in_grew:-0}" = 1 ] && in_arr="$C_IN"
  out_arr="$DIM"; [ "${out_grew:-0}" = 1 ] && out_arr="$C_OUT"
  io_seg="${in_arr}↓${R} ${DIM}in${R} ${C_IN}$(fmt_tok "$tok_in")${R}"
  io_seg="${io_seg}   ${out_arr}↑${R} ${DIM}out${R} ${C_OUT}$(fmt_tok "$tok_out")${R}"
  if [ -n "$tpm" ] && [ "$tpm" -gt 0 ] 2>/dev/null; then
    rate_seg="${C_TM}@ $(fmt_tok "$tpm")${R} ${DIM}t/s${R}"
  fi
fi

# ---- assemble (old order, rate limits on the right) -----------------------
model_txt="󰚩 ${model}"
[ -n "$effort" ] && model_txt="${model_txt} (${effort})"
out="${C_DIR}${dir_name}${R}"
[ -n "$git_seg" ]  && out="${out}${SEP}${git_seg}"
out="${out}${SEP}${C_MODEL}${model_txt}${R}"
[ -n "$cost_seg" ] && out="${out}${SEP}${cost_seg}"
[ -n "$time_seg" ] && out="${out}${SEP}${time_seg}"
[ -n "$rl5_seg" ]  && out="${out}${SEP}${rl5_seg}"
[ -n "$rl7_seg" ]  && out="${out}${SEP}${rl7_seg}"

printf '%b\n' "$out"
# Second line, ordered: context | @ t/s | in / out.
line_tok=""
for seg in "$ctx_seg" "$rate_seg" "$io_seg"; do
  [ -n "$seg" ] || continue
  if [ -n "$line_tok" ]; then line_tok="${line_tok}${SEP}${seg}"; else line_tok="$seg"; fi
done
[ -n "$line_tok" ] && printf '%b\n' "$line_tok"
line2=""
[ -n "$diff_line" ] && line2="$diff_line"
if [ -n "$loc_seg" ]; then
  if [ -n "$line2" ]; then line2="${line2}${SEP}${loc_seg}"; else line2="$loc_seg"; fi
fi
[ -n "$line2" ] && printf '%b\n' "$line2"
exit 0
