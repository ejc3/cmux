#!/bin/bash
# ============================================================================
# Remote-tmux linked-view CHAOS + DATA-INTEGRITY soak.
#
# A leak-only metric ("too many windows") is one-sided: over-eager discard makes
# it look BETTER, so it REWARDS data loss. This soak uses a TWO-SIDED oracle:
#   - leak:      live window count must stay bounded under host-death churn;
#   - data-loss: a window that should survive (baseline; aggregated window whose
#                OTHER host is still alive) must NOT disappear (tracked by id);
#   - render:    a freshly-attached mirror must render with no stray PROMPT_SP "%".
# Plus deterministic scenarios for the exact ordered sequences that bit us
# (aggregate two hosts then kill one; bootstrap whose session vanishes instantly).
#
# Runs ONLY against throwaway localhost ssh aliases (default cmux-srvA/cmux-srvB ->
# /tmp/cmux-srvA|B) so it never touches your real tmux. See the render harness
# header for the ~/.ssh/config alias setup. Requires a tagged app running:
#   ./scripts/reload.sh --tag <tag> --launch ; CMUX_TAG=<tag> SOAK_DURATION=600 \
#       ./scripts/remote-tmux-linkedview-soak.sh
# ============================================================================
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${CMUX_TAG:?set CMUX_TAG to the tagged debug app (e.g. CMUX_TAG=lv-all)}"
TMUXBIN="${CMUX_SOAK_TMUX:-/opt/homebrew/bin/tmux}"
SRV_A="${CMUX_SOAK_SRV_A:-cmux-srvA}"; DIR_A="${CMUX_SOAK_DIR_A:-/tmp/cmux-srvA}"
SRV_B="${CMUX_SOAK_SRV_B:-cmux-srvB}"; DIR_B="${CMUX_SOAK_DIR_B:-/tmp/cmux-srvB}"
SEED="${SOAK_SEED:-1337}"; RANDOM=$SEED
DURATION="${SOAK_DURATION:-600}"
APPRE="${CMUX_TAG}/Build/Products/Debug/cmux DEV ${CMUX_TAG}.app/Contents/MacOS"
UUID='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
LOG="${SOAK_LOG:-/tmp/cmux-linkedview-soak.log}"; : > "$LOG"

cli() { CMUX_TAG="$CMUX_TAG" timeout 20 "$REPO/scripts/cmux-debug-cli.sh" "$@" 2>&1; }
ts() { date +%H:%M:%S; }
log() { echo "$(ts) $*" | tee -a "$LOG"; }
app_alive() { pgrep -f "$APPRE" >/dev/null; }
real_count() { TMUX_TMPDIR=$1 "$TMUXBIN" ls 2>/dev/null | grep -vc cmux-view; }
ensure_server() { local d=$1; mkdir -p "$d"; TMUX_TMPDIR=$d "$TMUXBIN" has-session 2>/dev/null || TMUX_TMPDIR=$d "$TMUXBIN" new-session -d -s s0 2>/dev/null; }
win_ids() { cli list-windows | awk '{for(i=1;i<=NF;i++) if($i ~ /^selected_workspace=/) print $(i-1)}'; }
win_count() { win_ids | grep -cE "$UUID"; }
win_present() { win_ids | grep -qix "$1"; }
win_workspaces() { cli list-windows | awk -v w="$1" 'index($0,w){for(i=1;i<=NF;i++) if($i ~ /^workspaces=/){sub("workspaces=","",$i); print $i}}'; }
win_stray_pct() { cli read-screen --window "$1" 2>/dev/null | grep -acE '(^|[^[:alnum:]])%[[:space:]]*$'; }
attach_get_window() {
  local before after; before=$(win_ids | sort -u)
  cli ssh-tmux "$1" --no-focus >/dev/null 2>&1; sleep 1
  after=$(win_ids | sort -u)
  comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -iE "$UUID" | head -1
}

ANOM_CRASH=0; ANOM_HANG=0; ANOM_SESS=0; ANOM_WIN=0; ANOM_LOSS=0; ANOM_DIRTY=0; ITERS=0; MAXWIN=0
BASELINE_WINS=()

check_invariants() {
  if ! app_alive; then log "!!! CRITICAL: app DIED"; ANOM_CRASH=$((ANOM_CRASH+1)); return 1; fi
  local wl wc; wl=$(cli list-windows)
  if [ -z "$wl" ] || echo "$wl" | grep -qiE 'socket not found|refused|connection|unknown command'; then
    log "!!! ANOM hang/unresponsive CLI: ${wl:0:90}"; ANOM_HANG=$((ANOM_HANG+1))
  fi
  wc=$(echo "$wl" | grep -cE '^[[:space:]]*[*[:space:]][[:space:]]*[0-9]+:')
  [ "${wc:-0}" -gt "$MAXWIN" ] && MAXWIN=$wc
  [ "${wc:-0}" -gt 14 ] && { log "!!! ANOM window leak wc=$wc"; ANOM_WIN=$((ANOM_WIN+1)); }
  local b
  for b in "${BASELINE_WINS[@]}"; do
    win_present "$b" || { log "!!! DATALOSS: baseline window $b disappeared"; ANOM_LOSS=$((ANOM_LOSS+1)); BASELINE_WINS=(); break; }
  done
  local s rc
  for s in "$DIR_A" "$DIR_B"; do rc=$(real_count "$s"); [ "${rc:-0}" -gt 25 ] && { log "!!! ANOM session runaway $s rc=$rc"; ANOM_SESS=$((ANOM_SESS+1)); }; done
  return 0
}

