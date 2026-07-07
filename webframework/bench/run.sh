#!/usr/bin/env bash
# Throughput + profiling harness for the webframework, in isolation (benchserver = framework only,
# no DB/blob/app logic). Run build.sh first. Everything runs on THIS machine — the load generator
# and the server share the same cores, so absolute req/s is conservative; the interesting signals
# are relative (thread scaling, mm-mode deltas), idle CPU, the crash test, and the perf profile.
#
# Usage: ./run.sh            # full suite
#        DURATION=3 ./run.sh # quicker
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
bin="$here/bin"
lg="$bin/loadgen"
PORT_BASE=${PORT_BASE:-27000}
CONNS=${CONNS:-40}
DURATION=${DURATION:-5}

[ -x "$lg" ] || { echo "run build.sh first"; exit 1; }

# start_server <binary> <threads> <port>  -> echoes PID; waits until it accepts.
start_server() {
    PORT=$3 THREADS=$2 "$1" >/dev/null 2>"$bin/.srv.log" & local pid=$!
    local i; for i in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$3/plaintext" && break; done
    echo "$pid"; }
load() { PORT=$1 CONNS=$CONNS DURATION=$DURATION TARGET=${2:-/plaintext} "$lg" 2>/dev/null; }
field() { grep -oP "$2=\\K[0-9.]+" <<<"$1"; }

echo "### 1. THREAD SCALING (mm=atomicArc, CONNS=$CONNS, ${DURATION}s each)"
printf "  %-8s %-12s %-10s %-8s\n" threads rps avg_us errors
for T in 1 2 4 8 16; do
    p=$((PORT_BASE)); pid=$(start_server "$bin/benchserver_atomicArc" "$T" "$p")
    r=$(load "$p"); kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    printf "  %-8s %-12s %-10s %-8s\n" "$T" "$(field "$r" rps)" "$(field "$r" avg_us)" "$(field "$r" errors)"
done

echo; echo "### 2. mm-MODE CRASH TEST (THREADS=8, CONNS=$CONNS, 10 rounds)"
echo "    orc = production default. Its cycle collector's process-global registry is mutated"
echo "    unsynchronised by every worker freeing per-request closures -> data race -> SIGSEGV."
echo "    The race is ALWAYS present; whether it faults depends on code layout + timing, so the"
echo "    frame-pointer build (orc_fp) surfaces it reliably where plain orc's window is narrower."
for mm in orc orc_fp arc atomicArc; do
    dead=0
    for round in $(seq 1 10); do
        p=$((PORT_BASE+round)); pid=$(start_server "$bin/benchserver_$mm" 8 "$p")
        load "$p" >/dev/null
        kill -0 "$pid" 2>/dev/null || dead=$((dead+1))
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    done
    printf "  %-10s crashed %d/10\n" "$mm" "$dead"
done

echo; echo "### 3. IDLE CPU (mm=atomicArc, 4 workers, no traffic, 10s)"
p=$((PORT_BASE)); pid=$(start_server "$bin/benchserver_atomicArc" 4 "$p")
clk=$(getconf CLK_TCK)
read -r _ _ _ _ _ _ _ _ _ _ _ _ _ u1 s1 _ < "/proc/$pid/stat"
timeout -sINT 10 perf stat -p "$pid" -e task-clock >/dev/null 2>&1 || true
read -r _ _ _ _ _ _ _ _ _ _ _ _ _ u2 s2 _ < "/proc/$pid/stat"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
dt=$(( (u2+s2) - (u1+s1) ))
awk "BEGIN{printf \"  idle CPU = %.3f%% of one core (%d ticks / 10s)\n\", ($dt/$clk)/10*100, $dt}"

echo; echo "### 4. RSS UNDER LOAD (leak check, CONNS=30, 10s)"
printf "  %-10s %-6s %-12s %-12s\n" mm thr rss_start rss_end
for spec in "arc:4" "atomicArc:4" "orc:1"; do
    mm=${spec%:*}; T=${spec#*:}; p=$((PORT_BASE)); pid=$(start_server "$bin/benchserver_$mm" "$T" "$p")
    r0=$(awk '/VmRSS/{print $2}' "/proc/$pid/status")
    PORT=$p CONNS=30 DURATION=10 "$lg" >/dev/null 2>&1
    r1=$(awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null || echo NA)
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    printf "  %-10s %-6s %-12s %-12s\n" "$mm" "$T" "${r0}KB" "${r1}KB"
done

echo; echo "### 5. CPU PROFILE (perf, mm=atomicArc, ${DURATION}s load) — top self-time"
if command -v perf >/dev/null; then
    p=$((PORT_BASE)); pid=$(start_server "$bin/benchserver_perf" 4 "$p")
    perf record -o "$bin/perf.data" -e task-clock -g --call-graph fp -p "$pid" -- \
        env PORT=$p CONNS=$CONNS DURATION=$DURATION "$lg" >/dev/null 2>&1
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    perf report -i "$bin/perf.data" --stdio -g none 2>/dev/null \
        | grep -vE '^\s*#' | awk '$2!="0.00%"' | head -20
    echo "  (full call graph: perf report -i $bin/perf.data)"
else
    echo "  perf not available — skipped"
fi
