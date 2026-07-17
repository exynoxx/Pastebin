#!/usr/bin/env bash
# Orchestrate a burst run against the Pi WITH box-side monitoring.
#   - snapshots the api container restart-count / image before & after
#   - samples Pi RAM/swap + api-container mem/cpu every ~2s during the run
#   - runs loadtest/burst_test.py, then prints a combined verdict
#
# Usage: run_burst.sh <scenario> <ramp> [write_size] [admin_token]
#   scenario : read | write | mixed
#   ramp     : e.g. 5:5,20:10,50:10,100:10,200:15,400:15
# Env: URL (default http://100.120.214.111 = Pi over tailnet)
set -u
SCENARIO="${1:-read}"
RAMP="${2:-5:5,20:10,50:10,100:10,200:15,400:15}"
WRITE_SIZE="${3:-500}"
ADMIN_TOKEN="${4:-}"
URL="${URL:-http://100.120.214.111}"

HERE="$(cd "$(dirname "$0")" && pwd)"
cd /home/nicholas/Dokumenter/git/Pastebin
set -a; . ./.taskenv 2>/dev/null; set +a
PI=100.120.214.111
SSH="sshpass -p ${PI_PASS} ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 pi@${PI}"
C=deploy-pastebin-api-1
LOG="$(mktemp)"

snap() { $SSH "docker inspect -f '{{.RestartCount}} {{.State.StartedAt}} {{.Image}} {{.State.OOMKilled}}' $C 2>/dev/null"; }

echo "===== PRE ====="
PRE="$(snap)"; echo "restartcount startedat image oomkilled = $PRE"
PRE_RC="$(echo "$PRE" | awk '{print $1}')"

# ---- start box-side sampler (remote loop, streamed to a local file) ----
$SSH 'bash -s' > "$LOG" 2>/dev/null <<'REMOTE' &
for i in $(seq 1 300); do
  ts=$(date +%s)
  ma=$(free -m | awk '/^Mem:/{print $3, $7}')
  sw=$(free -m | awk '/^Swap:/{print $3}')
  st=$(docker stats --no-stream --format '{{.MemUsage}} {{.MemPerc}} {{.CPUPerc}}' deploy-pastebin-api-1 2>/dev/null)
  echo "$ts mem_used_avail=[$ma] swap_used=$sw api=[$st]"
  sleep 2
done
REMOTE
SAMPLER=$!
sleep 1

# ---- run the burst ----
echo "===== BURST ====="
IDS_FILE=""
case "$SCENARIO" in write|mixed) IDS_FILE="$(mktemp)";; esac
set +e
python3 "$HERE/burst_test.py" --url "$URL" --scenario "$SCENARIO" --ramp "$RAMP" \
    --write-size "$WRITE_SIZE" ${SIZES:+--sizes "$SIZES"} ${MAX_REQUESTS:+--max-requests "$MAX_REQUESTS"} \
    ${IDS_FILE:+--ids-file "$IDS_FILE"} ${ADMIN_TOKEN:+--admin-token "$ADMIN_TOKEN"}
PY_RC=$?

# ---- stop sampler (never let this abort the POST/verdict reporting) ----
kill "$SAMPLER" 2>/dev/null || true
wait "$SAMPLER" 2>/dev/null || true

echo "===== POST ====="
POST="$(snap)"; echo "restartcount startedat image oomkilled = $POST"
POST_RC="$(echo "$POST" | awk '{print $1}')"
OOM="$(echo "$POST" | awk '{print $4}')"

echo "===== BOX-SIDE SAMPLES (peaks) ====="
awk '
  match($0, /mem_used_avail=\[([0-9]+) ([0-9]+)\]/, m) { if(m[1]+0>peakused)peakused=m[1]; if(minavail==""||m[2]+0<minavail)minavail=m[2] }
  match($0, /swap_used=([0-9]+)/, s) { if(s[1]+0>peakswap)peakswap=s[1] }
  { print }
  END { print "---"; printf "peak_mem_used=%sMB  min_mem_avail=%sMB  peak_swap_used=%sMB\n", peakused, minavail, peakswap }
' "$LOG"

echo "===== VERDICT ====="
echo "python_exit=$PY_RC (0=survived,1=crashed-per-health,2=preflight-down)"
echo "restart_count: $PRE_RC -> $POST_RC   oom_killed_flag=$OOM"
if [ "$PRE_RC" != "$POST_RC" ] || [ "$OOM" = "true" ]; then
  echo ">>> CONTAINER RESTARTED / OOM-KILLED DURING TEST — the box did NOT survive cleanly"
elif [ "$PY_RC" = "0" ]; then
  echo ">>> SURVIVED: served or shed (503/429) throughout, container stable, no OOM"
else
  echo ">>> INCONCLUSIVE/DISTRESS: review stage output above"
fi

# ---- self-cleanup: delete the pastes this write/mixed run created ----
if [ -n "$IDS_FILE" ] && [ -s "$IDS_FILE" ]; then
  n=$(wc -l < "$IDS_FILE")
  echo "===== CLEANUP: deleting $n created pastes (token stays on Pi) ====="
  $SSH 'T=$(docker exec deploy-pastebin-api-1 printenv ADMIN_TOKEN);
    xargs -P 16 -I{} curl -s -o /dev/null -X DELETE "http://localhost/api/admin/pastes/{}" -H "X-Admin-Token: $T"' < "$IDS_FILE"
  # verify residue via the public recent list (BURSTTEST titles remaining)
  left=$(curl -s "$URL/api/pastes" | grep -oc '"title":"BURSTTEST' || true)
  echo "cleanup issued for $n ids; BURSTTEST still visible in recent page: ${left:-0}"
fi
rm -f "$LOG" "${IDS_FILE:-/dev/null}" 2>/dev/null || true