di_aggregate_kill_one() {
  ensure_server "$DIR_A"; ensure_server "$DIR_B"
  local W; W=$(attach_get_window "$SRV_A"); [ -z "$W" ] && { log "DI-aggkill skip"; return; }
  cli ssh-tmux "$SRV_B" --into-window "$W" --no-focus >/dev/null 2>&1; sleep 2
  log "DI-aggkill: aggregated $SRV_A+$SRV_B into $W (workspaces=$(win_workspaces "$W")); killing ONLY $SRV_A"
  local s; for s in $(TMUX_TMPDIR="$DIR_A" "$TMUXBIN" ls -F '#{session_name}' 2>/dev/null|grep -v cmux-view); do TMUX_TMPDIR="$DIR_A" "$TMUXBIN" kill-session -t "$s" 2>/dev/null; done
  sleep 3
  if win_present "$W"; then log "DI-aggkill OK: $W survived (workspaces=$(win_workspaces "$W"))"; else log "!!! DATALOSS DI-aggkill: $W discarded when only $SRV_A died"; ANOM_LOSS=$((ANOM_LOSS+1)); fi
  TMUX_TMPDIR="$DIR_B" "$TMUXBIN" kill-server 2>/dev/null
}
di_bootstrap_vanish() {
  ensure_server "$DIR_B"
  for s in $(TMUX_TMPDIR="$DIR_B" "$TMUXBIN" ls -F '#{session_name}' 2>/dev/null|grep -v cmux-view); do TMUX_TMPDIR="$DIR_B" "$TMUXBIN" kill-session -t "$s" 2>/dev/null; done
  log "DI-bootvanish: empty $SRV_B, attach, race-kill the bootstrapped session 3x"
  cli ssh-tmux "$SRV_B" --no-focus >/dev/null 2>&1
  local k; for k in 1 2 3; do sleep 1; for s in $(TMUX_TMPDIR="$DIR_B" "$TMUXBIN" ls -F '#{session_name}' 2>/dev/null|grep -v cmux-view); do TMUX_TMPDIR="$DIR_B" "$TMUXBIN" kill-session -t "$s" 2>/dev/null; done; done
  sleep 2; ensure_server "$DIR_B"
}
di_render_clean() {
  ensure_server "$DIR_A"
  local before; before=$(win_ids | sort -u)
  cli ssh-tmux "$SRV_A" --no-focus >/dev/null 2>&1; sleep 3
  local W; W=$(win_ids | sort -u | comm -13 <(printf '%s\n' "$before") - | grep -iE "$UUID" | head -1)
  [ -z "$W" ] && { log "DI-render skip"; return; }
  local sp; sp=$(win_stray_pct "$W")
  if [ "${sp:-0}" -gt 0 ]; then log "!!! DIRTY DI-render: $W shows $sp stray PROMPT_SP '%'"; ANOM_DIRTY=$((ANOM_DIRTY+1)); else log "DI-render OK: $W clean"; fi
}

END=$(( $(date +%s) + DURATION ))
ensure_server "$DIR_A"; ensure_server "$DIR_B"
while IFS= read -r _w; do [ -n "$_w" ] && BASELINE_WINS+=("$_w"); done < <(win_ids | grep -iE "$UUID" | sort -u)
log "SOAK START app=$(pgrep -f "$APPRE" | head -1) seed=$SEED baselineWindows=${#BASELINE_WINS[@]} dur=${DURATION}s"
i=0
while [ "$(date +%s)" -lt "$END" ]; do
  i=$((i+1)); ITERS=$i
  case $(( RANDOM % 18 )) in
    0) log "[$i] attach A"; cli ssh-tmux "$SRV_A" --no-focus >/dev/null ;;
    1) log "[$i] attach B"; cli ssh-tmux "$SRV_B" --no-focus >/dev/null ;;
    2) log "[$i] rapid re-attach A"; cli ssh-tmux "$SRV_A" --no-focus >/dev/null; cli ssh-tmux "$SRV_A" --no-focus >/dev/null ;;
    3) log "[$i] new session A + attach"; TMUX_TMPDIR="$DIR_A" "$TMUXBIN" new-session -d -s "w$i" 2>/dev/null; cli ssh-tmux "$SRV_A" --no-focus >/dev/null ;;
    4) log "[$i] kill a session A"; sn=$(TMUX_TMPDIR="$DIR_A" "$TMUXBIN" ls -F '#{session_name}' 2>/dev/null|grep -v cmux-view|head -1); [ -n "$sn" ] && TMUX_TMPDIR="$DIR_A" "$TMUXBIN" kill-session -t "$sn" 2>/dev/null ;;
    5) log "[$i] new-window A"; sn=$(TMUX_TMPDIR="$DIR_A" "$TMUXBIN" ls -F '#{session_name}' 2>/dev/null|grep -v cmux-view|head -1); [ -n "$sn" ] && TMUX_TMPDIR="$DIR_A" "$TMUXBIN" new-window -t "$sn" 2>/dev/null ;;
    6) log "[$i] rename A"; sn=$(TMUX_TMPDIR="$DIR_A" "$TMUXBIN" ls -F '#{session_name}' 2>/dev/null|grep -v cmux-view|head -1); [ -n "$sn" ] && TMUX_TMPDIR="$DIR_A" "$TMUXBIN" rename-session -t "$sn" "r$i" 2>/dev/null ;;
    7) log "[$i] CONCURRENT double-attach B"; cli ssh-tmux "$SRV_B" --no-focus >/dev/null & cli ssh-tmux "$SRV_B" --no-focus >/dev/null & wait ;;
    8) log "[$i] *** SERVER DEATH: kill-server B ***"; TMUX_TMPDIR="$DIR_B" "$TMUXBIN" kill-server 2>/dev/null ;;
    9) log "[$i] recover B + attach"; ensure_server "$DIR_B"; cli ssh-tmux "$SRV_B" --no-focus >/dev/null ;;
    10) log "[$i] *** kill cmux-view OWNER on A ***"; vn=$(TMUX_TMPDIR="$DIR_A" "$TMUXBIN" ls -F '#{session_name}' 2>/dev/null|grep cmux-view|head -1); [ -n "$vn" ] && TMUX_TMPDIR="$DIR_A" "$TMUXBIN" kill-session -t "$vn" 2>/dev/null; cli ssh-tmux "$SRV_A" --no-focus >/dev/null ;;
    11) log "[$i] *** kill SSH master to A ***"; pkill -f "ssh.*$SRV_A" 2>/dev/null; sleep 1; cli ssh-tmux "$SRV_A" --no-focus >/dev/null ;;
    12) log "[$i] *** empty B then attach (bootstrap) ***"; for s in $(TMUX_TMPDIR="$DIR_B" "$TMUXBIN" ls -F '#{session_name}' 2>/dev/null|grep -v cmux-view); do TMUX_TMPDIR="$DIR_B" "$TMUXBIN" kill-session -t "$s" 2>/dev/null; done; cli ssh-tmux "$SRV_B" --no-focus >/dev/null ;;
    13) log "[$i] churn burst B"; for k in 1 2 3; do TMUX_TMPDIR="$DIR_B" "$TMUXBIN" new-session -d -s "b$i-$k" 2>/dev/null; done; TMUX_TMPDIR="$DIR_B" "$TMUXBIN" kill-session -t "b$i-2" 2>/dev/null ;;
    14) log "[$i] *** AGGREGATE A+B in ONE window ***"; cli ssh-tmux "$SRV_A" --no-focus >/dev/null; aw=$(win_ids | grep -iE "$UUID" | head -1); [ -n "$aw" ] && cli ssh-tmux "$SRV_B" --into-window "$aw" --no-focus >/dev/null ;;
    15) di_aggregate_kill_one ;;
    16) di_bootstrap_vanish ;;
    17) di_render_clean ;;
  esac
  sleep 2
  check_invariants || break
  if [ $((i % 12)) -eq 0 ]; then ensure_server "$DIR_A"; ensure_server "$DIR_B"; log "[$i] keepalive (live windows=$(win_count))"; fi
done
log "SOAK END iters=$ITERS seed=$SEED crash=$ANOM_CRASH hang=$ANOM_HANG sessRunaway=$ANOM_SESS winLeak=$ANOM_WIN dataLoss=$ANOM_LOSS renderDirty=$ANOM_DIRTY maxWindows=$MAXWIN app_alive=$(app_alive && echo YES || echo NO)"
echo "SOAK_COMPLETE iters=$ITERS crash=$ANOM_CRASH hang=$ANOM_HANG sessRunaway=$ANOM_SESS winLeak=$ANOM_WIN dataLoss=$ANOM_LOSS renderDirty=$ANOM_DIRTY maxWindows=$MAXWIN"
TMUX_TMPDIR="$DIR_A" "$TMUXBIN" kill-server 2>/dev/null; TMUX_TMPDIR="$DIR_B" "$TMUXBIN" kill-server 2>/dev/null
exit $(( ANOM_CRASH + ANOM_HANG + ANOM_SESS + ANOM_WIN + ANOM_LOSS + ANOM_DIRTY ))
